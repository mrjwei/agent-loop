#!/usr/bin/env bash
# Print why agents stopped and what reviewers asked for, newest first, so that recurring ones can become rules in
# .agent-loop/prompts/project.md. Nobody summarizes this: the person decides what becomes a rule (no model call, no cost).
# Usage: agent-loop lessons [--days N]      (default 30)
set -euo pipefail
. "$(dirname "$0")/../lib/common.sh"

days=30
while [ $# -gt 0 ]; do
  case "$1" in
    --days) days=${2:-}; shift 2 || die "--days needs a number" ;;
    --days=*) days=${1#--days=}; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
case "$days" in '' | *[!0-9]*) die "--days needs a number of days" ;; esac

echo "Lessons from the last $days days (newest first). Turn the ones that keep coming back into rules in:"
echo "  ${PROMPTS_DIR#"$REPO"/}/project.md   (${PROMPTS_DIR}/project.md)"
echo
if [ ! -s "$LESSONS_FILE" ]; then echo "(nothing recorded yet)"; exit 0; fi
# Epoch seconds, then the text; the time is formatted here so that it is the local time like the loop's log
jq -rs --argjson days "$days" 'map(select((.time | fromdateiso8601) >= (now - $days * 86400))) | reverse | .[]
    | "\(.time | fromdateiso8601)\t#\(.issue)\t\(.mode // "" | if . == "" then "-" else . end)\t" +
      (if .type == "feedback" then "feedback from \(.author) (\(.where)): \(.feedback)"
       else "stopped: \(.reason | split("\n")[0])" end)' "$LESSONS_FILE" |
  while IFS=$'\t' read -r when issue mode text; do
    printf '%s  %-6s %-10s %s\n' "$(fmt_epoch "$when")" "$issue" "$mode" "$text"
  done
