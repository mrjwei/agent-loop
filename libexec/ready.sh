#!/usr/bin/env bash
# Check that the current project is ready for the loop, and say how to fix what is not.
#   agent-loop ready [--json]
# Each check prints pass, warn or fail (with the fix). The exit status is 1 when any check fails. --json prints the results
# as a JSON array of {id, status, message, fix} for other commands to use. Nothing is changed on GitHub; the only thing
# written is a temporary worktree of the base branch, which is removed again.
set -euo pipefail
. "$(dirname "$0")/../lib/common.sh"

json=0
for a in "$@"; do
  case "$a" in
    --json) json=1 ;;
    -h | --help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $a" ;;
  esac
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/agent-loop-ready.XXXXXX")
RESULTS="$TMP/results.jsonl"; : >"$RESULTS"
cleanup() {
  if [ -d "$TMP/wt" ]; then git -C "$REPO" worktree remove --force "$TMP/wt" >/dev/null 2>&1 || true; fi
  git -C "$REPO" worktree prune >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

res() { # id status(pass|warn|fail) message [fix]
  jq -nc --arg id "$1" --arg s "$2" --arg m "$3" --arg f "${4:-}" '{id: $id, status: $s, message: $m, fix: $f}' >>"$RESULTS"
}
# The last lines of a command's output, indented under the message (printf, not sed \n: macOS's sed has no \n)
last_lines() { tail -n 8 "$1" | tr -d '\r' | while IFS= read -r l; do printf '\n        %s' "$l"; done; }
# The comma-separated AGENT_IGNORE_CHECKS contains this name?
ignored_check() { echo "$AGENT_IGNORE_CHECKS" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -qxF -- "$1"; }

# The workflow files of the project that use claude-code-action, as paths
claude_workflows() {
  local f
  for f in "$REPO"/.github/workflows/*.yml "$REPO"/.github/workflows/*.yaml; do
    [ -f "$f" ] || continue
    if grep -q 'anthropics/claude-code-action' "$f"; then echo "$f"; fi
  done
}
# The check name of a workflow's first job: its `name:`, else its key
first_job_name() { # file
  awk '/^jobs:[[:space:]]*$/ { injobs = 1; next }
    injobs && /^[^[:space:]#]/ { exit }
    injobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ && !key { key = $1; sub(/:$/, "", key); next }
    injobs && key && /^    name:/ && !nm { nm = $0; sub(/^    name:[[:space:]]*/, "", nm); gsub(/^["'"'"']|["'"'"']$/, "", nm); next }
    END { print (nm != "" ? nm : key) }' "$1"
}

check_doctor() {
  local out rc=0 warns
  out=$("$LIBEXEC/init.sh" --check </dev/null 2>&1) || rc=$?
  if [ "$rc" != 0 ]; then
    res doctor fail "agent-loop doctor fails: $(echo "$out" | grep '^MISSING' | tr '\n' ';' | sed 's/;$//')" "run: agent-loop doctor"
    return
  fi
  warns=$(echo "$out" | grep '^WARNING' | sed 's/^WARNING  *//' | tr '\n' ';' | sed 's/;$//' || true)
  if [ -n "$warns" ]; then res doctor warn "agent-loop doctor passes with warnings: $warns" "run: agent-loop doctor"
  else res doctor pass "agent-loop doctor passes"; fi
}

check_config() {
  if [ -f "$AGENT_CONF" ]; then res config pass "${AGENT_CONF#"$REPO"/} exists"
  else res config fail "$(basename "$AGENT_CONF") does not exist" "run: agent-loop init"; fi
  if [ -n "$AGENT_VERIFY_CMD" ]; then res verify-cmd pass "AGENT_VERIFY_CMD is set: $AGENT_VERIFY_CMD"
  else res verify-cmd fail "AGENT_VERIFY_CMD is not set, so no agent's work is checked before it opens a PR" \
    "set AGENT_VERIFY_CMD in .agent-loop.conf (lint, type check and tests; init guesses it from package.json, go.mod, Cargo.toml or a Makefile)"; fi
}

# The commands that make an agent's work verifiable must pass on a clean checkout of the base branch, without the
# credentials the agents do not get. Otherwise every agent's Stop hook fails, whatever it wrote.
check_hermetic() {
  local out="$TMP/verify.out"
  if [ -z "$AGENT_VERIFY_CMD" ]; then res hermetic-verify warn "not run: AGENT_VERIFY_CMD is not set"; return; fi
  if ! git -C "$REPO" rev-parse --verify -q "$BASE_REF^{commit}" >/dev/null; then
    res hermetic-verify fail "the base branch $BASE_REF is not available locally" "run: git fetch origin"; return
  fi
  if ! git -C "$REPO" worktree add -q --detach "$TMP/wt" "$BASE_REF" >/dev/null 2>&1; then
    res hermetic-verify fail "could not create a temporary worktree of $BASE_REF"; return
  fi
  log "running AGENT_SETUP_CMD and AGENT_VERIFY_CMD in a clean checkout of $BASE_REF (without credentials)..."
  if [ -n "$AGENT_SETUP_CMD" ]; then
    (cd "$TMP/wt" && without_credentials bash -c "$AGENT_SETUP_CMD") >"$out" 2>&1 </dev/null || {
      res hermetic-verify fail "AGENT_SETUP_CMD fails on a clean checkout of $BASE_REF without credentials: $(last_lines "$out")" \
        "make the install work without the variables in AGENT_SCRUB_ENV, or take the one it needs out of AGENT_SCRUB_ENV"; return; }
  fi
  (cd "$TMP/wt" && without_credentials bash -c "$AGENT_VERIFY_CMD") >"$out" 2>&1 </dev/null || {
    res hermetic-verify fail "AGENT_VERIFY_CMD fails on a clean checkout of $BASE_REF without credentials: $(last_lines "$out")" \
      "make it pass on $BASE_REF with no secret or service in the environment (a test that needs one must skip itself), or fix what is broken"; return; }
  res hermetic-verify pass "AGENT_SETUP_CMD and AGENT_VERIFY_CMD pass on a clean checkout of $BASE_REF without credentials"
}

check_origin_head() {
  if git -C "$REPO" symbolic-ref --quiet refs/remotes/origin/HEAD >/dev/null 2>&1; then
    res origin-head pass "origin/HEAD is set ($(git -C "$REPO" symbolic-ref --quiet --short refs/remotes/origin/HEAD))"
  else res origin-head fail "origin/HEAD is not set, so the base branch is a guess" "run: git remote set-head origin --auto"; fi
}

# Branch protection (or a ruleset) requires a pull request. Reading classic protection needs admin rights: when GitHub
# refuses, that is a warning, not a failure.
check_protection() {
  local r rules out
  r=$(gh_repo 2>/dev/null) || { res branch-protection warn "could not read the repository from gh"; return; }
  if rules=$(gh api "repos/$r/rules/branches/$AGENT_BASE_BRANCH" 2>/dev/null) \
    && echo "$rules" | jq -e 'map(select(.type == "pull_request")) | length > 0' >/dev/null 2>&1; then
    res branch-protection pass "a ruleset requires a pull request on $AGENT_BASE_BRANCH"; return
  fi
  if out=$(gh api "repos/$r/branches/$AGENT_BASE_BRANCH/protection" 2>&1); then
    if echo "$out" | jq -e '.required_pull_request_reviews != null' >/dev/null 2>&1; then
      res branch-protection pass "branch protection requires a pull request on $AGENT_BASE_BRANCH"
    else
      res branch-protection fail "branch protection on $AGENT_BASE_BRANCH does not require a pull request" \
        "Settings > Branches (or Rules): require a pull request before merging; without it only the agents' deny rules stop a push to $AGENT_BASE_BRANCH"
    fi
    return
  fi
  case "$out" in
    *"Branch not protected"*)
      res branch-protection fail "$AGENT_BASE_BRANCH has no branch protection" \
        "Settings > Branches (or Rules): require a pull request before merging; without it only the agents' deny rules stop a push to $AGENT_BASE_BRANCH" ;;
    *) res branch-protection warn "could not read branch protection (it needs admin rights, or the plan has none): $(echo "$out" | grep -v '^{' | head -n 1)" \
      "check it yourself: a pull request should be required on $AGENT_BASE_BRANCH" ;;
  esac
}

check_labels() {
  local have l missing=""
  if ! have=$(gh label list --limit 200 --json name -q '.[].name' 2>/dev/null); then
    res labels warn "could not list the repository's labels (is gh authenticated, and does the repository have a GitHub remote?)"; return
  fi
  # shellcheck disable=SC2153  # L_RISK_HIGH and L_QUESTION exist only in versions that have them
  for l in $L_OK $L_WIP $L_BLOCKED $L_HUMAN $L_AUTOMERGE ${L_RISK_HIGH:-} ${L_QUESTION:-}; do
    echo "$have" | grep -qxF -- "$l" || missing="$missing${missing:+, }$l"
  done
  if [ -z "$missing" ]; then res labels pass "the loop's labels exist"
  else res labels fail "labels missing: $missing" "run: agent-loop labels"; fi
}

# The secrets a Claude workflow reads must exist as repository secrets (only their names are listed, never the values)
check_secrets() {
  local wf secrets names s missing=""
  wf=$(claude_workflows)
  if [ -z "$wf" ]; then res claude-secret pass "no Claude workflow, so no secret is needed"; return; fi
  # shellcheck disable=SC2086  # the file names have no spaces we care about
  secrets=$(grep -hE '^[[:space:]]*(claude_code_oauth_token|anthropic_api_key):' $wf 2>/dev/null | grep -oE 'secrets\.[A-Za-z_][A-Za-z0-9_]*' | sed 's/^secrets\.//' | sort -u || true)
  [ -n "$secrets" ] || { res claude-secret pass "the Claude workflow reads no repository secret"; return; }
  if ! names=$(gh secret list --json name -q '.[].name' 2>/dev/null); then
    res claude-secret warn "could not list the repository's secrets (it needs write access): check yourself that $(echo "$secrets" | tr '\n' ' ')exists"; return
  fi
  for s in $secrets; do echo "$names" | grep -qxF -- "$s" || missing="$missing${missing:+, }$s"; done
  if [ -z "$missing" ]; then res claude-secret pass "the repository secret(s) the Claude workflow reads exist: $(echo "$secrets" | tr '\n' ' ' | sed 's/ $//')"
  else res claude-secret fail "the Claude workflow reads $missing, which is not a repository secret" \
    "run: claude setup-token, then: gh secret set $(echo "$missing" | cut -d, -f1)  (organization secrets are not listed here: ignore this if yours is one)"; fi
}

# Signs that the project can deploy: then the agents need deny rules for those commands
check_deny() {
  local signs="" f n=0
  for f in vercel.json fly.toml netlify.toml serverless.yml; do [ -e "$REPO/$f" ] && signs="$signs${signs:+, }$f"; done
  if git -C "$REPO" ls-files '*.tf' 2>/dev/null | grep -q .; then signs="$signs${signs:+, }Terraform files"; fi
  if [ -f "$REPO/package.json" ] && jq -e '(.scripts // {}) | keys | map(select(test("deploy"; "i"))) | length > 0' "$REPO/package.json" >/dev/null 2>&1; then
    signs="$signs${signs:+, }a deploy script in package.json"
  fi
  if git -C "$REPO" ls-files 'scripts/deploy*' 'deploy.sh' 'deploy/*' 2>/dev/null | grep -q .; then signs="$signs${signs:+, }a deploy script"; fi
  # shellcheck disable=SC2034
  for f in ${AGENT_EXTRA_DENY[@]+"${AGENT_EXTRA_DENY[@]}"}; do n=$((n + 1)); done
  if [ -z "$signs" ]; then res deny-rules pass "no sign of deploy commands"
  elif [ "$n" -gt 0 ]; then res deny-rules pass "AGENT_EXTRA_DENY has $n rule(s) (this project shows: $signs)"
  else res deny-rules warn "this project shows signs of deploy commands ($signs) but AGENT_EXTRA_DENY is empty: an agent may run them" \
    "add deny rules to .agent-loop.conf, for example AGENT_EXTRA_DENY=(\"Bash(*vercel*)\" \"Bash(*terraform apply*)\")"; fi
}

check_review() {
  local wf name f
  wf=$(claude_workflows | grep -E 'review' | head -n 1 || true)
  if [ -z "$wf" ]; then
    for f in $(claude_workflows); do if grep -q 'pull_request' "$f"; then wf=$f; break; fi; done
  fi
  if [ -z "$wf" ]; then
    res review-check pass "no Claude review workflow"
    res automerge-review pass "no Claude review workflow, so no review bot to wait for"
    return
  fi
  name=$(first_job_name "$wf")
  if [ -n "$name" ] && ignored_check "$name"; then res review-check pass "the review check '$name' is in AGENT_IGNORE_CHECKS"
  else res review-check warn "the review check '${name:-?}' is not in AGENT_IGNORE_CHECKS: while the review runs or fails to start, the loop starts fix runs for it" \
    "set AGENT_IGNORE_CHECKS='${name:-<name of the review job>}' in .agent-loop.conf"; fi
  if [ "$AGENT_AUTOMERGE" != 1 ]; then res automerge-review pass "auto-merge is off (AGENT_AUTOMERGE=0)"
  elif [ -n "$AGENT_AUTOMERGE_REQUIRE_REVIEW" ]; then res automerge-review pass "auto-merge waits for the review of $AGENT_AUTOMERGE_REQUIRE_REVIEW"
  else res automerge-review warn "the project has a review workflow, but AGENT_AUTOMERGE_REQUIRE_REVIEW is empty: an issue labeled $L_AUTOMERGE is merged without waiting for the review" \
    "set AGENT_AUTOMERGE_REQUIRE_REVIEW='$AGENT_CLEAN_REVIEW_USER' in .agent-loop.conf"; fi
}

check_doctor
check_config
check_origin_head
check_hermetic
check_protection
check_labels
check_secrets
check_deny
check_review

summary=$(jq -s '{pass: map(select(.status == "pass")) | length, warn: map(select(.status == "warn")) | length, fail: map(select(.status == "fail")) | length}' "$RESULTS")
failed=$(echo "$summary" | jq -r .fail)
if [ "$json" = 1 ]; then
  jq -s . "$RESULTS"
else
  jq -r '(if .status == "pass" then "pass" elif .status == "warn" then "WARN" else "FAIL" end) as $s
    | "\($s)  \(.id): \(.message)" + (if .fix != "" and .status != "pass" then "\n        fix: \(.fix)" else "" end)' "$RESULTS"
  echo
  echo "$summary" | jq -r '"ready: \(.pass) passed, \(.warn) warning(s), \(.fail) failed"'
fi
[ "$failed" = 0 ]
