#!/usr/bin/env bash
# How the loop is doing over time, from the finished runs recorded in history.jsonl (and the result files in the logs
# that it does not have yet). Computed here with jq; no model call.
# Usage: agent-loop stats [--days N] [--json]     (default 7 days)
#        agent-loop stats --digest                a short text for the last 24 hours: PRs opened, issues blocked with
#                                                 their reasons, PRs waiting for review, spend (needs gh for the PRs)
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
    | ($ev[0] | map(select((.time | fromdateiso8601) >= $since))) as $runs
    | ($ls[0] | map(select(.type == "blocked" and (.time | fromdateiso8601) >= $since))) as $blk
    | ([$runs[] | select(.outcome == "pr_opened")]) as $opened
    | ([$runs[] | select(.mode == "fix")] | length) as $fixes
    | ([$runs[].turns] | add // 0) as $turns
    | ([$runs[].cost] | add // 0) as $cost
    | def r2: . * 100 | round / 100;
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
       cost_per_pr_usd: (if ($opened | length) > 0 then ($cost / ($opened | length) | r2) else null end)}'
}

if [ "$json" = 1 ]; then summary; exit 0; fi

if [ "$digest" = 1 ]; then
  s=$(summary)
  echo "agent-loop, last 24 hours"
  echo "$s" | jq -r '"PRs opened: \(.prs_opened)\(if (.prs | length) > 0 then " (" + (.prs | map("#\(.)") | join(", ")) + ")" else "" end)"'
  echo "$s" | jq -r 'if .issues_blocked == 0 then "Issues blocked: none"
    else "Issues blocked: \(.issues_blocked)\n" + (.blocked | map("  #\(.issue): \(.reason[0:160])") | join("\n")) end'
  waiting=$(agent_prs 2>/dev/null | jq -r '.[] | "  PR #\(.pr) (issue #\(.issue))"' 2>/dev/null || true)
  if [ -n "$waiting" ]; then echo "PRs waiting for review:"; echo "$waiting"; else echo "PRs waiting for review: none"; fi
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
  "Cost (API-equivalent): $\(.cost_usd) in total, \(if .cost_per_pr_usd == null then "-" else "$\(.cost_per_pr_usd)" end) per PR"'
