---
status: active
---

<!--
Plan template for agent-loop. Copy this file to docs/plans/<name>.md, replace the example items, and check it with
`agent-loop plan-lint`. (`agent-loop init --plan` puts it at docs/plans/TEMPLATE.md with `status: template`, which triage and
plan-lint skip.)

One item = one PR. Each item is a `### <ID> <title>` heading followed by the lines below:
  - Size: S | M | L          how big the PR is (S: a few files; M: a day of work; L: split it if you can)
  - Risk: low | high         high: CI, auth, migrations, infrastructure, lockfiles, anything that must not merge unseen
  - Owner: agent | human     human: only a person can do it (credentials, a live system, a decision)
  - Depends on: <IDs>        IDs of items that must be merged first (here or in another plan), or `none`
  - Touches: <globs>         optional: the files the item changes, so two items that overlap do not run at once
  - Acceptance:              at least one checkable line; each becomes a line of the issue's acceptance criteria
Triage turns Size and Risk into the labels size:s|m|l and risk:low|high, and `Owner: human` into the `human` label.
-->

# Plan title

Goal: one or two sentences on what is true when this plan is done.

## Open questions

- None yet. Write here what is undecided; an item that depends on an answer waits until it is decided.

## Items

### P1-01 Set up the project skeleton
- Size: S · Risk: low · Owner: agent
- Depends on: none
- Touches: app/**, package.json
- Acceptance:
  - [ ] `npm test` runs and passes with one placeholder test
  - [ ] The README says how to start the app

### P1-03 Upload a CSV and preview rows
- Size: S · Risk: low · Owner: agent
- Depends on: P1-01
- Touches: app/upload/**, lib/csv/**
- Acceptance:
  - [ ] Given a 10 MB CSV, the preview shows the first 50 rows within 2 s
  - [ ] An invalid file shows the error from docs/spec/errors.md
