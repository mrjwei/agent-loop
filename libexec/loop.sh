#!/usr/bin/env bash
# The agent loop. Looks at GitHub at a fixed interval and repeats the steps below (AI cost only accrues while an agent runs).
#   1. Clean up: remove the worktree, branches and state of PRs that were merged or closed. An issue that is still open
#                after its PR was merged or closed loses agent-ok, so the same work does not start again
#      Resume:   an agent-blocked issue answered by a trusted author loses agent-blocked (AGENT_AUTO_RESUME)
#      Base check: while checks fail on the head of origin/<base>, step 4 does not start agents (an issue is opened once)
#   2. Fix:      for an agent PR with a conflict, a failing check or new review feedback, run work.sh --fix
#   3. Triage:   when nothing is ready to start and the base branch moved since the last triage, run triage.sh
#   4. Start:    run work.sh in parallel for issues that are agent-ok with all dependencies closed, up to the free slots
# Merging a PR closes the dependency of the issues waiting on it, so the next round starts them.
# When today's spend reaches AGENT_DAILY_BUDGET, steps 2-4 are skipped until the next local day (cleanup continues).
# When a usage limit hits, the run is not counted as a failure, and steps 2-4 stop until it resets (cleanup continues).
#
# Usage: agent-loop start [--once] [--dry-run] [--no-triage]
#        agent-loop status | kill | unpause
# Configuration: .agent-loop.conf in the project (see README.md), or environment variables (e.g. AGENT_MAX_PARALLEL=3)
set -euo pipefail

. "$(dirname "$0")/../lib/common.sh"

# The loop runs from a private copy of the package under .git/, so that upgrading or switching branches
# in the package checkout cannot change the scripts of a running loop.
# --status, --kill and --unpause do not copy (they must not replace a running loop's copy).
case " $* " in *" --status "* | *" --kill "* | *" --unpause "*) AGENT_FROM_COPY=1 ;; esac
if [ "${AGENT_FROM_COPY:-0}" != 1 ]; then
  # Delete copies from finished loops older than a day (agents keep running from a copy after the loop stops)
  for d in "$STATE"/pkg-*; do
    [ -d "$d" ] || continue
    kill -0 "${d##*/pkg-}" 2>/dev/null || [ -z "$(find "$d" -maxdepth 0 -mtime +1)" ] || rm -rf "$d"
  done
  pkg="$STATE/pkg-$$"   # the pid does not change across exec
  rm -rf "$pkg" && mkdir -p "$pkg"
  cp -R "$PKG_DIR/bin" "$PKG_DIR/libexec" "$PKG_DIR/lib" "$PKG_DIR/prompts" "$pkg/"
  [ -f "$PKG_DIR/VERSION" ] && cp "$PKG_DIR/VERSION" "$pkg/"
  export AGENT_REPO="$REPO" AGENT_FROM_COPY=1
  exec "$pkg/libexec/loop.sh" "$@"
fi

once=0 tick=0
export DRY=${DRY:-0} NO_TRIAGE=${NO_TRIAGE:-0}
# GitHub snapshots for this round (status uses its own, so it cannot change a running round's view)
ISSUES_JSON="$STATE/issues.json" PRS_JSON="$STATE/prs.json"
for a in "$@"; do
  case "$a" in
    --once) once=1 ;;
    --dry-run) DRY=1 ;;
    --no-triage) NO_TRIAGE=1 ;;
    --tick) tick=1 ;;
    --status) mode=status ;;
    --kill) mode="kill" ;;   # quoted: an unquoted word that names a command looks like a mistake to shellcheck
    --unpause) mode=unpause ;;
    *) die "unknown argument: $a" ;;
  esac
done

launch() { # issue implement|fix
  local log_file
  log_file="$STATE/logs/issue-$1-$(date +%Y%m%d-%H%M%S)-$2.log"
  if [ "$DRY" = 1 ]; then log "[dry-run] start $2 for #$1"; return; fi
  # set -m: the agent leads its own process group, so Ctrl-C on the loop does not reach it and
  # `agent-loop kill` can stop the whole group (work.sh, claude and their children)
  set -m
  if [ "$2" = fix ]; then nohup "$LIBEXEC/work.sh" "$1" --fix >"$log_file" 2>&1 </dev/null &
  else nohup "$LIBEXEC/work.sh" "$1" >"$log_file" 2>&1 </dev/null &
  fi
  set +m
  echo $! >"$(pid_file "$1")"
  log "#$1: started $2 (pid $!, ${log_file})"
}

# --- 1. Clean up ---
cleanup_branch() { # issue reason
  local n=$1 wt br
  wt=$(wt_of "$n"); br=$(br_of "$n")
  if [ -d "$wt" ] && [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
    log "#$n: $2, but $wt has uncommitted changes, so it stays"
    return
  fi
  log "#$n: $2. Removing the worktree and branches"
  [ -d "$wt" ] && run git -C "$REPO" worktree remove --force "$wt"
  run git -C "$REPO" branch -D "$br" >/dev/null 2>&1 || true
  # Also delete the branch on GitHub (merges usually do it already; a closed PR's branch can be restored from the PR page)
  if git -C "$REPO" ls-remote --exit-code --heads origin "$br" >/dev/null 2>&1; then
    run git -C "$REPO" push origin --delete "$br" --quiet || true
  fi
  [ "$DRY" = 1 ] || forget_issue "$n"
}

issue_open() { jq -e --argjson n "$1" 'any(.[]; .number == $n)' "$ISSUES_JSON" >/dev/null; }

# Take agent-ok / agent-wip off an issue: on GitHub, and in this round's snapshot so that step 4 does not start it
unlabel_issue() { # issue
  local t
  label_remove "$1" "$L_OK"; label_remove "$1" "$L_WIP"
  t=$(mktemp "$STATE/issues.XXXXXX")
  jq --argjson n "$1" --arg ok "$L_OK" --arg wip "$L_WIP" \
    'map(if .number == $n then .labels -= [$ok, $wip] else . end)' "$ISSUES_JSON" >"$t" && mv "$t" "$ISSUES_JSON"
}

phase_cleanup() {
  local ref n pr state last
  for ref in $(git -C "$REPO" for-each-ref --format='%(refname:short)' 'refs/heads/agent/issue-*'); do
    n=${ref#agent/issue-}
    case "$n" in '' | *[!0-9]*) continue ;; esac
    is_running "$n" && continue
    jq -e --argjson n "$n" 'any(.[]; .issue == $n)' "$PRS_JSON" >/dev/null && continue  # PR still open
    last=$(last_done_pr "$ref") || last=""
    pr=${last%% *} state=${last#* }
    if [ -n "$pr" ] && [ "$(stamp_get closedpr "$n" "")" != "$pr" ]; then
      # The branch's latest PR is finished and not handled yet: clean up, once. If the issue is still open, also
      # remove agent-ok, or the next round would start the same work again. That happens when a human rejected the
      # PR, and after a merge when "Closes #n" did not apply (the base branch is not the default branch, the line
      # is missing, or part of the issue was left for a person). If agent-ok is added again, the work restarts from
      # the base branch on the same branch name; this PR is then ignored because it is remembered as handled.
      if [ "$state" = MERGED ]; then
        cleanup_branch "$n" "PR #$pr was merged"
        if issue_open "$n"; then
          unlabel_issue "$n"
          issue_comment "$n" "PR #$pr was merged but this issue is still open, so I removed \`$L_OK\`. Close the issue if it is done. If part of it is left for an agent, add \`$L_OK\` again (it starts from $AGENT_BASE_BRANCH)."
        fi
      else
        cleanup_branch "$n" "PR #$pr was closed without merging"
        if issue_open "$n"; then
          unlabel_issue "$n"
          issue_comment "$n" "PR #$pr was closed without merging, so I removed \`$L_OK\`. Add it again to hand this back to an agent (it restarts from $AGENT_BASE_BRANCH)."
        fi
      fi
      [ "$DRY" = 1 ] || stamp_set closedpr "$n" "$pr"
    elif ! issue_open "$n"; then
      cleanup_branch "$n" "the issue was closed"
    fi
  done
  run git -C "$REPO" worktree prune
  [ "$DRY" = 1 ] || find "$STATE/logs" -type f -mtime +"$AGENT_LOG_DAYS" -delete 2>/dev/null || true
}

# An agent-blocked issue whose block comment was answered by a trusted author resumes: the loop removes the label (in
# this round's snapshot too), and the issue then follows the normal path (a new attempt, or a fix run when its PR is open)
phase_resume() {
  local n who t
  [ "$AGENT_AUTO_RESUME" = 1 ] || return 0
  for n in $(jq -r --arg b "$L_BLOCKED" '.[] | select(.labels | index($b)) | .number' "$ISSUES_JSON"); do
    who=$(block_answered "$n") || who=""
    [ -n "$who" ] || continue
    log "#$n: $who answered the block comment, so I removed \`$L_BLOCKED\` and the issue resumes"
    label_remove "$n" "$L_BLOCKED"
    t=$(mktemp "$STATE/issues.XXXXXX")
    jq --argjson n "$n" --arg b "$L_BLOCKED" 'map(if .number == $n then .labels -= [$b] else . end)' "$ISSUES_JSON" >"$t" && mv "$t" "$ISSUES_JSON"
  done
}

# --- Base branch checks ---
# Two PRs that each pass can break the base branch together. While a check on the head of origin/<base> has failed (other
# than AGENT_IGNORE_CHECKS), step 4 does not start agents (cleanup and fix go on); an issue and one notification are
# made once per failing commit. Pending checks, and a base branch without checks, block nothing.
BASE_FAILING=""
phase_base_check() {
  local sha checks fail green merged body title url cc
  BASE_FAILING=""
  sha=$(git -C "$REPO" rev-parse --verify -q "$BASE_REF") || return 0
  checks=$(commit_checks "$sha")
  fail=$(echo "$checks" | sed -n 's/^FAIL //p' | sort -u)
  if [ -z "$fail" ]; then
    # Finished and passing: remember it, to name the PRs merged since if a later commit fails
    if echo "$checks" | grep -q '^OK ' && ! echo "$checks" | grep -q '^PENDING '; then
      [ "$DRY" = 1 ] || echo "$sha" >"$STATE/base-last-green-sha"
    fi
    return 0
  fi
  BASE_FAILING=$(echo "$fail" | paste -sd, - | sed 's/,/, /g')
  log "Checks are failing on $BASE_REF (${sha:0:7}): $BASE_FAILING. Not starting agents until they pass"
  [ "$(cat "$STATE/base-failed-sha" 2>/dev/null)" = "$sha" ] && return 0   # this commit was reported already
  green=$(cat "$STATE/base-last-green-sha" 2>/dev/null || true)
  merged=$(base_merged_prs "$green" "$sha")
  cc=$(mention)
  title="Checks failing on $AGENT_BASE_BRANCH: $BASE_FAILING"
  body="The checks on the head of \`$AGENT_BASE_BRANCH\` failed.

- Commit: $sha
- Failing checks: $(echo "$fail" | sed 's/.*/`&`/' | paste -sd, - | sed 's/,/, /g')

No agent starts until the checks on \`$AGENT_BASE_BRANCH\` pass again (fix runs and cleanup continue). Revert or fix it by hand; the loop resumes by itself when the head passes.

$(if [ -n "$green" ]; then echo "Pull requests merged since the last commit that passed (${green:0:7}):"; else echo "The last commit that passed is not known. Pull requests merged with the head commit:"; fi)
${merged:-- none found}${cc:+

cc $cc}"
  if url=$(run gh issue create --title "$title" --body "$body"); then
    [ "$DRY" = 1 ] || echo "$sha" >"$STATE/base-failed-sha"
    notify "Checks failing on $AGENT_BASE_BRANCH" "$BASE_FAILING. No agent starts until they pass." "$url"
  else
    log "could not open the issue for the failing base branch; trying again next round"
  fi
}

# --- 2. Fix ---
phase_fix() {
  local p n reasons sig
  while IFS= read -r p <&3; do
    n=$(echo "$p" | jq .issue)
    is_running "$n" && continue
    issue_open "$n" || continue
    has_label "$ISSUES_JSON" "$n" "$L_BLOCKED" && continue
    reasons=$(pr_fix_reasons "$p" "$(stamp_get handled "$n")")
    [ "$(echo "$reasons" | jq .needed)" = true ] || continue
    sig=$(echo "$reasons" | jq -r .signature)
    [ "$sig" = "$(stamp_get sig "$n" none)" ] && continue   # nothing changed since the last fix run
    log "#$n: PR #$(echo "$p" | jq .pr) needs work ($(echo "$reasons" | jq -r '[if .conflict then "conflict" else empty end, (.failing[] | "failing: \(.)"), (if (.feedback | length) > 0 then "\(.feedback | length) feedback item(s)" else empty end)] | join(", ")'))"
    if [ "$(count_get fixes "$n")" -ge "$AGENT_MAX_FIXES" ]; then
      run gh pr comment "$(echo "$p" | jq .pr)" --body "$AGENT_MARKER Conflicts, failing checks or feedback remain after ${AGENT_MAX_FIXES} fix rounds. Waiting for a human." >/dev/null
      block_issue "$n" "PR #$(echo "$p" | jq .pr) still has conflicts, failing checks or feedback after ${AGENT_MAX_FIXES} fix rounds." fix
      continue
    fi
    [ "$(running_count)" -lt "$AGENT_MAX_PARALLEL" ] || { log "No free slot; fixing waits for the next round"; return; }
    launch "$n" fix   # work.sh records the state (sig) when it finishes a fix; on failure the next round tries again
  done 3< <(jq -c '.[]' "$PRS_JSON")
}

# --- 3. Triage ---
phase_triage() {
  local base_sha
  [ "$NO_TRIAGE" = 1 ] && return
  [ -n "$AGENT_PLANS_GLOB" ] || return   # triage needs plan files; disabled unless AGENT_PLANS_GLOB is set
  base_sha=$(git -C "$REPO" rev-parse "$BASE_REF")
  [ "$base_sha" = "$(cat "$STATE/last-triage-sha" 2>/dev/null)" ] && return
  if [ "$DRY" = 1 ]; then log "[dry-run] run triage ($BASE_REF moved since the last triage)"; return; fi
  local rc=0
  "$LIBEXEC/triage.sh" || rc=$?
  case "$rc" in
    0) echo "$base_sha" >"$STATE/last-triage-sha"; issues_snapshot >"$ISSUES_JSON" ;;
    75) log "Triage stopped by a usage limit. It will run again once the limit resets" ;;
    *) log "Triage failed. It will run again the next time $BASE_REF moves"; echo "$base_sha" >"$STATE/last-triage-sha" ;;
  esac
}

# --- 4. Start ---
candidates() { # issue numbers ready to start (excluding ones that are running or already have an open PR)
  local n
  for n in $(ready_issues "$ISSUES_JSON"); do
    is_running "$n" && continue
    jq -e --argjson n "$n" 'any(.[]; .issue == $n)' "$PRS_JSON" >/dev/null && continue
    echo "$n"
  done
}

phase_launch() {
  local n
  for n in $(candidates); do
    [ "$(running_count)" -lt "$AGENT_MAX_PARALLEL" ] || return 0
    launch "$n" implement
  done
}

do_tick() {
  git -C "$REPO" fetch origin --prune --quiet
  running_count >/dev/null   # drops the pid files of finished agents
  issues_snapshot >"$ISSUES_JSON"
  agent_prs >"$PRS_JSON"
  phase_cleanup
  phase_resume
  phase_base_check
  if paused; then
    log "Paused by a usage limit until $(fmt_epoch "$(paused_until)"); not starting agents (resume now: agent-loop unpause)"
    return 0
  fi
  if over_budget; then
    log "Daily budget reached: \$$(spend_today) of \$${AGENT_DAILY_BUDGET} spent today (AGENT_DAILY_BUDGET); not fixing or starting agents until tomorrow"
    if [ "$(cat "$STATE/budget-notified" 2>/dev/null)" != "$(date +%Y%m%d)" ]; then
      [ "$DRY" = 1 ] || date +%Y%m%d >"$STATE/budget-notified"
      notify "Agents paused" "Daily budget reached: \$$(spend_today) of \$${AGENT_DAILY_BUDGET}. No agent starts until tomorrow."
    fi
    return 0
  fi
  phase_fix
  [ -z "$(candidates)" ] && phase_triage
  paused || [ -n "$BASE_FAILING" ] || phase_launch   # if triage hit a limit, or the base branch is red, do not start anything
  log "Round done: agents running $(running_count)/${AGENT_MAX_PARALLEL}, open PRs $(jq length "$PRS_JSON"), ready to start $(candidates | wc -l | tr -d ' ')"
}

show_status() {
  local f n failing
  paused && echo "== Paused by a usage limit until $(fmt_epoch "$(paused_until)") (resume now: agent-loop unpause)"
  failing=$(base_failing_names)
  [ -z "$failing" ] || echo "== Checks are failing on $BASE_REF ($failing): no agent starts until they pass"
  over_budget && echo "== Daily budget reached: no agent starts until tomorrow"
  echo "== Spend today: \$$(spend_today)$([ -n "$AGENT_DAILY_BUDGET" ] && echo " of \$${AGENT_DAILY_BUDGET} (AGENT_DAILY_BUDGET)" || echo ' (AGENT_DAILY_BUDGET is not set)')"
  echo "== Running agents"
  for f in "$STATE"/running/*.pid; do
    [ -f "$f" ] || continue
    n=$(basename "$f" .pid)
    kill -0 "$(cat "$f")" 2>/dev/null && echo "#$n pid $(cat "$f")  latest log: $(ls -t "$STATE"/logs/issue-"$n"-*.log 2>/dev/null | head -1)"
  done
  echo "== Agent PRs"
  agent_prs | jq -r '.[] | "PR #\(.pr) <- #\(.issue)  mergeable=\(.mergeable)  checks=\([.checks[] | .conclusion // .status] | group_by(.) | map("\(.[0])x\(length)") | join(" "))"'
  echo "== Blocked (${L_BLOCKED})"
  gh issue list --label "$L_BLOCKED" --json number,title -q '.[] | "#\(.number) \(.title)"'
  echo "== Ready to start (${L_OK}, dependencies closed)"
  ISSUES_JSON=$(mktemp "$STATE/status-issues.XXXXXX") PRS_JSON=$(mktemp "$STATE/status-prs.XXXXXX")
  trap 'rm -f "$ISSUES_JSON" "$PRS_JSON"' EXIT
  issues_snapshot >"$ISSUES_JSON"; agent_prs >"$PRS_JSON"
  for n in $(candidates); do jq -r --argjson n "$n" '.[] | select(.number == $n) | "#\(.number) \(.title)"' "$ISSUES_JSON"; done
  echo "== Worktrees"
  git -C "$REPO" worktree list | grep -F -- "$AGENT_WT_PREFIX-" || true
}

case "${mode:-loop}" in
  status) show_status; exit 0 ;;
  unpause) rm -f "$PAUSE_FILE"; log "Cleared the usage-limit pause"; exit 0 ;;
  kill)
    for f in "$STATE"/running/*.pid; do
      [ -f "$f" ] || continue
      stop_agent "$(cat "$f")" && log "Stopped pid $(cat "$f") (#$(basename "$f" .pid))"
      rm -f "$f"
    done
    exit 0 ;;
esac

if [ "$tick" = 1 ]; then do_tick; exit 0; fi

# The loop itself. Each round runs as a separate process so a failure in one round does not end the loop.
lock="$STATE/loop.lock"
if ! mkdir "$lock" 2>/dev/null; then
  if kill -0 "$(cat "$lock/pid" 2>/dev/null)" 2>/dev/null; then die "the loop is already running (pid $(cat "$lock/pid"))"; fi
  rm -rf "$lock"; mkdir "$lock"
fi
echo $$ >"$lock/pid"
trap 'rm -rf "$lock"; log "Loop stopped. Running agents continue to the end (stop them with: agent-loop kill)"' EXIT
command -v caffeinate >/dev/null && { caffeinate -i -w $$ & }   # keep the Mac awake while the loop runs
[ "$DRY" = 1 ] || ensure_labels
[ -n "$AGENT_PLANS_GLOB" ] || [ "$NO_TRIAGE" = 1 ] || log "Triage is off (AGENT_PLANS_GLOB is empty): only issues you label ${L_OK} are worked on"
log "Starting the loop (${AGENT_MAX_PARALLEL} at a time, every ${AGENT_POLL_SECONDS}s, base ${AGENT_BASE_BRANCH}$([ "$DRY" = 1 ] && echo ', dry-run'))"
while :; do
  "$LIBEXEC/loop.sh" --tick || log "This round failed. Continuing with the next round"
  [ "$once" = 1 ] && break
  sleep "$AGENT_POLL_SECONDS"
done
