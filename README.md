# agent-loop

An autonomous issue-to-PR loop driven by headless [Claude Code](https://claude.com/claude-code). Run it in a project's git checkout and it:

1. cleans up the worktrees and branches of merged or closed PRs,
2. fixes agent PRs that have merge conflicts, failing checks or new review feedback,
3. optionally compares your plan files with the GitHub issues and keeps them in sync (triage),
4. starts agents in parallel for issues labeled `agent-ok` whose dependencies are closed, each in its own git worktree, ending in a PR.

You do two things: **merge PRs** and **answer blocked issues**. Merging a PR closes the dependency of the issues waiting on it, so the next round starts them. AI cost only accrues while an agent runs.

It is a set of bash scripts (macOS bash 3.2 compatible) around `claude -p`, `gh`, `git` and `jq`.

## Requirements

- `git` ≥ 2.31, `jq`, [`gh`](https://cli.github.com) (authenticated: `gh auth login`), and the [`claude`](https://claude.com/claude-code) CLI
- A GitHub repository with an `origin` remote. Protect the base branch so nothing can be pushed to it without a PR; the safety model relies on this.
- macOS or Linux. Keep-awake (`caffeinate`) is macOS-only and skipped elsewhere.

## Install

```bash
git clone <this repo> ~/tools/agent-loop
cd ~/tools/agent-loop && make install            # copies to ~/.local/share/agent-loop, links ~/.local/bin/agent-loop
# or: make install PREFIX=/usr/local, or symlink bin/agent-loop yourself to track the clone
```

Or vendor it into a project as a submodule (`git submodule add <url> tools/agent-loop`) and call `tools/agent-loop/bin/agent-loop`. Update with `git pull` in the clone or `git submodule update --remote`.

## Set up a project

```bash
cd ~/projects/my-project
agent-loop doctor      # checks the tools above, and which GitHub account the loop acts as
agent-loop init        # writes .agent-loop.conf, .agent-loop/prompts/project.md, and the labels
                       # (add --workflows for the review workflow, --plan for the plan template)
```

`init` does the following, and `--dry-run` shows it without changing anything:

| Step | Result |
|---|---|
| Config | `.agent-loop.conf`, with setup and verify commands guessed from `package.json`, `go.mod`, `Cargo.toml` or a Makefile |
| Project rules | `.agent-loop/prompts/project.md`, a stub for what an agent cannot guess from the code |
| Review workflow (only with `--workflows`) | `.github/workflows/claude-code-review.yml`, an independent review that blocks only on real findings and checks the acceptance criteria: see "Review workflow". Skipped when the file exists (`--force` overwrites it) |
| Plan template (only with `--plan`) | `docs/plans/TEMPLATE.md`, the plan format triage works best with, checked by `agent-loop plan-lint`: see "Plans" |
| Stop hook (only with `--hook`) | `.claude/hooks/agent-loop-verify.sh`, merged into `.claude/settings.json`, for people's interactive sessions too. The loop does not need it: every agent run gets the same hook through `--settings`. |
| Labels | `agent-ok`, `agent-wip`, `agent-blocked`, `human`, `agent-automerge`, `risk:high` (skip with `--no-labels`) |

Then:

1. Edit `.agent-loop.conf`. Check `AGENT_SETUP_CMD` and `AGENT_VERIFY_CMD`, and **add `AGENT_EXTRA_DENY` rules for every deploy, production-database and cloud command your project can run.**
2. Write the project rules in `.agent-loop/prompts/project.md`.
3. Commit `.agent-loop.conf` and `.agent-loop/` so teammates share them (the loop reads them from the main checkout).
4. Try it without cost or changes: `agent-loop start --once --dry-run --no-triage`
5. Label one small, well-specified issue `agent-ok`, then run `agent-loop start --no-triage`.

## Commands

```bash
agent-loop start [--once] [--dry-run] [--no-triage]   # run the loop (Ctrl-C stops it; running agents finish)
agent-loop status                                      # the account the loop acts as, running agents, agent PRs with their risk, blocked and ready issues
agent-loop kill                                        # stop running agents and their claude processes (worktrees stay; the next run continues from them)
agent-loop unpause                                     # clear a usage-limit pause
agent-loop work <issue> [--fix]                        # run a single issue by hand
agent-loop triage [--dry-run]                          # sync issues with plan files
agent-loop stats [--days N] [--json|--digest]          # outcomes, turns and cost of the finished runs (default 7 days); --digest: a short text for the last 24 hours
agent-loop lessons [--days N]                          # why agents stopped and what reviewers asked for (default 30 days), newest first
agent-loop plan-lint [files...]                        # check plan files (default: AGENT_PLANS_GLOB) for items triage can use; exit 1 on errors
agent-loop labels                                      # (re)create the labels (including agent-automerge and risk:high)
agent-loop doctor                                      # check tools, claude CLI options, gh auth and account, base branch
agent-loop version
```

## How a round works (every `AGENT_POLL_SECONDS`, default 300)

| # | Step | What happens |
|---|---|---|
| 1 | Clean up | For PRs merged, closed unmerged, or whose issue closed: remove the worktree `../<repo>-agent-<n>`, the local and remote branch, and the state. If the issue is still open (the PR was closed unmerged, or merged without closing the issue), it loses `agent-ok` once, with a comment saying why, so the same work does not start again. Logs older than 14 days are deleted. |
| 1b | Resume | An open issue labeled `agent-blocked` whose last "Stopped working on this" comment from the loop was followed by a comment from a trusted author (`AGENT_TRUSTED_ASSOCIATIONS` / `AGENT_TRUSTED_USERS`) that does not start with `🤖 agent:` loses `agent-blocked`. It then follows the normal path: a new attempt, or a fix run when its PR is open. Comments from anyone else never resume an issue. `AGENT_AUTO_RESUME=0` turns this off. |
| 1c | Base check | Reads the check status of the head commit of `origin/<base>`. If a check has failed (ignoring `AGENT_IGNORE_CHECKS`), step 4 starts no agent until the head passes again (cleanup, resume and fix go on), and the top of `agent-loop status` says so. Once per failing commit the loop opens an issue titled for the failing checks, listing the commit, the check names and the PRs merged since the last commit it saw pass, and sends one notification. The issue gets no `agent-ok`: you decide whether to revert or fix it by hand. Pending checks and a base branch without checks block nothing. No model call. |
| 1d | Auto-merge | For an open agent PR the loop merges it when every condition in "Auto-merge" below holds: the PR of an issue you labeled `agent-automerge`, or, with `AGENT_AUTOMERGE_POLICY=risk`, a low-risk PR without the label (`AGENT_AUTOMERGE=0` turns all of it off). With `AGENT_AUTOMERGE_POLICY=shadow` it only comments what `risk` would do. |
| 2 | Fix | An open PR on branch `agent/issue-<n>` of this repository (a PR from a fork never counts) with a conflict, a failing check or new review feedback from a trusted author gets `work --fix`. Nothing runs if nothing changed since the last fix. After 3 rounds it becomes `agent-blocked`, and so does a PR whose fix run pushed nothing while the conflict or failing check remains (for example a flaky check: re-run it, then remove the label). |
| 3 | Triage | When nothing is ready to start and the base branch moved since the last triage, run triage (only if `AGENT_PLANS_GLOB` is set). |
| 4 | Start | Issues with `agent-ok`, without `human` / `agent-blocked`, with no sub-issues and all dependencies closed start in number order, up to `AGENT_MAX_PARALLEL`. Dependencies are GitHub's "blocked by" relations plus a `Depends on: #12, #13` line in the body. An issue with a `Touches:` line (below) is held back for the round while its files overlap a running issue's or an open agent PR's. |

While a usage limit is in effect (a rejected usage window, API 429, or overload 529), the interrupted run is not counted as a failure and steps 2-4 pause until the reset; cleanup continues. The loop also stops starting agents when any window reported in the `rate_limit_event` stream passes `AGENT_PAUSE_AT_UTILIZATION` (default 80%), so you keep some quota.

Agents run as `claude -p`, so they bill like any headless Claude Code use: against your API key, or on a subscription against what your plan gives headless use (Anthropic moved `claude -p` on Pro/Max to a separate monthly Agent SDK credit from 2026-06-15; check your plan). The `$` figures in the logs are API-equivalent estimates.

Every attempt after the first starts with what the previous run left behind: its summary, its `blocked_reason`, and how it ended (turn limit, timeout, checks still failing, usage limit), read from its result file in the logs. The line that starts a run in the log names the model it actually uses.

Passing checks prove the project's checks pass, not that the issue is done. So the implement prompt requires a `## Acceptance criteria` section in the PR body: one line per criterion of the issue, each with its evidence (the test that covers it, or the file and lines) or `not done` with the reason, and a PR with a `not done` line uses `Refs #<n>` instead of `Closes #<n>`. The fix prompt keeps the section up to date. After an implement run opens a PR, `work.sh` checks that the body has the section and, if not, comments once on the PR; it starts no extra run for it. There is no second review pass, so this costs no extra tokens (screenshots or browser evidence for UI work are out of scope).

Outcomes are judged by GitHub's real state (is a PR open?), not by what the agent claims. Implementation stops after 2 attempts and fixing after 3 rounds, each ending in `agent-blocked` plus a notification. Agents run in their own process group, so Ctrl-C on the loop leaves them running and `agent-loop kill` stops them completely.

### Auto-merge

Every agent PR waits for you to merge it, and the issues that depend on it wait too. For low-risk work (documentation, tests, small well-specified changes) you can hand the click to the loop in two ways: label an issue `agent-automerge` before the work exists (your decision, per issue), or let the loop judge the diff (`AGENT_AUTOMERGE_POLICY=risk`, below). Either way the PR merges in the round where all of these hold:

- (policy `label`) the issue has `agent-automerge`, or (policy `risk`) the PR is low-risk in the sense below; and in both cases the issue has neither `agent-blocked` nor `human`;
- the PR is mergeable and **every check has finished and passed** (`SUCCESS`, `NEUTRAL` or `SKIPPED`; a PR with no checks is never merged automatically; `AGENT_IGNORE_CHECKS` does not apply here);
- no feedback from a trusted author is waiting for a fix run, there is no conflict, and no agent run is in progress for the issue;
- if `AGENT_AUTOMERGE_REQUIRE_REVIEW` names a login (for example an external review bot), that login's latest review or comment is clean in the sense of `AGENT_CLEAN_REVIEW_USER` (a "No issues found" comment) and is newer than the PR's last commit (see "Review workflow");
- the PR body contains `Closes #<n>` (a PR that leaves part for a person, with `Refs #<n>`, is not merged);
- the checks on the head of the base branch are not failing (see round step 1c);
- no changed file is on a high-risk path, the issue is not labeled `risk:high`, and GitHub returned the changed files (below). **This applies to labeled PRs in every policy**: the label is decided before the diff exists, and a PR that ended up changing CI or a lockfile must not merge unseen. (Before this existed, the label alone was enough: to get that back for a path, remove it from `AGENT_RISK_PATHS`.)

The merge uses `AGENT_AUTOMERGE_METHOD` (`squash` by default; `merge` or `rebase`), pinned to the head commit that was checked, and is announced with a comment on the PR (which says the policy and the reasons) and a notification. If a PR is not merged although the policy would allow it, the log says why, once per reason. The loop makes the merge itself: `gh pr merge` stays denied to the agents, and the loop adds no review pass of its own and no model call, so this costs no tokens. A project that wants an independent review before merging supplies it outside the loop (a review bot, a required check) and names it in `AGENT_AUTOMERGE_REQUIRE_REVIEW`. Branch protection still applies: if GitHub refuses the merge, the loop logs it and tries again next round.

#### Judging the risk from the diff

The risk is in the diff, which the loop can read (`gh api repos/<repo>/pulls/<n>/files`, cached per head commit). A PR is **low-risk** when all of these hold:

| Condition | Setting |
|---|---|
| no changed file (nor the old path of a renamed one) matches `AGENT_RISK_PATHS` | globs, space-separated, in the syntax of `Touches:` (`*` also matches `/`, so `**` works). Default: `.github/** .agent-loop/** .agent-loop.conf CLAUDE.md */CLAUDE.md docs/plans/** docs/decisions/**` and, in the root and in subdirectories, `package.json pnpm-lock.yaml package-lock.json yarn.lock pyproject.toml uv.lock requirements*.txt go.mod go.sum Cargo.toml Cargo.lock`. Add your own (migrations, infrastructure, auth, API schemas, UI). Empty means no path is high-risk |
| at most `AGENT_AUTOMERGE_MAX_LINES` lines changed (additions plus deletions) | default `300` |
| its issue is not labeled `risk:high` | triage adds it from a plan's `Risk: high` (see "Plans"); a person can add it too, and only a person removes it |
| it deletes no test file (nor renames one to a path that is not a test), and removes no more lines from test files than it adds | test files: `AGENT_TEST_PATHS`, default `test/** tests/** *_test.* *.test.* *.spec.* */test_*.py` |
| every condition in the list above holds (checks, feedback, `Closes #<n>`, ...) | |

Files that cannot be read count as high-risk. The first and third condition stop a PR even when its issue has `agent-automerge`; the size and test conditions only decide whether a PR may merge *without* the label.

#### The three policies (`AGENT_AUTOMERGE_POLICY`)

| Policy | What merges | What else |
|---|---|---|
| `label` (default) | the PR of an issue you labeled `agent-automerge` (and that is not stopped by a high-risk path or `risk:high`) | PRs without the label are not looked at |
| `shadow` | the same as `label`: nothing merges that `label` would not merge | each agent PR gets **one comment per head commit**: "would merge automatically" or "needs a person: <reasons>". The comment is made once the PR has settled (checks finished, mergeability known, no run in progress), so the verdict is the final one for that commit |
| `risk` | as `label`, and a low-risk PR merges without the label | the log says once per reason why a PR is not merged |

`agent-loop status` lists each open agent PR as `risk=low (<n> changed lines)` or `risk=high: <reasons>`.

**Suggested rollout.** Run `shadow` for two weeks. Each agent PR then carries the loop's verdict next to what you did with it: look at the PRs you merged within minutes and see whether the loop said "would merge automatically", and at the ones it said "needs a person" for and whether you agree with the reason. Tighten `AGENT_RISK_PATHS` and `AGENT_AUTOMERGE_MAX_LINES` until the verdicts match what you would have done, then switch to `risk`. Keep `AGENT_AUTOMERGE_REQUIRE_REVIEW` set to the review bot of the next section if you have one.

### Review workflow

Passing checks prove the project's checks pass, not that the issue is done, and the `## Acceptance criteria` section the implementer writes is self-reported. `agent-loop init --workflows` writes `.github/workflows/claude-code-review.yml` (from `templates/github/claude-code-review.yml`; an existing file is left alone, `--force` replaces it, `--dry-run` shows it) that adds an independent reviewer, run by [claude-code-action](https://github.com/anthropics/claude-code-action). It needs the repository secret `CLAUDE_CODE_OAUTH_TOKEN` and the Claude GitHub App. Its contract:

- **One comment, updated in place** (`use_sticky_comment: true`), on every push, instead of a new comment per push. The loop reads a comment from the time it was last edited, so an updated comment counts as new.
- **It reports only findings that block the merge**: a bug, a security problem, a broken rule from `CLAUDE.md`, an acceptance criterion that is not met. When there are none, the comment starts with `No issues found.`, and nits go under an `## Optional` heading after it. With findings, the comment starts with `## Blocking findings` and never contains the words "No issues found".
- **It checks the acceptance criteria.** It reads the issue the PR closes and compares each criterion with the PR's `## Acceptance criteria` section and with the diff. A criterion missing from the section, marked `not done` while the PR says `Closes`, or whose evidence does not hold (the test is not there, or does not test it) is a blocking finding. The review runs in a fresh context, so it grades independently of the implementer.
- The bot settings are the same as in agent-loop's own workflow (`allowed_bots: 'claude'`, so PRs opened by the loop's own agents are reviewed).

How it fits the loop's settings:

| Setting | With this workflow |
|---|---|
| `AGENT_CLEAN_REVIEW_USER` (default `claude[bot]`) | The login that posts the comment. A `No issues found` comment from it is not feedback; a comment with blocking findings is, so a fix round starts, and after `AGENT_MAX_FIXES` rounds the issue is blocked. Nits under `## Optional` after a `No issues found.` start nothing. If your comments come from another login (the action posts as `github-actions[bot]` when you give it `github_token`), set this to that login |
| `AGENT_IGNORE_CHECKS` | Add the job name, `claude-review`: a failed review *job* (an outage, a missing secret) should not start fix runs. The review's findings are the comment, not the job's status |
| `AGENT_AUTOMERGE_REQUIRE_REVIEW` | Set it to the same login: the loop then merges only when that login's latest comment is clean and newer than the PR's last commit. A review of an older commit does not count |

### Plans

Triage turns plan items into issues and relies on each item being about one PR, with acceptance criteria, dependencies and `human` marks. `agent-loop init --plan` copies `templates/plan.md` to `docs/plans/TEMPLATE.md` (with `status: template`, so triage and `plan-lint` skip it); copy it to `docs/plans/<name>.md` for a real plan. Items have a fixed shape:

```markdown
### P1-03 Upload a CSV and preview rows
- Size: S · Risk: low · Owner: agent
- Depends on: P1-01
- Touches: app/upload/**, lib/csv/**
- Acceptance:
  - [ ] Given a 10 MB CSV, the preview shows the first 50 rows within 2 s
  - [ ] An invalid file shows the error from docs/spec/errors.md
```

`agent-loop plan-lint [files...]` (default: the files of `AGENT_PLANS_GLOB`) exits 1 and prints `file:line: message` when an item lacks `Size` (S, M or L), `Risk` (low or high), `Owner` (agent or human) or an `Acceptance` line with at least one criterion, when an id is used twice, or when `Depends on` names an id (`P1-01`; issue numbers such as `#12` are ignored) that no plan defines. Ids are defined by every plan of `AGENT_PLANS_GLOB` plus the files you name. Items are `### <ID> title` headings, where the id is letters, a dash and digits; other headings and fenced code blocks are not items. It is plain bash and awk: no model call, no GitHub, so it runs in CI:

```yaml
# .github/workflows/plan-lint.yml
name: plan-lint
on:
  pull_request:
    paths: ['docs/plans/**']
jobs:
  plan-lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: git clone --depth 1 https://github.com/mrjwei/agent-loop /tmp/agent-loop && /tmp/agent-loop/bin/agent-loop plan-lint docs/plans/*.md
```

Triage maps the fields to labels: `Size` to `size:s`, `size:m` or `size:l`; `Risk` to `risk:low` or `risk:high`; `Owner: human` to `human`. Let triage create them with `AGENT_AUTOCREATE_LABELS='size:* risk:*'` (`risk:high` is created by `init` and `agent-loop labels`). `risk:high` also keeps the issue's PR from merging automatically (see "Auto-merge"), and triage never removes it: a person does.

### Stats and the daily digest

Without numbers, the effect of a prompt, model or configuration change is a guess. `agent-loop stats [--days N]` (default 7) prints, for the finished runs in that period: runs by mode and outcome, PRs opened, issues blocked, fix runs per opened PR, and turns and API-equivalent cost in total and per opened PR. `--json` prints the same numbers as JSON for other tools. `--digest` prints a short text for the last 24 hours: PRs opened, issues blocked with their reasons, PRs waiting for review, and spend. With `AGENT_DIGEST_HOUR` (a local hour, empty = off) and `AGENT_NOTIFY_CMD` set, the first round at or after that hour sends the digest once a day through the command.

Each finished run appends one line to `.git/agent-loop/history.jsonl` (run, time, issue, mode, outcome, status, PR, turns, cost, model), which is kept when the logs are deleted after `AGENT_LOG_DAYS`; `stats` also reads result files in the logs that the history does not have (runs from before it existed). Outcomes are `pr_opened`, `fixed`, `blocked`, `failed` (the attempt or round will be tried again) and `limit` (stopped by a usage limit); triage runs appear as mode `triage` with outcome `ok`, `failed` or `limit`. "Fix runs per PR" is the number of fix runs divided by the PRs opened in the same period. Everything is computed by the scripts with `jq`; no model call.

### Lessons

The reason an agent stopped is written to an issue comment, and review feedback to a PR; both are easy to forget, and the same missing rule (an undocumented convention, a command that needs a person) blocks later issues again. So the loop also appends one line to `.git/agent-loop/lessons.jsonl` when an issue is blocked, and one per review comment when a fix run finishes. `agent-loop lessons [--days N]` prints them newest first with the issue numbers, and the path of `.agent-loop/prompts/project.md`, where you turn the recurring ones into rules. Nothing summarizes the file: you decide what becomes a rule, so it costs no tokens.

### Notifications

Three events need a person: an agent stopped (`agent-blocked`), a PR was opened, and agents are paused by a usage limit. The scripts send the notifications themselves; no model call is involved, and `AGENT_NOTIFY=0` turns them all off. A failing notification is logged and never fails the loop.

- **GitHub (default).** The loop's comment on a blocked issue and its comment on a newly opened PR mention `AGENT_NOTIFY_USER`, so GitHub delivers a mobile push and an email with a link to the thread. Set it to your login (`init` fills in the authenticated user). GitHub does not notify you about your own comments, so this channel works when the loop's `gh` account is not `AGENT_NOTIFY_USER` (for example a bot account: see "Run the loop as a machine account"; `agent-loop doctor` warns when they are the same); if the loop runs as you, add `AGENT_NOTIFY_CMD`.
- **`AGENT_NOTIFY_CMD` (optional).** Run for all three events with the title and body appended as arguments (`$1`, `$2`), the issue or PR URL in `$AGENT_NOTIFY_URL`, and the title and body also in `$AGENT_NOTIFY_TITLE` and `$AGENT_NOTIFY_BODY`. The usage-limit pause has no issue to comment on, so it uses this channel only (it is also shown at the top of `agent-loop status`). A working example with [ntfy](https://ntfy.sh), which pushes to the ntfy phone app:

  ```bash
  AGENT_NOTIFY_CMD='ntfy_send() { curl -fsS -H "Title: $1" -H "Click: $AGENT_NOTIFY_URL" -d "$2" https://ntfy.sh/CHOOSE-A-SECRET-TOPIC >/dev/null; }; ntfy_send'
  ```

  Pushover, a Slack webhook and the like work the same way: any command that reads `$1`, `$2` and `$AGENT_NOTIFY_URL`.

### Run the loop as a machine account

By default the loop acts as whatever account `gh` is logged in as, usually the project owner. Then the agents' PRs are opened by the owner, who cannot approve their own PRs; GitHub does not notify a user of mentions written by their own account, so the mention channel under "Notifications" stays silent; the audit trail mixes the owner's actions with the agents'; and the token the loop holds has the owner's admin rights. A separate account fixes all four:

1. Create the account (GitHub allows one machine account per person, and it may be a free account) and invite it to the repository with **write** access.
2. As that account, create a fine-grained personal access token limited to the project repositories, with repository permissions **Contents**, **Pull requests** and **Issues** set to read and write, **Checks**, **Commit statuses** and **Actions** set to read, and **no Administration**. (Without the read permissions the base-branch check and the auto-merge conditions cannot see checks: a failed read looks like "no checks".) If your repository is in an organization, the organization may need to allow fine-grained tokens and approve this one.
3. Set `GH_TOKEN` **only for the loop process**, not in your shell profile, and run the loop from a terminal or service that has it:

   ```bash
   GH_TOKEN=github_pat_xxx agent-loop start
   # or, in a systemd unit / launchd plist / process manager: Environment=GH_TOKEN=...
   ```

   `gh` uses `GH_TOKEN` before its stored login, so your own `gh auth login` session is untouched. `git push` to `origin` still uses your git credentials: give the machine account push access the same way (an SSH deploy key with write access, or a credential helper that reads `GH_TOKEN`: `gh auth setup-git`).
4. Your own login keeps admin: use it for `agent-loop init` and for branch protection (require a PR and, if you want, one approval: the machine account's PRs can now be approved by you). Set `AGENT_NOTIFY_USER` to **your** login.

Check it:

```bash
GH_TOKEN=github_pat_xxx agent-loop doctor    # "the loop acts as GitHub user <machine account>"
GH_TOKEN=github_pat_xxx agent-loop status    # first line: "== Acting as GitHub user <machine account>"
```

`agent-loop doctor` warns when the loop's `gh` user is `AGENT_NOTIFY_USER` (the mentions will not notify you) and when that user has admin permission on the repository (the loop holds more rights than it needs). `agent-loop status` always shows which account the loop acts as. See also "Safety model".

### Issues that change the same files

Issues start in number order as soon as their dependencies are closed, so two that change the same files run in parallel, and the second PR to merge gets a conflict that costs a fix run. To avoid it, an issue body may carry a line next to `Depends on:`:

```
Touches: src/billing/**, docs/api.md
```

The value is comma-separated globs (`*`, `?`, `[...]`; a `*` also matches `/`, so `**` works; a trailing `/` means everything below). In the start step an issue is held back for this round while its globs overlap (a) the `Touches` globs of a running issue, or of an issue started earlier in the same round, or (b) the changed files of an open agent PR (`gh pr view --json files`). It starts in a later round, once that issue or PR is gone. Issues without the line behave as before, and the check is conservative (when two patterns might overlap, they are treated as overlapping). The triage prompt asks for a `Touches:` line when a plan makes the files clear. `agent-loop status` shows the ready issues that are held back and why. The check is done by the scripts; no model call.

### Labels

| Label | Meaning | Set by |
|---|---|---|
| `agent-ok` | An agent may take this issue | triage, or you |
| `agent-wip` | An agent is working on it, or its PR awaits review | the loop |
| `agent-blocked` | The agent stopped; the reason is in an issue comment | the loop. **Your answer in a comment is enough**: the next round removes it and work resumes (removing it by hand works too, and is needed with `AGENT_AUTO_RESUME=0`) |
| `human` | Work only a person can do; `agent-ok` is never added | you, or triage |
| `agent-automerge` | The loop merges this issue's PR itself once every condition in "Auto-merge" holds | **you only**. Triage never adds or removes it, and the agents cannot change labels |
| `risk:high` | The PR of this issue is never merged automatically, whatever the policy and the label | triage (from a plan's `Risk: high`) or you; **only you remove it** |
| `size:s`, `size:m`, `size:l`, `risk:low` | A plan item's Size and Risk, recorded on its issue (nothing in the loop reads them yet) | triage, when `AGENT_AUTOCREATE_LABELS` allows `size:* risk:*` |

### What you do

- Review and merge PRs. A PR that covers the whole issue closes it on merge; one that leaves part for you says so in its body and keeps the issue open, without `agent-ok`. Comment on a PR to ask for changes; the next round reads the comment, then fixes or replies with a comment starting `🤖 agent:`.
- Answer `agent-blocked` issues in a comment. The loop sees an answer from a trusted author in its next round and removes the label itself, so a reply from the GitHub mobile app is enough (comments from anyone else never resume an issue; with `AGENT_AUTO_RESUME=0`, remove the label yourself). The previous conversation opens with `cd ../<repo>-agent-<n> && claude -r <session-id>` (the id is in the issue comment and the log).

## Configuration

`.agent-loop.conf` at the project root is plain bash. **Precedence: environment variable > `.agent-loop.conf` > default.** Arrays can only be set in the file. Use `AGENT_CONF=/path` to read a different file.

| Variable | Default | Meaning |
|---|---|---|
| `AGENT_SETUP_CMD` | empty | Runs in each worktree before the agent (dependency install), in the same scrubbed environment as the agent |
| `AGENT_VERIFY_CMD` | empty | Checks that must pass before a PR; told to the agent and run by a Stop hook before it may finish |
| `AGENT_VERIFY_TIMEOUT` | `600` | Seconds the Stop hook may spend on `AGENT_VERIFY_CMD` |
| `AGENT_LANGUAGE` | `English` | Language of commits, PRs, summaries and agent comments |
| `AGENT_BASE_BRANCH` | origin's default branch, else `main` | Branch PRs are based on |
| `AGENT_WT_PREFIX` | `<repo-dir>-agent` | Worktrees are `../<prefix>-<issue>` |
| `AGENT_PROMPTS_DIR` | `.agent-loop/prompts` | Project prompt overrides (relative to the repo root) |
| `AGENT_PLANS_GLOB` | empty (triage off) | Plan files for triage, e.g. `docs/plans/*.md` |
| `AGENT_PLANS_ACTIVE_REGEX` | `^status: active` | A plan counts as active when a line matches (empty = all) |
| `AGENT_AUTOCREATE_LABELS` | empty | Globs of labels triage may create, e.g. `phase:*`. For plans in the template form: `'size:* risk:*'` |
| `AGENT_MODEL` / `AGENT_EFFORT` | `claude-sonnet-5-5` / `high` | Implement and fix agents |
| `AGENT_ESCALATE_MODEL` / `AGENT_ESCALATE_EFFORT` | empty (off) | Model and effort for the last implement attempt (`AGENT_MAX_ATTEMPTS`) and the last fix round (`AGENT_MAX_FIXES`), instead of `AGENT_MODEL` / `AGENT_EFFORT`. Each one falls back to the normal value when empty. No extra run: the same number of attempts happens, the last with the stronger model |
| `AGENT_TRIAGE_MODEL` / `AGENT_TRIAGE_EFFORT` | `claude-opus-5-5` / `high` | Triage agent |
| `AGENT_PERMISSION_MODE` | `auto` | `acceptEdits` is stricter: anything not on the allow list is refused |
| `AGENT_MAX_PARALLEL` | `2` | Agents at once |
| `AGENT_POLL_SECONDS` | `300` | Time between rounds |
| `AGENT_AUTO_RESUME` | `1` | A comment from a trusted author after the loop's block comment removes `agent-blocked` in the next round. `0` = a person removes the label |
| `AGENT_MAX_ATTEMPTS` / `AGENT_MAX_FIXES` | `2` / `3` | Attempts and fix rounds before `agent-blocked` |
| `AGENT_MAX_TURNS` / `AGENT_TRIAGE_MAX_TURNS` | `150` / `80` | Turn limit per agent / triage run |
| `AGENT_RUN_TIMEOUT` | `3600` | Seconds one implement or fix run may take. Then its process group is stopped, the run counts as a failed attempt or fix round, and the worktree stays so the next attempt continues from it. `0` = no limit |
| `AGENT_MAX_COST_PER_RUN` | empty (off) | API-equivalent dollars one run may cost, passed to the `claude` CLI's own `--max-budget-usd`. `agent-loop doctor` says whether the installed CLI has it; if not, the variable is skipped with a warning |
| `AGENT_DAILY_BUDGET` | empty (off) | API-equivalent dollars per local day. The loop sums `total_cost_usd` of today's result files in the logs; when it reaches the budget, rounds skip the fix, triage and start steps until the next day (cleanup continues) and one notification is sent. `agent-loop status` shows today's spend and the budget |
| `AGENT_TRIAGE_MAX_ACTIONS` | `15` | Changes applied per triage |
| `AGENT_PAUSE_AT_UTILIZATION` | `0.8` | Stop starting agents when a usage window passes this share |
| `AGENT_LIMIT_PAUSE_SECONDS` | `1800` | Wait when a limit hits and no reset time is known |
| `AGENT_IGNORE_CHECKS` | empty | CI check names (comma-separated) that never trigger a fix, and never count as failing on the base branch |
| `AGENT_IGNORE_FEEDBACK_USERS` | `github-actions[bot]` | Users whose comments are never feedback |
| `AGENT_CLEAN_REVIEW_USER` | `claude[bot]` | A "No issues found" comment from this user is not feedback (the login of the review workflow's comment) |
| `AGENT_TRUSTED_ASSOCIATIONS` | `OWNER MEMBER COLLABORATOR` | GitHub author associations whose comments count as feedback and whose issues triage may give `agent-ok` (`*` = everyone) |
| `AGENT_TRUSTED_USERS` | the value of `AGENT_CLEAN_REVIEW_USER` | Logins trusted whatever their association (review bots) |
| `AGENT_AUTOMERGE` | `1` | `0` turns off auto-merge everywhere: the label is ignored and no policy merges |
| `AGENT_AUTOMERGE_POLICY` | `label` | `label` (the PR of an `agent-automerge` issue), `shadow` (as `label`, plus one comment per head commit saying what `risk` would do) or `risk` (also a low-risk PR without the label). See "Auto-merge" |
| `AGENT_AUTOMERGE_MAX_LINES` | `300` | A low-risk PR changes at most this many lines (additions plus deletions) |
| `AGENT_RISK_PATHS` | `.github/**`, `.agent-loop/**`, `.agent-loop.conf`, `CLAUDE.md`, `*/CLAUDE.md`, `docs/plans/**`, `docs/decisions/**`, and the usual manifests and lockfiles (`package.json`, `pnpm-lock.yaml`, `package-lock.json`, `yarn.lock`, `pyproject.toml`, `uv.lock`, `requirements*.txt`, `go.mod`, `go.sum`, `Cargo.toml`, `Cargo.lock`, each also in subdirectories) | Globs (space-separated, the syntax of `Touches:`) of paths that make a PR high-risk: it is never merged automatically, labeled or not. Setting it replaces the list, so copy the default when you add to it; empty = none |
| `AGENT_TEST_PATHS` | `test/** tests/** *_test.* *.test.* *.spec.* */test_*.py` | Globs that identify test files: a low-risk PR deletes none and removes no more lines from them than it adds |
| `AGENT_AUTOMERGE_METHOD` | `squash` | `squash`, `merge` or `rebase` |
| `AGENT_AUTOMERGE_REQUIRE_REVIEW` | empty | A login (e.g. a review bot) whose latest review or comment on the PR must be clean before the loop merges |
| `AGENT_NOTIFY` | `1` | `0` turns off every notification: the `@mention` comments and `AGENT_NOTIFY_CMD` |
| `AGENT_NOTIFY_USER` | empty (`init` fills in your GitHub login) | GitHub login mentioned in the loop's comments on blocked issues and opened PRs |
| `AGENT_NOTIFY_CMD` | empty | Command run with the title and body as arguments and the issue or PR URL in `$AGENT_NOTIFY_URL` |
| `AGENT_LOG_DAYS` | `14` | Log retention (`history.jsonl` and `lessons.jsonl` are kept) |
| `AGENT_DIGEST_HOUR` | empty (off) | Local hour (0-23) at which the loop sends `agent-loop stats --digest` once a day through `AGENT_NOTIFY_CMD` |
| `AGENT_EXTRA_ALLOW`, `AGENT_EXTRA_DENY`, `AGENT_EXTRA_TRIAGE_DENY` | empty arrays | Extra permission rules (Claude Code `--allowedTools` / `--disallowedTools` syntax) |
| `AGENT_SCRUB_ENV` | common cloud and token variables | Variables removed from the environment of the agents and of `AGENT_SETUP_CMD`. If the install needs one (e.g. `NPM_TOKEN` for a private registry), set this list without it |
| `AGENT_CHILD_ENV` | `(AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null)` | `NAME=VALUE` pairs set for the agents |

The branch name `agent/issue-<n>` and the label names are fixed.

## Customizing the prompts

The agents get three prompts: `implement`, `fix` and `triage` (in `prompts/`). Two ways to adapt them to a project, both in `.agent-loop/prompts/`:

- **`project.md`** is inserted into all three prompts under "Project rules". Use it for commit style, documents to update, what needs a human, issue conventions. HTML comments in it are stripped.
- **`implement.md`, `fix.md`, `triage.md`** replace the packaged prompt entirely. Placeholders: `{{N}} {{BRANCH}} {{WT}} {{PR}} {{BASE}} {{LANGUAGE}} {{TRUSTED}} {{VERIFY}} {{MARKER}} {{RESUME}} {{REASONS}} {{PLANS}} {{MAX}} {{PROJECT}}` (not every placeholder is set in every prompt).

`examples/acme_work_management/` shows a real configuration: a conf with project-specific allow/deny rules, a `project.md`, and a full `triage.md` override.

## Safety model

These are best-effort defenses, **not a sandbox**: the agents run with your own permissions.

- **Whose words count**: text on GitHub becomes instructions to an agent, so the people who can write it are the trust boundary. Only comments from trusted authors (`AGENT_TRUSTED_ASSOCIATIONS`, by default the owner, organization members and collaborators, plus `AGENT_TRUSTED_USERS`) start a fix run or reach the fix prompt. Triage never adds `agent-ok` to an issue someone else opened; label it yourself after reading it. The agents still read whole issue and PR threads with `gh`, and the prompts tell them to treat other people's comments as information only, which is a weaker defense: on a public repository, read a thread before you label its issue `agent-ok`.
- **Who can cause a merge**: only the loop merges. With the default policy, only the PR of an issue that carries `agent-automerge`; that label is set by whoever can label issues in the repository (people with triage or write access), triage never adds it and the agents cannot change labels. With `AGENT_AUTOMERGE_POLICY=risk`, also a PR the loop judges low-risk from its diff (a PR that touches `AGENT_RISK_PATHS`, is large, removes tests or whose issue is `risk:high` is never judged low-risk, and no label overrides a high-risk path). Comments, even from trusted authors, never merge anything. The conditions under "Auto-merge" must all hold, and branch protection still applies. If you do not want the loop to merge at all, set `AGENT_AUTOMERGE=0`.
- **Whose account**: run the loop as a machine account with a fine-grained token that can write but not administer ("Run the loop as a machine account"), so that a mistake or a hijacked run cannot change settings, branch protection or secrets with your admin rights. `agent-loop doctor` warns when the loop's user has admin permission.
- **Denied commands** (built in): `gh pr merge`, closing PRs or issues, label changes, `gh api`, `gh auth`, `gh repo/secret/variable/workflow/release`, force-push (including `+refspec`), pushing to the base branch, `git rebase`, `git reset --hard`, `git worktree`. Patterns also match in the middle of a command line. Your project's deploy and production commands are **yours to add** in `AGENT_EXTRA_DENY`.
- **Credentials**: the variables in `AGENT_SCRUB_ENV` are removed for the agents and for `AGENT_SETUP_CMD` (an install runs scripts from the worktree); `~/.aws`, `~/.ssh`, `~/.config/gh` and the macOS keychain are denied to the Read tool and to shell commands that name them. Of the main checkout's `.env` files, the Read tool is denied `.env`, `.env.local`, `.env.production` and `.env.*.local`; shell commands are denied when they name `.env.local` or `.env.production`, or any `.env*` file by the main checkout's absolute path. A shell command that reaches a plain `.env` through a relative path matches no rule and is left to the permission classifier, so keep production keys out of the main checkout where you can.
- **MCP**: `--strict-mcp-config` means no MCP servers or claude.ai connectors are loaded.
- **Isolation**: for anything beyond your own trusted repositories, run the loop as a separate OS user, in a VM or in a dev container, with a GitHub token limited to that repository.
- **Main branch**: use branch protection so a PR is required. The deny rules for pushes to the base branch are a second layer, not a replacement: they match the usual forms of the command only.
- **Triage agent** is read-only (`dontAsk` mode, no Edit/Write/commit/push). It returns proposed issue changes as JSON, and `triage.sh` enforces the rules before applying: it never touches `agent-wip`, `agent-blocked` or `human`; never adds `agent-ok` to a `human` issue; never rewrites an issue that is in progress or blocked; never closes issues; applies at most 15 changes per run. Old issue bodies are saved before rewriting.
- The loop runs from a private copy of the package under `.git/agent-loop/pkg-<pid>/`, so updating the package while a loop runs cannot change that loop.

## State and logs

Everything is under `.git/agent-loop/` (outside version control, shared by all worktrees).

| Path | Content |
|---|---|
| `logs/issue-<n>-<time>-<implement\|fix>.jsonl` | Full conversation (`stream-json`, including usage events) |
| `logs/issue-<n>-<time>-<…>.json` | Final result: `session_id`, turns, approximate API-equivalent cost, `structured_output` |
| `logs/issue-<n>-<time>-<…>.end` | One line on how the run ended, read by the next attempt's prompt |
| `logs/issue-<n>-<time>-<…>.log` | `work.sh` output |
| `logs/triage-<time>.json(l)`, `.applied.log`, `.issue-<n>.old-body.md` | Triage proposal, changes applied, previous issue bodies |
| `digest-sent` | The day the digest was last sent |
| `pr-files/<pr>-<sha>.json` | The changed files of a PR at a head commit, read once for the risk judgment (deleted with the logs) |
| `stamp/shadow-<n>` | The head commit of the PR of issue `<n>` that got its shadow comment |
| `base-failed-sha`, `base-last-green-sha` | The base commit an issue was opened for, and the last base commit seen passing |
| `history.jsonl` | One line per finished run (outcome, turns, cost, ...). Kept; read by `agent-loop stats` |
| `lessons.jsonl` | One line per agent stop (time, issue, mode, reason) and per review comment a fix run was started for (author, first line). Kept; read by `agent-loop lessons`. No model reads or summarizes it |
| `paused-until` | End of a usage-limit pause (epoch seconds) |
| `running/<n>.pid`, `count/`, `stamp/` | Running agents, retry counters, feedback timestamps |

## Troubleshooting

| Symptom | What to do |
|---|---|
| Nothing starts | Read the top of `agent-loop status`. If it is paused by a usage limit, wait or run `agent-loop unpause`. Check the issue has `agent-ok`, no sub-issues (a parent is never worked on), and closed dependencies. `agent-loop doctor` warns when `origin/HEAD` is unset and the base branch fell back to `main`. |
| A PR comment is ignored | Its author is not trusted: see `AGENT_TRUSTED_ASSOCIATIONS` and `AGENT_TRUSTED_USERS`. A review bot must be listed in `AGENT_TRUSTED_USERS`. |
| `the loop is already running` | Another terminal runs it. If it is not running, `rm -rf .git/agent-loop/loop.lock`. |
| The same issue blocks repeatedly | Read the reason in the issue comment, then fix the issue text or remove `agent-ok`. You can also work in its worktree and push; the next fix run merges your commits. |
| A worktree is left over | Cleanup skips worktrees with uncommitted changes. Inspect it, then `git worktree remove --force <path>` if unwanted. |
| Triage is skipped | Set `AGENT_PLANS_GLOB` and make sure a plan matches `AGENT_PLANS_ACTIVE_REGEX`. |

## Moving a project from an embedded `scripts/agent/` copy

1. Copy the example config and prompts: `cp -R examples/acme_work_management/.agent-loop* <project>/` (adjust to your project).
2. The loop passes its own verify Stop hook to every agent. Remove the project's own verify hook, or make it exit early when `AGENT_LOOP_RUN=1`, or the checks run twice per stop. For interactive sessions you can install the packaged one with `agent-loop init --hook --no-labels`.
3. Delete `scripts/agent/` and any docs that describe it; point them at this repository.
4. Run `agent-loop start --once --dry-run` and compare with the old behavior. The package uses the same state directory (`.git/agent-loop/`) and lock, so the old and new loops can never run at the same time.

## Layout

```
bin/agent-loop        entry point (dispatches to libexec/)
libexec/              loop.sh  work.sh  triage.sh  init.sh  plan-lint.sh  stats.sh  lessons.sh  verify-hook.sh (the Stop hook)
lib/common.sh         configuration, GitHub helpers, usage-limit handling
prompts/              default implement / fix / triage prompts
templates/            files `init` writes into a project (config, project rules, github/claude-code-review.yml, plan.md)
examples/             a real project's configuration
test/run.sh           offline tests (fake gh and claude, no network): `make test`
Makefile              install / uninstall / test / lint (`make lint` runs shellcheck at warning level, as CI does)
```
