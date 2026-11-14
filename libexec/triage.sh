#!/usr/bin/env bash
# Compare the active plan files with the GitHub issues: create missing issues, fix inaccurate ones, set parent/child links and
# dependencies, and add or remove agent-ok. The agent only reads and returns proposed changes as JSON; this script checks them
# against the rules below and applies them.
# Issue text is written by whoever opened the issue: the script never adds agent-ok to an issue from an untrusted author.
# Usage: agent-loop triage [--dry-run]   (--dry-run only prints the proposal; the AI still runs and uses quota)
set -euo pipefail
. "$(dirname "$0")/../lib/common.sh"

[ "${1:-}" = --dry-run ] && export DRY=1
[ -n "$AGENT_PLANS_GLOB" ] || die "triage needs plan files: set AGENT_PLANS_GLOB in .agent-loop.conf (e.g. 'docs/plans/*.md')"
r=$(gh_repo)
ts=$(date +%Y%m%d-%H%M%S)
stream="$STATE/logs/triage-$ts.jsonl"   # the whole conversation
out="$STATE/logs/triage-$ts.json"       # the final result (the proposal)
applied="$STATE/logs/triage-$ts.applied.log"
tmp=$(mktemp -d "$STATE/triage.XXXXXX")
wt="$(dirname "$REPO")/$AGENT_WT_PREFIX-triage"

cd "$REPO"
git fetch origin --prune --quiet
[ "${DRY:-0}" = 1 ] || ensure_labels   # created issues may carry agent-ok / human
[ -d "$wt" ] && git worktree remove --force "$wt"
git worktree add --quiet --detach "$wt" "$BASE_REF"
trap 'git -C "$REPO" worktree remove --force "$wt" 2>/dev/null || true; rm -rf "$tmp"' EXIT

# --- Material for the agent ---
issues_snapshot >"$tmp/open.json"
gh issue list --state closed --limit 100 --json number,title >"$tmp/closed.json"
gh pr list --state open --limit 100 --json number,title,headRefName >"$tmp/prs.json"
gh label list --limit 200 --json name -q '[.[].name]' >"$tmp/labels.json"
mkdir -p "$wt/.agent"
jq -n --slurpfile o "$tmp/open.json" --slurpfile c "$tmp/closed.json" --slurpfile p "$tmp/prs.json" --slurpfile l "$tmp/labels.json" \
  '{openIssues: $o[0], recentClosedIssues: $c[0], openPullRequests: $p[0], repoLabels: $l[0]}' >"$wt/.agent/triage-context.json"
plans=$(cd "$wt" && for f in $AGENT_PLANS_GLOB; do
  [ -f "$f" ] || continue
  if [ -z "$AGENT_PLANS_ACTIVE_REGEX" ] || grep -Eq "$AGENT_PLANS_ACTIVE_REGEX" "$f"; then echo "$f"; fi
done | tr '\n' ' ')
[ -n "$plans" ] || die "no active plans (AGENT_PLANS_GLOB='$AGENT_PLANS_GLOB', AGENT_PLANS_ACTIVE_REGEX='$AGENT_PLANS_ACTIVE_REGEX')"

schema='{"type":"object","required":["summary","actions"],"properties":{
  "summary":{"type":"string","description":"'"$AGENT_LANGUAGE"', what you checked and what you propose"},
  "actions":{"type":"array","items":{"type":"object","required":["op","reason"],"properties":{
    "op":{"type":"string","enum":["create","update"]},
    "ref":{"type":"string"}, "number":{"type":"integer"},
    "title":{"type":"string"}, "body":{"type":"string"},
    "labels":{"type":"array","items":{"type":"string"}},
    "add_labels":{"type":"array","items":{"type":"string"}},
    "remove_labels":{"type":"array","items":{"type":"string"}},
    "parent":{"type":"string","description":"issue number such as \"24\", or a ref of a create in this list"},
    "blocked_by":{"type":"array","items":{"type":"string","description":"issue number such as \"28\", or a ref"}},
    "comment":{"type":"string"}, "reason":{"type":"string"}}}}}}'

export T_PLANS="$plans" T_MAX="$AGENT_TRIAGE_MAX_ACTIONS"
log "Starting triage ($AGENT_TRIAGE_MODEL / ${AGENT_TRIAGE_EFFORT}, plans: ${plans})"
render_prompt triage | (cd "$wt" && without_credentials claude -p --strict-mcp-config \
  --model "$AGENT_TRIAGE_MODEL" --effort "$AGENT_TRIAGE_EFFORT" \
  --permission-mode dontAsk --max-turns "$AGENT_TRIAGE_MAX_TURNS" --settings '{"disableAllHooks": true}' \
  --allowedTools Read Grep Glob "Bash(git log:*)" "Bash(git show:*)" "Bash(gh issue view:*)" "Bash(gh issue list:*)" "Bash(gh pr view:*)" "Bash(gh pr list:*)" \
  --disallowedTools "${TRIAGE_DENY[@]}" \
  --output-format stream-json --verbose --json-schema "$schema" --name "agent triage") >"$stream" 2>"$out.stderr" || true
result_of "$stream" >"$out" || true
pause_if_heavy_usage "$stream"
# One line in history.jsonl (kept when the logs are deleted)
if jq -e .structured_output "$out" >/dev/null 2>&1; then tri_outcome=ok
elif limit_resume_at "$stream" >/dev/null; then tri_outcome=limit
else tri_outcome=failed; fi
tri_turns=$(jq -r '.num_turns // 0' "$out" 2>/dev/null || true); tri_cost=$(jq -r '.total_cost_usd // 0' "$out" 2>/dev/null || true)
history_add "$(jq -nc --arg run "$(basename "${out%.json}")" --arg t "$(now_iso)" --arg outcome "$tri_outcome" --arg model "$AGENT_TRIAGE_MODEL" \
  --argjson turns "${tri_turns:-0}" --argjson cost "${tri_cost:-0}" \
  '{run: $run, time: $t, issue: null, mode: "triage", outcome: $outcome, status: null, pr: null, turns: $turns, cost: $cost, model: $model}' 2>/dev/null)" || true
if ! jq -e .structured_output "$out" >/dev/null 2>&1 && resume_at=$(limit_resume_at "$stream"); then
  pause_until "$resume_at"
  exit 75   # usage limit: loop.sh runs triage again after it resets
fi

jq -e .structured_output "$out" >/dev/null || die "triage produced no result (${out})"
log "Triage result: $(jq -r '.structured_output.summary' "$out")"
log "($(jq -r '"\(.num_turns) turns, $\(.total_cost_usd | . * 100 | round / 100)"' "$out"), full text in ${out})"
total=$(jq '.structured_output.actions | length' "$out")
[ "$total" -gt "$AGENT_TRIAGE_MAX_ACTIONS" ] && log "${total} actions proposed. Applying only the first ${AGENT_TRIAGE_MAX_ACTIONS}"

# --- Apply (anything that breaks the rules is dropped) ---
known_labels=$(jq -r '.[]' "$tmp/labels.json")
resolve() { # number or ref -> number (empty if it cannot be resolved)
  case "$1" in
    '' | null) ;;
    *[!0-9]*) cat "$tmp/ref-$1" 2>/dev/null || { [ "${DRY:-0}" = 1 ] && echo "{{$1}}"; } || true ;;
    *) echo "$1" ;;
  esac
}
subst_refs() { # replace {{ref}} in a body with the issue number
  local text=$1 f k
  for f in "$tmp"/ref-*; do
    [ -f "$f" ] || continue
    k=${f##*/ref-}
    text=$(T_X="#$(cat "$f")" K="{{$k}}" awk 'BEGIN { k = ENVIRON["K"]; v = ENVIRON["T_X"] }
      { line = $0; out = ""; while ((i = index(line, k)) > 0) { out = out substr(line, 1, i - 1) v; line = substr(line, i + length(k)) } print out line }' <<<"$text")
  done
  printf '%s' "$text"
}
filter_labels() { # one label per line in -> only the labels that may be used
  local l g ok
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    if [ "$l" = "$L_WIP" ] || [ "$l" = "$L_BLOCKED" ] || [ "$l" = "$L_AUTOMERGE" ]; then log "  label $l is never added or removed"; continue; fi
    if echo "$known_labels" | grep -qx "$l" || [ "$l" = "$L_OK" ] || [ "$l" = "$L_HUMAN" ]; then echo "$l"; continue; fi
    ok=0
    # shellcheck disable=SC2254
    for g in $AGENT_AUTOCREATE_LABELS; do case "$l" in $g) ok=1 ;; esac; done
    # (may already exist when an earlier action in this run created it)
    if [ "$ok" = 1 ]; then run gh label create "$l" --color ededed >/dev/null 2>&1 || true; echo "$l"
    else log "  unknown label $l is not added"; fi
  done
}
db_id() { gh api "repos/$r/issues/$1" --jq .id; }
link_parent() { # child parent
  local p cur=""; p=$(resolve "$2"); [ -n "$p" ] || return 0
  case "$1" in *[!0-9]*) ;; *) cur=$(jq -r --argjson n "$1" '.[] | select(.number == $n) | .parent // empty' "$tmp/open.json") ;; esac
  [ "$cur" = "$p" ] && return 0
  if [ "${DRY:-0}" = 1 ]; then log "[dry-run] make #$1 a sub-issue of #$p"; return 0; fi
  gh api -X POST "repos/$r/issues/$p/sub_issues" -F sub_issue_id="$(db_id "$1")" >/dev/null 2>&1 ||
    log "  could not make #$1 a sub-issue of #$p (it may already have another parent)"
}
link_blockers() { # issue blocked_by-json-array
  local b
  for b in $(echo "$2" | jq -r '.[]? | tostring'); do
    b=$(resolve "$b"); [ -n "$b" ] || continue
    if [ "${DRY:-0}" = 1 ]; then log "[dry-run] #$1 waits for #$b (dependency)"; continue; fi
    gh api -X POST "repos/$r/issues/$1/dependencies/blocked_by" -F issue_id="$(db_id "$b")" >/dev/null 2>&1 ||
      log "  dependency #$1 <- #$b is already set or could not be set (the body's 'Depends on:' line decides)"
  done
}

jq -c ".structured_output.actions[:$AGENT_TRIAGE_MAX_ACTIONS][]" "$out" | while IFS= read -r a; do
  op=$(echo "$a" | jq -r .op)
  why=$(echo "$a" | jq -r .reason)
  locked=false
  if [ "$op" = create ]; then
    ref=$(echo "$a" | jq -r '.ref // empty')
    title=$(echo "$a" | jq -r '.title // empty')
    [ -n "$title" ] || { log "Skipping a create proposal with no title"; continue; }
    body=$(subst_refs "$(echo "$a" | jq -r '.body // ""')")
    labels=$(echo "$a" | jq -r '.labels[]?' | filter_labels)
    echo "$labels" | grep -qx "$L_HUMAN" && labels=$(echo "$labels" | grep -vx "$L_OK" || true)
    log "Create: $title [${labels//$'\n'/,}] - $why"
    if [ "${DRY:-0}" = 1 ]; then
      num="{{${ref:-new}}}"
      printf '%s\n' "$body" | sed 's/^/    | /' >&2
    else
      largs=()
      [ -n "$labels" ] && largs=(--label "$(echo "$labels" | paste -sd, -)")
      url=$(gh issue create --title "$title" --body-file - ${largs[@]+"${largs[@]}"} <<<"$body") ||
        { log "  could not create the issue; skipping"; continue; }
      num=${url##*/}
      [ -n "$ref" ] && echo "$num" >"$tmp/ref-$ref"
      echo "created #$num $title" >>"$applied"
    fi
  else
    num=$(echo "$a" | jq -r '.number // empty')
    [ -n "$num" ] || { log "Skipping an update proposal with no number"; continue; }
    cur=$(jq -c --argjson n "$num" '.[] | select(.number == $n)' "$tmp/open.json")
    [ -n "$cur" ] || { log "#$num is not open; skipping"; continue; }
    locked=$(echo "$cur" | jq --arg w "$L_WIP" --arg b "$L_BLOCKED" '.labels | (index($w) or index($b))')
    cur_human=$(echo "$cur" | jq --arg h "$L_HUMAN" '.labels | index($h) != null')
    cur_trusted=$(echo "$cur" | jq --arg assoc "$AGENT_TRUSTED_ASSOCIATIONS" --arg users "$AGENT_TRUSTED_USERS" \
      "$JQ_TRUSTED"'trusted(.author; .authorAssociation)')
    log "Update: #$num $(echo "$cur" | jq -r .title) - $why"
    if [ "$locked" = true ]; then
      log "  in progress or blocked: comment only"
    else
      args=()
      title=$(echo "$a" | jq -r '.title // empty')
      [ -n "$title" ] && args+=(--title "$title")
      if echo "$a" | jq -e 'has("body")' >/dev/null; then
        [ "${DRY:-0}" = 1 ] || echo "$cur" | jq -r .body >"$STATE/logs/triage-$ts.issue-$num.old-body.md"   # keep the original body
        subst_refs "$(echo "$a" | jq -r .body)" >"$tmp/body-$num"
        args+=(--body-file "$tmp/body-$num")
      fi
      add=$(echo "$a" | jq -r '.add_labels[]?' | filter_labels)
      rem=$(echo "$a" | jq -r '.remove_labels[]?' | grep -vx -e "$L_HUMAN" -e "$L_WIP" -e "$L_BLOCKED" -e "$L_AUTOMERGE" -e "$L_RISK_HIGH" || true)
      if [ "$cur_human" = true ] || echo "$add" | grep -qx "$L_HUMAN"; then
        echo "$add" | grep -qx "$L_OK" && log "  not adding $L_OK to a $L_HUMAN issue"
        add=$(echo "$add" | grep -vx "$L_OK" || true)
      fi
      # An issue from someone who is not trusted reaches an agent only when a person labels it
      if [ "$cur_trusted" != true ] && echo "$add" | grep -qx "$L_OK"; then
        log "  not adding $L_OK: #$num was opened by $(echo "$cur" | jq -r '.author // "an unknown user"'), who is not trusted (AGENT_TRUSTED_ASSOCIATIONS / AGENT_TRUSTED_USERS). Add the label yourself if the issue is fine"
        add=$(echo "$add" | grep -vx "$L_OK" || true)
      fi
      [ -n "$add" ] && args+=(--add-label "$(echo "$add" | paste -sd, -)")
      [ -n "$rem" ] && args+=(--remove-label "$(echo "$rem" | paste -sd, -)")
      if [ ${#args[@]} -gt 0 ]; then
        log "  change: $(printf '%s ' "${args[@]}" | tr '\n' ' ' | cut -c1-300)"
        if run gh issue edit "$num" "${args[@]}" >/dev/null; then
          [ "${DRY:-0}" = 1 ] || { echo "updated #$num ${args[*]}" | tr '\n' ' ' | cut -c1-500; echo; } >>"$applied"
        else
          log "  could not update #$num"
        fi
      fi
    fi
    c=$(echo "$a" | jq -r '.comment // empty')
    [ -n "$c" ] && { log "  comment: $c"; issue_comment "$num" "$c" || log "  could not comment on #$num"; }
  fi
  [ "$locked" = true ] && continue   # in-progress and blocked issues keep their parent/child links and dependencies
  link_parent "$num" "$(echo "$a" | jq -r '.parent // empty | tostring')"
  link_blockers "$num" "$(echo "$a" | jq -c '.blocked_by // []')"
done
log "Triage done$([ "${DRY:-0}" = 1 ] && echo ' (dry-run: nothing was changed)')"
