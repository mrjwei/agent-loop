---
name: harvest-lessons
description: Find the problems that keep recurring - why agents got blocked and what reviewers keep asking for - and propose project rules that would prevent them, written into CLAUDE.md or the agent-loop project rules after the user approves. Use when the user asks what keeps going wrong, wants to improve the agents' instructions, or asks to review lessons or blocked issues.
argument-hint: [days, default 30]
---

# Harvest lessons into rules

The same missing rule (an undocumented convention, a command that needs a person) blocks issue after issue. You find
those patterns and propose rules. **The user decides which ones become rules.**

## 1. Gather (last `$ARGUMENTS` days, default 30)

- agent-loop's record, if the project uses it:
  `jq -c . "$(git rev-parse --path-format=absolute --git-common-dir)/agent-loop/lessons.jsonl"`. Each line has `time`,
  `issue`, `mode`, and either `type: "feedback"` with `author`, `where`, `feedback`, or a stop `reason`.
  `agent-loop lessons --days N` prints the same thing.
- Blocked issues: `gh issue list --label agent-blocked --state all --limit 50 --json number,title`, then read the loop's
  "Stopped working on this" comments.
- Review feedback on recent merged PRs: `gh pr list --state merged --limit 30 --json number,title`, then
  `gh api repos/{owner}/{repo}/pulls/<pr>/comments` and `gh pr view <pr> --json reviews,comments`. Skip comments that start
  with `🤖 agent:` and clean `No issues found.` reviews.

## 2. Find what recurs

Group the items by underlying cause, not by wording. Keep a group only when it appears at least twice, or once with a high
cost (a blocked issue, a reverted PR). Drop what an existing rule in `CLAUDE.md` or `.agent-loop/prompts/project.md`
already covers, unless the rule is evidently not working, in which case propose a clearer wording.

## 3. Propose

For each group, show:

- **Pattern**: one line, with the issue and PR numbers.
- **Rule**: the exact text to add, short and checkable ("Run `make db-reset` before the integration tests"), not advice
  ("be careful with the database").
- **Where**: `CLAUDE.md` for rules that hold for every session; `.agent-loop/prompts/project.md` for rules only the
  background agents need (what counts as blocked, what they must never run); `AGENT_EXTRA_DENY` in `.agent-loop.conf` for
  commands that must be denied, not just discouraged.

Edit the files only for the rules the user approves, and leave the commit to them.
