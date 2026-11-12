#!/usr/bin/env bash
# Have a headless Claude Code implement one issue and open a PR. With --fix, fix that PR's conflicts, failing checks and review feedback.
# Normally started by loop.sh. You can also run one issue by hand.
# Usage: agent-loop work <issue-number> [--fix]
set -euo pipefail
. "$(dirname "$0")/../lib/common.sh"

n=${1:?usage: agent-loop work <issue-number> [--fix]}
mode=implement
[ "${2:-}" = --fix ] && mode=fix
br=$(br_of "$n")
wt=$(wt_of "$n")
pf=$(pid_file "$n")

# Never run two agents for one issue (loop.sh writes the pid right after starting us; if it is ours, carry on)
if is_running "$n" && [ "$(cat "$pf")" != $$ ]; then die "#$n is already running (pid $(cat "$pf"))"; fi
echo $$ >"$pf"
trap 'rm -f "$pf"' EXIT

cd "$REPO"
git fetch origin --prune --quiet
pr=$(pr_of_branch "$br" open)
if [ "$mode" = implement ] && [ -n "$pr" ]; then die "#$n already has an open PR (#$pr). Use --fix"; fi
if [ "$mode" = fix ] && [ -z "$pr" ]; then die "#$n has no open PR"; fi

# --- Worktree (continue earlier work if it is still there) ---
resumed=0
if [ -d "$wt" ]; then
  resumed=1
elif git show-ref --verify --quiet "refs/heads/$br"; then
  git worktree add --quiet "$wt" "$br"
  resumed=1
elif git ls-remote --exit-code --heads origin "$br" >/dev/null; then
  git worktree add --quiet --track -b "$br" "$wt" "origin/$br"
  resumed=1
else
  # --no-track: otherwise the branch would track origin/<base>, and a plain `git push` would target the base branch
  git worktree add --quiet --no-track -b "$br" "$wt" "$BASE_REF"
fi
cd "$wt"
if [ "$mode" = fix ]; then
  # Take in anything a human pushed to the branch (if it cannot fast-forward, leave it to the agent)
  git fetch origin "$br" --quiet && git merge --ff-only --quiet "origin/$br" 2>/dev/null || true
fi

# --- Prompt ---
export T_N="$n" T_BRANCH="$br" T_WT="$wt" T_MARKER="$AGENT_MARKER" T_PR="$pr" T_RESUME="" T_REASONS=""
if [ "$mode" = implement ]; then
  # The previous run may have died early (e.g. setup failed): the attempt limit applies to that too
  if [ "$(count_get attempts "$n")" -ge "$AGENT_MAX_ATTEMPTS" ]; then
    block_issue "$n" "No PR was opened after ${AGENT_MAX_ATTEMPTS} attempts. Logs: .git/agent-loop/logs/issue-$n-*"
    exit 0
  fi
  label_add "$n" "$L_WIP"
  attempt=$(count_inc attempts "$n")
  if [ "$resumed" = 1 ]; then
    T_RESUME="This worktree already holds work from an earlier attempt (attempt $attempt of $AGENT_MAX_ATTEMPTS). Inspect \`git status\` and \`git log $BASE_REF..HEAD\` and continue from it instead of starting over."
  fi
  prompt=$(render_prompt implement)
else
  # Where to start reading feedback. Advanced only when a fix finishes (on failure or interruption the next run reads the same feedback)
  since=$(stamp_get handled "$n")
  started=$(now_iso)
  pr_json=$(agent_prs | jq -c --argjson n "$n" '.[] | select(.issue == $n)')
  [ -n "$pr_json" ] || die "could not read the state of the PR for #$n"
  reasons=$(pr_fix_reasons "$pr_json" "$since")
  T_REASONS=$(echo "$reasons" | jq -r '
    (if .conflict then "- The PR has merge conflicts with the base branch (mergeable=CONFLICTING).\n" else "" end)
    + (if (.failing | length) > 0 then "- Failing checks: \(.failing | join(", "))\n" else "" end)
    + (if (.feedback | length) > 0 then "- New review feedback (\(.feedback | length) item(s)):\n"
         + ([.feedback[] | "  --- \(.u) at \(.t), \(.where):\n\(.b | split("\n") | map("    " + .) | join("\n"))"] | join("\n"))
       else "" end)')
  export T_REASONS
  count_inc fixes "$n" >/dev/null
  prompt=$(render_prompt fix)
fi

# --- Run ---
if [ -n "$AGENT_SETUP_CMD" ]; then
  log "#$n: setup: $AGENT_SETUP_CMD"
  # A failure counts as a failed attempt (the next round tries again, then the issue becomes agent-blocked)
  bash -c "$AGENT_SETUP_CMD" || die "#$n: AGENT_SETUP_CMD failed in $wt (exit $?)"
fi
# For the Stop hook (verify-hook.sh --loop) that agent_settings passes
export AGENT_LOOP_RUN=1 AGENT_VERIFY_CMD AGENT_BASE_BRANCH
ts=$(date +%Y%m%d-%H%M%S)
stream="$STATE/logs/issue-$n-$ts-$mode.jsonl"   # the whole conversation
out="${stream%.jsonl}.json"                      # the final result only
log "#$n: starting $mode ($AGENT_MODEL / ${AGENT_EFFORT}, worktree ${wt})"
rc=0
printf '%s' "$prompt" | without_credentials claude -p --strict-mcp-config \
  --model "$AGENT_MODEL" --effort "$AGENT_EFFORT" \
  --permission-mode "$AGENT_PERMISSION_MODE" --max-turns "$AGENT_MAX_TURNS" --settings "$(agent_settings)" \
  --allowedTools "${WORKER_ALLOW[@]}" --disallowedTools "${WORKER_DENY[@]}" \
  --output-format stream-json --verbose --json-schema "$WORKER_SCHEMA" --name "agent #$n $mode" \
  >"$stream" 2>"$out.stderr" || rc=$?
result_of "$stream" >"$out" || true
pause_if_heavy_usage "$stream"

status=$(jq -r '.structured_output.status // empty' "$out" 2>/dev/null || true)
summary=$(jq -r '.structured_output.summary // .result // empty' "$out" 2>/dev/null || true)
reason=$(jq -r '.structured_output.blocked_reason // empty' "$out" 2>/dev/null || true)
sid=$(jq -r '.session_id // empty' "$out" 2>/dev/null || true)
log "#$n: $mode finished (exit code ${rc}, status=${status:-none}, $(jq -r '"\(.subtype // "?"), \(.num_turns // "?") turns, $\(.total_cost_usd // 0 | . * 100 | round / 100)"' "$out" 2>/dev/null || echo 'no result'))"
log "#$n: recording ${stream}; open the conversation with: cd $wt && claude -r $sid"
[ -n "$summary" ] && log "#$n: $summary"
resume_hint="worktree: \`$(basename "$wt")\`, conversation: \`claude -r $sid\` (inside the worktree)"

# --- Judge the outcome by GitHub's real state, not by what the agent says ---
pr_now=$(pr_of_branch "$br" open)
# Did it stop on a usage limit / overload before finishing? (a finished run has a status)
limited=0
if [ -z "$status" ] && resume_at=$(limit_resume_at "$stream"); then
  limited=1
  pause_until "$resume_at"
fi
if [ "$mode" = implement ]; then
  if [ -n "$pr_now" ]; then
    count_reset attempts "$n"
    stamp_set handled "$n" "$(now_iso)"   # only comments after this count as "new feedback"
    notify "PR opened (#${n})" "PR #$pr_now: ${summary:-}"
    exit 0
  fi
  if [ "$limited" = 1 ]; then
    # Not a failure: keep agent-wip and the worktree, and continue once the limit resets
    count_dec attempts "$n"
    log "#$n: stopped by a usage limit. Will continue after $(fmt_epoch "$(paused_until)")"
    exit 75
  fi
  if [ "$status" = blocked ]; then
    block_issue "$n" "${reason:-No reason was given} (${resume_hint})"
    exit 0
  fi
  if [ "$(count_get attempts "$n")" -ge "$AGENT_MAX_ATTEMPTS" ]; then
    block_issue "$n" "No PR was opened after ${AGENT_MAX_ATTEMPTS} attempts. ${reason:-$summary} (${resume_hint})"
    exit 0
  fi
  log "#$n: no PR is open. Will try again in the next round"
  exit 1
fi

# fix (loop.sh checks the round limit before starting the next fix)
if [ "$limited" = 1 ]; then
  # Not a failure. Neither the feedback start time nor the last state advanced, so the same reasons run again after the reset
  count_dec fixes "$n"
  log "#$n: stopped by a usage limit. Will fix again after $(fmt_epoch "$(paused_until)")"
  exit 75
fi
case "$status" in
  fixed | blocked)
    # Finished: advance the feedback start time and remember the current state (so the same reasons do not start another run)
    stamp_set handled "$n" "$started"
    stamp_set sig "$n" "$(pr_fix_reasons "$(agent_prs | jq -c --argjson n "$n" '.[] | select(.issue == $n)')" "$started" | jq -r .signature)"
    ;;
  *)
    # Failed or interrupted: remember nothing, so the next round runs again. loop.sh counts rounds and blocks at the limit
    log "#$n: did not finish the fix (status=${status:-none}). Will try again in the next round (round $(count_get fixes "$n")/${AGENT_MAX_FIXES})"
    exit 1
    ;;
esac
if [ "$status" = blocked ]; then
  run gh pr comment "$pr" --body "$AGENT_MARKER Stopped fixing this. ${reason:-$summary}" >/dev/null
  block_issue "$n" "PR #$pr: ${reason:-$summary} (${resume_hint})"
fi
exit 0
