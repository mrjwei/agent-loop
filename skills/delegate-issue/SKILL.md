---
name: delegate-issue
description: Check whether a GitHub issue is fit for the unattended agent-loop and, with the user's approval, label it so the background loop picks it up. Use when the user wants to hand an issue to the loop, run it in the background, or asks whether an issue can be delegated or auto-merged.
argument-hint: <issue-number> [more numbers]
---

# Delegate an issue to the background loop

The background loop (`agent-loop start`) works only on issues labeled `agent-ok`, without anyone to answer questions. An
issue that is not ready comes back as `agent-blocked` after a wasted run. Your job is to catch that before it happens.
Do this for each issue in `$ARGUMENTS`.

## 1. Check

Read the issue (`gh issue view <n> --comments`), `CLAUDE.md`, `.agent-loop/prompts/project.md`, and the code the issue
names. Then grade it:

| Check | Ready when |
|---|---|
| Decided | No open question in the issue or the docs affects it |
| Acceptance criteria | Written in the issue and checkable: a test or a file can show each one |
| Self-contained | No credentials, consoles, production data, deploys, real users, or eyes on a screen |
| Size | About one PR (rough guide: under ~300 changed lines) |
| Dependencies | `Depends on:` lists every issue that must merge first |
| Files | A `Touches:` line, when the files are clear, so the loop does not run it beside an overlapping issue |
| Setup | `.agent-loop.conf` exists, with `AGENT_VERIFY_CMD` set |

## 2. Report and fix the gaps

Show the table with ✅ / ❌ and one line per gap. Offer to fix the gaps you can (write acceptance criteria, add
`Depends on:` / `Touches:`), and ask the user about the ones that need a decision. Edit the issue only after a yes.

## 3. Label

When every row passes and the user agrees, add `agent-ok` (`gh issue edit <n> --add-label agent-ok`).

Then ask about merging, and **never decide it yourself**:

- `agent-automerge` lets the loop merge the PR once every check passes. Suggest it only for low-risk work (docs, tests,
  small well-specified changes), and add it only when the user says so.
- Suggest `risk:high` when the issue touches auth, payments, migrations, infrastructure, CI or public APIs.

Finish with what the loop will do next: it starts the issue in its next round once its dependencies are closed. If no
loop is running, the user starts one with `agent-loop start`, or runs just this issue with `agent-loop work <n>`.
