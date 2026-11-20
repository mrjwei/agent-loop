---
name: plan-to-issues
description: Turn plan documents into PR-sized GitHub issues, and keep existing issues in line with the plans - acceptance criteria, dependencies, the files each touches, and which ones an agent can do alone. Use when the user asks to break a plan or spec into issues, sync issues with plans, triage the backlog, or plan the next batch of work.
argument-hint: [plan files or glob]
---

# Plans to issues

You compare the project's plans with its GitHub issues and propose changes. **Nothing is written to GitHub until the user
approves the list.**

## 1. Read

- Plans: the files the user names (`$ARGUMENTS`); otherwise `AGENT_PLANS_GLOB` from `.agent-loop.conf`; otherwise ask.
  Read them fully, including progress and notes sections.
- `CLAUDE.md`, `README.md`, `.agent-loop/prompts/project.md`, and `git log --oneline -50` (what already merged).
- Issues: `gh issue list --state open --limit 200 --json number,title,labels,body,author` and
  `gh issue list --state closed --limit 100 --json number,title`. Read the bodies of the ones a plan item might match.
- Labels: `gh label list`.

## 2. Work out the changes

1. **Coverage.** Every plan item that is not done has one open issue of about one PR in size. Do not create issues for
   done work, for work the plan defers, or for duplicates of open or closed issues.
2. **Accuracy.** Fix open issues whose title or body contradicts the plans or docs (superseded approach, wrong names,
   steps already done, missing acceptance criteria). Change only what is wrong; keep ticked checkboxes and people's notes.
   Leave `agent-wip` and `agent-blocked` issues alone, except for a comment.
3. **Structure.** For an issue that must wait for another, add `Depends on: #a, #b` to the body (and the "blocked by"
   relation if the user wants it). When the plan makes the files clear, add `Touches: src/billing/**, docs/api.md`.
4. **Who does it.** Mark an issue as one an agent can do alone only when all of these hold: the result is code or docs
   checkable with the project's own checks; no credentials, consoles, production data, deploys or real users; every
   requirement is decided and the acceptance criteria are written; it is about one PR; nothing in it needs a person. Give
   the rest the `human` label, or split mixed issues into an agent part and a `human` part (steps as checkboxes).

Write issues like the existing ones (title format, sections), with an `## Acceptance criteria` section and a link to the
plan.

## 3. Propose, then apply

Show a numbered table: action (`create` / `update` / `comment`), issue, what changes, and the plan line it is based on.
Be conservative: if the issues already match the plans, say so and stop.

Apply only the rows the user approves, with `gh issue create` / `gh issue edit` / `gh issue comment`. Do not add
`agent-ok` here; offer the `delegate-issue` skill for the issues marked as agent work. Never close issues, and never add
or remove `agent-wip`, `agent-blocked`, `agent-automerge` or `risk:high`.
