#!/usr/bin/env bash
# How the loop is doing over time, from the finished runs recorded in history.jsonl (and the result files in the logs
# that it does not have yet). Computed here with jq; no model call.
# Usage: agent-loop stats [--days N] [--json]     (default 7 days)
#        agent-loop stats --digest                a short text for the last 24 hours: PRs opened, issues blocked with
#                                                 their reasons, what waits for you (high-risk agent PRs, blocked issues,
#                                                 open questions), PRs the loop merged, spend (needs gh)
set -euo pipefail
. "$(dirname "$0")/../lib/common.sh"

days=7 json=0 digest=0
while [ $# -gt 0 ]; do
  case "$1" in
    --days) days=${2:-}; shift 2 || die "--days needs a number" ;;
    --days=*) days=${1#--days=}; shift ;;
    --json) json=1; shift ;;
    --digest) digest=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
case "$days" in '' | *[!0-9]*) die "--days needs a number of days" ;; esac
[ "$digest" = 0 ] || days=1

tmp=$(mktemp -d "$STATE/stats.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
history_events >"$tmp/events.json"
if [ -s "$LESSONS_FILE" ]; then jq -s . "$LESSONS_FILE" >"$tmp/lessons.json"; else echo '[]' >"$tmp/lessons.json"; fi

# The numbers for the last $days days, as JSON
summary() {
  jq -n --argjson days "$days" --slurpfile ev "$tmp/events.json" --slurpfile ls "$tmp/lessons.json" '
    (now - $days * 86400) as $since
    | ($ev[0] | map(select(.mode != "pr" and (.time | fromdateiso8601) >= $since))) as $runs
    | ($ev[0] | map(select(.mode == "pr" and (.time | fromdateiso8601) >= $since))) as $pre
    | ([$pre[] | select(.outcome == "merged")]) as $merged
    | ([$merged[] | select(.opened != null and .closed != null)
        | ((.closed | fromdateiso8601) - (.opened | fromdateiso8601)) / 3600] | sort) as $hours
    | ([$merged[] | select(.merged_by == "loop")]) as $byloop
    | ($ls[0] | map(select(.type == "blocked" and (.time | fromdateiso8601) >= $since))) as $blk
    | ([$runs[] | select(.outcome == "pr_opened")]) as $opened
    | ([$runs[] | select(.mode == "fix")] | length) as $fixes
    | ([$runs[].turns] | add // 0) as $turns
    | ([$runs[].cost] | add // 0) as $cost
    | def r2: . * 100 | round / 100;
      def r1: . * 10 | round / 10;
      def pct($p): if length == 0 then null else .[([((length * $p) | ceil) - 1, 0] | max)] | r1 end;   # nearest rank
      {days: $days,
       runs_total: ($runs | length),
       runs: ($runs | group_by(.mode) | map({key: .[0].mode, value: (group_by(.outcome) | map({key: .[0].outcome, value: length}) | from_entries)}) | from_entries),
       prs_opened: ($opened | length),
       prs: ([$opened[] | .pr | select(. != null)] | sort),
       issues_blocked: ($blk | map(.issue) | unique | length),
       blocked: ($blk | map({issue, mode, reason: (.reason | split("\n")[0])})),
       fix_runs: $fixes,
       fix_rounds_per_pr: (if ($opened | length) > 0 then ($fixes / ($opened | length) | r2) else null end),
       turns: $turns,
       turns_per_pr: (if ($opened | length) > 0 then ($turns / ($opened | length) | round) else null end),
       cost_usd: ($cost | r2),
       cost_per_pr_usd: (if ($opened | length) > 0 then ($cost / ($opened | length) | r2) else null end),
       prs_merged: ($merged | length),
       prs_closed: ([$pre[] | select(.outcome == "closed")] | length),
       merge_hours_median: ($hours | pct(0.5)),
       merge_hours_p90: ($hours | pct(0.9)),
       merged_by_loop: ($byloop | length),
       merged_by_loop_share: (if ($merged | length) > 0 then (($byloop | length) / ($merged | length) | r2) else null end),
       merged_by_loop_prs: ([$byloop[].pr] | sort),
       reverts: ([$pre[] | select(.outcome == "reverted")] | length),
       reverted_prs: ([$pre[] | select(.outcome == "reverted") | .pr] | unique)}'
}

# What waits for a person, one line each: agent PRs that need a person (high risk, or not judged yet; all agent PRs while
# the policy only merges labeled PRs), open blocked issues, open questions
waiting_for_you() {
  local prs policy pr n risk
  prs=$(agent_prs 2>/dev/null || echo '[]')
  policy=$AGENT_AUTOMERGE_POLICY
  [ "$AGENT_AUTOMERGE" = 1 ] || policy=off
  echo "$prs" | jq -r --arg policy "$policy" --arg dir "$STATE/stamp" '.[]? | "\(.pr) \(.issue)"' 2>/dev/null |
    while read -r pr n; do
      risk=$(stamp_get risk "$n" "")
      case "$policy" in
        risk | shadow) [ "$risk" = low ] && continue
                       echo "  PR #$pr (issue #$n): $(if [ "$risk" = high ]; then echo "high risk"; else echo "risk not judged yet"; fi)" ;;
        *) echo "  PR #$pr (issue #$n): waiting for review" ;;
      esac
    done
  gh issue list --state open --label "$L_BLOCKED" --limit 50 --json number,title 2>/dev/null |
    jq -r '.[]? | "  #\(.number) blocked: \(.title)"' 2>/dev/null || true
  gh issue list --state open --label "${L_QUESTION:-question}" --limit 50 --json number,title 2>/dev/null |
    jq -r '.[]? | "  #\(.number) question: \(.title)"' 2>/dev/null || true
}

if [ "$json" = 1 ]; then summary; exit 0; fi

if [ "$digest" = 1 ]; then
  s=$(summary)
  echo "agent-loop, last 24 hours"
  echo "$s" | jq -r '"PRs opened: \(.prs_opened)\(if (.prs | length) > 0 then " (" + (.prs | map("#\(.)") | join(", ")) + ")" else "" end)"'
  echo "$s" | jq -r 'if .issues_blocked == 0 then "Issues blocked: none"
    else "Issues blocked: \(.issues_blocked)\n" + (.blocked | map("  #\(.issue): \(.reason[0:160])") | join("\n")) end'
  waiting=$(waiting_for_you)
  if [ -n "$waiting" ]; then echo "Waiting for you:"; echo "$waiting"; else echo "Waiting for you: nothing"; fi
  echo "$s" | jq -r '"Merged by the loop: " + (if (.merged_by_loop_prs | length) > 0 then (.merged_by_loop_prs | map("#\(.)") | join(", ")) else "none" end)'
  echo "$s" | jq -r 'if .reverts > 0 then "Reverted: " + (.reverted_prs | map("#\(.)") | join(", ")) else empty end'
  echo "$s" | jq -r '"Spend (API-equivalent): $\(.cost_usd)"'
  exit 0
fi

summary | jq -r '
  "agent-loop stats, last \(.days) days",
  "Runs: \(.runs_total)" + (if .runs_total > 0 then " (" + (.runs | to_entries | map("\(.key) \(.value | [.[]] | add)") | join(", ")) + ")" else "" end),
  (.runs | to_entries[] | "  \(.key): " + (.value | to_entries | map("\(.key) \(.value)") | join(", "))),
  "PRs opened: \(.prs_opened)",
  "Issues blocked: \(.issues_blocked)" + (if (.blocked | length) > 0 then " (" + (.blocked | map("#\(.issue)") | unique | join(", ")) + ")" else "" end),
  "Fix runs per PR: \(.fix_rounds_per_pr // "-")",
  "Turns: \(.turns) in total, \(.turns_per_pr // "-") per PR",
  "Cost (API-equivalent): $\(.cost_usd) in total, \(if .cost_per_pr_usd == null then "-" else "$\(.cost_per_pr_usd)" end) per PR",
  "PRs merged: \(.prs_merged)" + (if .prs_merged > 0 then " (\(.merged_by_loop) by the loop, \(.merged_by_loop_share * 100 | round)%)" else "" end) + ", closed without merging: \(.prs_closed)",
  "Time to merge: " + (if .merge_hours_median == null then "-" else "median \(.merge_hours_median)h, 90th percentile \(.merge_hours_p90)h" end),
  "Reverted: \(.reverts)" + (if .reverts > 0 then " (" + (.reverted_prs | map("#\(.)") | join(", ")) + ")" else "" end)'
