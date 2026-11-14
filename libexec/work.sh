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
escalate=0   # set below on the last implement attempt and the last fix round
export T_N="$n" T_BRANCH="$br" T_WT="$wt" T_MARKER="$AGENT_MARKER" T_PR="$pr" T_RESUME="" T_REASONS=""
if [ "$mode" = implement ]; then
  # The previous run may have died early (e.g. setup failed): the attempt limit applies to that too
  if [ "$(count_get attempts "$n")" -ge "$AGENT_MAX_ATTEMPTS" ]; then
    block_issue "$n" "No PR was opened after ${AGENT_MAX_ATTEMPTS} attempts. Logs: .git/agent-loop/logs/issue-$n-*" implement
    exit 0
  fi
  label_add "$n" "$L_WIP"
  attempt=$(count_inc attempts "$n")
  if [ "$resumed" = 1 ]; then
    T_RESUME="This worktree already holds work from an earlier attempt (attempt $attempt of $AGENT_MAX_ATTEMPTS). Inspect \`git status\` and \`git log $BASE_REF..HEAD\` and continue from it instead of starting over."
  fi
  if [ "$attempt" -gt 1 ]; then
    T_RESUME="${T_RESUME:+$T_RESUME

}$(previous_run_note "$n" implement)"
  fi
  [ "$attempt" -ge "$AGENT_MAX_ATTEMPTS" ] && escalate=1
  export T_RESUME
  prompt=$(render_prompt implement)
else
  # Where to start reading feedback. Advanced only when a fix finishes (on failure or interruption the next run reads the same feedback)
  since=$(stamp_get handled "$n")
  started=$(now_iso)
  pr_json=$(agent_prs | jq -c --argjson n "$n" '.[] | select(.issue == $n)')
  [ -n "$pr_json" ] || die "could not read the state of the PR for #$n"
  reasons=$(pr_fix_reasons "$pr_json" "$since")
  head_before=$(git ls-remote origin "refs/heads/$br" | cut -f1)   # to see afterwards whether the agent pushed anything
  T_REASONS=$(echo "$reasons" | jq -r '
    (if .conflict then "- The PR has merge conflicts with the base branch (mergeable=CONFLICTING).\n" else "" end)
    + (if (.failing | length) > 0 then "- Failing checks: \(.failing | join(", "))\n" else "" end)
    + (if (.feedback | length) > 0 then "- New review feedback (\(.feedback | length) item(s)):\n"
         + ([.feedback[] | "  --- \(.u) at \(.t), \(.where):\n\(.b | split("\n") | map("    " + .) | join("\n"))"] | join("\n"))
       else "" end)')
  export T_REASONS
  round=$(count_inc fixes "$n")
  if [ "$round" -gt 1 ]; then T_RESUME=$(previous_run_note "$n" fix); fi
  [ "$round" -ge "$AGENT_MAX_FIXES" ] && escalate=1
  export T_RESUME
  prompt=$(render_prompt fix)
fi

# --- Run ---
if [ -n "$AGENT_SETUP_CMD" ]; then
  log "#$n: setup: $AGENT_SETUP_CMD"
  # A failure counts as a failed attempt (the next round tries again, then the issue becomes agent-blocked).
  # Without credentials, like the agent: an install runs scripts from the worktree, which may hold the agent's code
  without_credentials bash -c "$AGENT_SETUP_CMD" || die "#$n: AGENT_SETUP_CMD failed in $wt (exit $?)"
fi
# For the Stop hook (verify-hook.sh --loop) that agent_settings passes
export AGENT_LOOP_RUN=1 AGENT_VERIFY_CMD AGENT_BASE_BRANCH
ts=$(date +%Y%m%d-%H%M%S)
stream="$STATE/logs/issue-$n-$ts-$mode.jsonl"   # the whole conversation
out="${stream%.jsonl}.json"                      # the final result only
# The last attempt (AGENT_MAX_ATTEMPTS) or fix round (AGENT_MAX_FIXES) may use a stronger model and more effort
run_model=$AGENT_MODEL run_effort=$AGENT_EFFORT
if [ "$escalate" = 1 ]; then
  [ -z "$AGENT_ESCALATE_MODEL" ] || run_model=$AGENT_ESCALATE_MODEL
  [ -z "$AGENT_ESCALATE_EFFORT" ] || run_effort=$AGENT_ESCALATE_EFFORT
fi
# For the Stop hook: while this file exists, the last verify run failed
verify_mark="${stream%.jsonl}.verify-failed"
rm -f "$verify_mark"
export AGENT_LOOP_VERIFY_MARK="$verify_mark"
cost_args=()
if [ -n "$AGENT_MAX_COST_PER_RUN" ]; then
  if claude_has_cost_cap; then cost_args=(--max-budget-usd "$AGENT_MAX_COST_PER_RUN")
  else log "#$n: warning: this claude CLI has no --max-budget-usd, so AGENT_MAX_COST_PER_RUN is skipped"; fi
fi
log "#$n: starting $mode ($run_model / ${run_effort}$([ "$escalate" = 1 ] && echo ", last chance"), worktree ${wt}, limit ${AGENT_RUN_TIMEOUT}s)"
rc=0 timed_out=0
# The agent runs as the leader of its own process group (a background subshell under job control), so that the
# timeout below can stop claude and everything it started without stopping this script
set -m
(printf '%s' "$prompt" | without_credentials claude -p --strict-mcp-config \
  --model "$run_model" --effort "$run_effort" \
  --permission-mode "$AGENT_PERMISSION_MODE" --max-turns "$AGENT_MAX_TURNS" --settings "$(agent_settings)" \
  --allowedTools "${WORKER_ALLOW[@]}" --disallowedTools "${WORKER_DENY[@]}" ${cost_args[@]+"${cost_args[@]}"} \
  --output-format stream-json --verbose --json-schema "$WORKER_SCHEMA" --name "agent #$n $mode") \
  >"$stream" 2>"$out.stderr" &
agent_pid=$!
set +m
# `agent-loop kill` stops this script's process group, which no longer contains the agent: pass the signal on to it
trap 'kill -TERM -- "-$agent_pid" 2>/dev/null || true; exit 143' TERM INT HUP
started_at=$SECONDS
while kill -0 "$agent_pid" 2>/dev/null; do
  if [ "$AGENT_RUN_TIMEOUT" -gt 0 ] && [ $((SECONDS - started_at)) -ge "$AGENT_RUN_TIMEOUT" ]; then
    timed_out=1
    log "#$n: $mode exceeded AGENT_RUN_TIMEOUT (${AGENT_RUN_TIMEOUT}s); stopping the agent"
    stop_agent "$agent_pid"
    sleep 2
    kill -KILL -- "-$agent_pid" 2>/dev/null || true
    break
  fi
  sleep 1
done
wait "$agent_pid" 2>/dev/null || rc=$?
result_of "$stream" >"$out" || true
pause_if_heavy_usage "$stream"

status=$(jq -r '.structured_output.status // empty' "$out" 2>/dev/null || true)
summary=$(jq -r '.structured_output.summary // .result // empty' "$out" 2>/dev/null || true)
reason=$(jq -r '.structured_output.blocked_reason // empty' "$out" 2>/dev/null || true)
if [ "$timed_out" = 1 ]; then
  # A run that was stopped did not finish, whatever its last message said; the attempt or fix round stays counted
  status="" reason="The run was stopped after ${AGENT_RUN_TIMEOUT}s (AGENT_RUN_TIMEOUT)."
fi
sid=$(jq -r '.session_id // empty' "$out" 2>/dev/null || true)
log "#$n: $mode finished (exit code ${rc}, status=${status:-none}, $(jq -r '"\(.subtype // "?"), \(.num_turns // "?") turns, $\(.total_cost_usd // 0 | . * 100 | round / 100)"' "$out" 2>/dev/null || echo 'no result'))"
log "#$n: recording ${stream}; open the conversation with: cd $wt && claude -r $sid"
[ -n "$summary" ] && log "#$n: $summary"
resume_hint="worktree: \`$(basename "$wt")\`, conversation: \`claude -r $sid\` (inside the worktree)"

# --- Judge the outcome by GitHub's real state, not by what the agent says ---
pr_now=$(pr_of_branch "$br" open)
# Did it stop on a usage limit / overload before finishing? (a finished run has a status)
limited=0
if [ "$timed_out" = 0 ] && [ -z "$status" ] && resume_at=$(limit_resume_at "$stream"); then
  limited=1
  pause_until "$resume_at"
fi
# One line in history.jsonl per finished run (kept when the logs are deleted), written when this script exits
outcome=failed
record_run() {
  local turns cost
  turns=$(jq -r '.num_turns // 0' "$out" 2>/dev/null || true); cost=$(jq -r '.total_cost_usd // 0' "$out" 2>/dev/null || true)
  history_add "$(jq -nc --arg run "$(basename "${out%.json}")" --arg t "$(now_iso)" --argjson n "$n" --arg mode "$mode" \
    --arg outcome "$outcome" --arg status "$status" --arg pr "${pr_now:-$pr}" --arg model "$run_model" \
    --arg reason "${reason:-}" --argjson timed_out "$([ "$timed_out" = 1 ] && echo true || echo false)" \
    --argjson turns "${turns:-0}" --argjson cost "${cost:-0}" \
    '{run: $run, time: $t, issue: $n, mode: $mode, outcome: $outcome, status: (if $status == "" then null else $status end),
      pr: (if $pr == "" then null else ($pr | tonumber) end), turns: $turns, cost: $cost, model: $model, timed_out: $timed_out,
      reason: (if $reason == "" then null else $reason[0:300] end)}' 2>/dev/null)" || true
}
trap 'rm -f "$pf"; record_run' EXIT
# How the run ended, for the next attempt's prompt (previous_run_note)
if [ "$timed_out" = 1 ]; then end_note="it was stopped after ${AGENT_RUN_TIMEOUT}s (AGENT_RUN_TIMEOUT)"
elif [ "$(jq -r '.subtype // empty' "$out" 2>/dev/null)" = error_max_turns ]; then end_note="it hit the turn limit (AGENT_MAX_TURNS=$AGENT_MAX_TURNS)"
elif [ -f "$verify_mark" ]; then end_note="the checks (AGENT_VERIFY_CMD) were still failing when it stopped"
elif [ "$limited" = 1 ]; then end_note="it was stopped by a usage limit"
elif [ -n "$status" ]; then end_note="it reported status: $status"
else end_note="it ended without a result"; fi
printf '%s\n' "$end_note" >"${stream%.jsonl}.end"
if [ "$mode" = implement ]; then
  if [ -n "$pr_now" ]; then
    outcome=pr_opened
    count_reset attempts "$n"
    stamp_set handled "$n" "$(now_iso)"   # only comments after this count as "new feedback"
    cc=$(mention)
    # A comment that mentions AGENT_NOTIFY_USER: GitHub sends the push and the email (the PR itself was opened by the agent)
    [ -z "$cc" ] || run gh pr comment "$pr_now" --body "$AGENT_MARKER PR opened for #$n. Ready for review. $cc" >/dev/null || true
    notify "PR opened (#${n})" "PR #$pr_now: ${summary:-}" "$(pr_url "$pr_now")"
    # The PR body must show the evidence for every acceptance criterion (prompts/implement.md). If the section is
    # missing, say so once on the PR; no further run is started for it.
    if [ "$(stamp_get criteria "$n" "")" != "$pr_now" ]; then
      stamp_set criteria "$n" "$pr_now"
      if ! gh pr view "$pr_now" --json body -q .body 2>/dev/null | grep -Eiq '^[[:space:]]*(#{1,6}|[*][*])[[:space:]]*acceptance criteria'; then
        run gh pr comment "$pr_now" --body "$AGENT_MARKER This PR body has no \`## Acceptance criteria\` section. It should list each acceptance criterion of #$n with its evidence (the test, or the file and lines) or \`not done\`, so that a reviewer can see what is covered without reading the diff." >/dev/null || true
      fi
    fi
    exit 0
  fi
  if [ "$limited" = 1 ]; then
    # Not a failure: keep agent-wip and the worktree, and continue once the limit resets
    outcome=limit
    count_dec attempts "$n"
    log "#$n: stopped by a usage limit. Will continue after $(fmt_epoch "$(paused_until)")"
    exit 75
  fi
  if [ "$status" = blocked ]; then
    outcome=blocked
    block_issue "$n" "${reason:-No reason was given} (${resume_hint})" implement
    exit 0
  fi
  if [ "$(count_get attempts "$n")" -ge "$AGENT_MAX_ATTEMPTS" ]; then
    outcome=blocked
    block_issue "$n" "No PR was opened after ${AGENT_MAX_ATTEMPTS} attempts. ${reason:-$summary} (${resume_hint})" implement
    exit 0
  fi
  log "#$n: no PR is open. Will try again in the next round"
  exit 1
fi

# fix (loop.sh checks the round limit before starting the next fix)
if [ "$limited" = 1 ]; then
  # Not a failure. Neither the feedback start time nor the last state advanced, so the same reasons run again after the reset
  outcome=limit
  count_dec fixes "$n"
  log "#$n: stopped by a usage limit. Will fix again after $(fmt_epoch "$(paused_until)")"
  exit 75
fi
case "$status" in
  fixed | blocked)
    # Finished: advance the feedback start time and remember the current state (so the same reasons do not start another run)
    outcome=$status
    stamp_set handled "$n" "$started"
    lesson_feedback "$n" "$(echo "$reasons" | jq -c .feedback)"   # what the reviewers asked for, for `agent-loop lessons`
    pr_json=$(agent_prs | jq -c --argjson n "$n" '.[] | select(.issue == $n)')
    if [ -z "$pr_json" ]; then log "#$n: PR #$pr is no longer open; nothing more to do"; exit 0; fi
    after=$(pr_fix_reasons "$pr_json" "$started")
    stamp_set sig "$n" "$(echo "$after" | jq -r .signature)"
    ;;
  *)
    # Failed or interrupted: remember nothing, so the next round runs again. loop.sh counts rounds and blocks at the limit
    log "#$n: did not finish the fix (status=${status:-none}). Will try again in the next round (round $(count_get fixes "$n")/${AGENT_MAX_FIXES})"
    exit 1
    ;;
esac
if [ "$status" = blocked ]; then
  run gh pr comment "$pr" --body "$AGENT_MARKER Stopped fixing this. ${reason:-$summary}" >/dev/null
  block_issue "$n" "PR #$pr: ${reason:-$summary} (${resume_hint})" fix
elif [ "$(git ls-remote origin "refs/heads/$br" | cut -f1)" = "$head_before" ] &&
  [ "$(echo "$after" | jq '.conflict or (.failing | length > 0)')" = true ]; then
  # It reported "fixed" but pushed nothing, and the PR still has a conflict or a failing check. The state above is
  # remembered as handled, so no further fix run would start: hand it to a human instead of leaving the PR to wait.
  outcome=blocked
  left=$(echo "$after" | jq -r '[(if .conflict then "merge conflicts" else empty end), (.failing[] | "failing check `\(.)`")] | join(", ")')
  run gh pr comment "$pr" --body "$AGENT_MARKER The fix run pushed nothing, and this PR still has: ${left}. Waiting for a human. ${summary}" >/dev/null
  block_issue "$n" "PR #$pr still has ${left}, and the last fix run pushed nothing (it reported: ${summary:-no summary}). If a check is flaky, re-run it; otherwise push a fix or say what to do. (${resume_hint})" fix
fi
exit 0
