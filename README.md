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
- macOS or Linux. Notifications (`osascript`) and keep-awake (`caffeinate`) are macOS-only and skipped elsewhere.

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
agent-loop doctor      # checks the tools above
agent-loop init        # writes .agent-loop.conf, .agent-loop/prompts/project.md, and the labels
```

`init` does the following, and `--dry-run` shows it without changing anything:

| Step | Result |
|---|---|
| Config | `.agent-loop.conf`, with setup and verify commands guessed from `package.json`, `go.mod`, `Cargo.toml` or a Makefile |
| Project rules | `.agent-loop/prompts/project.md`, a stub for what an agent cannot guess from the code |
| Stop hook (only with `--hook`) | `.claude/hooks/agent-loop-verify.sh`, merged into `.claude/settings.json`, for people's interactive sessions too. The loop does not need it: every agent run gets the same hook through `--settings`. |
| Labels | `agent-ok`, `agent-wip`, `agent-blocked`, `human` (skip with `--no-labels`) |

Then:

1. Edit `.agent-loop.conf`. Check `AGENT_SETUP_CMD` and `AGENT_VERIFY_CMD`, and **add `AGENT_EXTRA_DENY` rules for every deploy, production-database and cloud command your project can run.**
2. Write the project rules in `.agent-loop/prompts/project.md`.
3. Commit `.agent-loop.conf` and `.agent-loop/` so teammates share them (the loop reads them from the main checkout).
4. Try it without cost or changes: `agent-loop start --once --dry-run --no-triage`
5. Label one small, well-specified issue `agent-ok`, then run `agent-loop start --no-triage`.

## Commands

```bash
agent-loop start [--once] [--dry-run] [--no-triage]   # run the loop (Ctrl-C stops it; running agents finish)
agent-loop status                                      # running agents, agent PRs, blocked issues, ready issues
agent-loop kill                                        # stop running agents and their claude processes (worktrees stay; the next run continues from them)
agent-loop unpause                                     # clear a usage-limit pause
agent-loop work <issue> [--fix]                        # run a single issue by hand
agent-loop triage [--dry-run]                          # sync issues with plan files
agent-loop labels                                      # (re)create the labels
agent-loop doctor                                      # check tools, claude CLI options, gh auth, base branch
agent-loop version
```

## How a round works (every `AGENT_POLL_SECONDS`, default 300)

| # | Step | What happens |
|---|---|---|
| 1 | Clean up | For PRs merged, closed unmerged, or whose issue closed: remove the worktree `../<repo>-agent-<n>`, the local and remote branch, and the state. If the issue is still open (the PR was closed unmerged, or merged without closing the issue), it loses `agent-ok` once, with a comment saying why, so the same work does not start again. Logs older than 14 days are deleted. |
| 2 | Fix | An open PR on branch `agent/issue-<n>` of this repository (a PR from a fork never counts) with a conflict, a failing check or new review feedback from a trusted author gets `work --fix`. Nothing runs if nothing changed since the last fix. After 3 rounds it becomes `agent-blocked`. |
| 3 | Triage | When nothing is ready to start and the base branch moved since the last triage, run triage (only if `AGENT_PLANS_GLOB` is set). |
| 4 | Start | Issues with `agent-ok`, without `human` / `agent-blocked`, with no sub-issues and all dependencies closed start in number order, up to `AGENT_MAX_PARALLEL`. Dependencies are GitHub's "blocked by" relations plus a `Depends on: #12, #13` line in the body. |

While a usage limit is in effect (a rejected usage window, API 429, or overload 529), the interrupted run is not counted as a failure and steps 2-4 pause until the reset; cleanup continues. The loop also stops starting agents when any window reported in the `rate_limit_event` stream passes `AGENT_PAUSE_AT_UTILIZATION` (default 80%), so you keep some quota.

Agents run as `claude -p`, so they bill like any headless Claude Code use: against your API key, or on a subscription against what your plan gives headless use (Anthropic moved `claude -p` on Pro/Max to a separate monthly Agent SDK credit from 2026-06-15; check your plan). The `$` figures in the logs are API-equivalent estimates.

Outcomes are judged by GitHub's real state (is a PR open?), not by what the agent claims. Implementation stops after 2 attempts and fixing after 3 rounds, each ending in `agent-blocked` plus a notification. Agents run in their own process group, so Ctrl-C on the loop leaves them running and `agent-loop kill` stops them completely.

### Labels

| Label | Meaning | Set by |
|---|---|---|
| `agent-ok` | An agent may take this issue | triage, or you |
| `agent-wip` | An agent is working on it, or its PR awaits review | the loop |
| `agent-blocked` | The agent stopped; the reason is in an issue comment | the loop. **You remove it after answering**, and work resumes |
| `human` | Work only a person can do; `agent-ok` is never added | you, or triage |

### What you do

- Review and merge PRs. A PR that covers the whole issue closes it on merge; one that leaves part for you says so in its body and keeps the issue open, without `agent-ok`. Comment on a PR to ask for changes; the next round reads the comment, then fixes or replies with a comment starting `🤖 agent:`.
- Answer `agent-blocked` issues in a comment, then remove the label. The previous conversation opens with `cd ../<repo>-agent-<n> && claude -r <session-id>` (the id is in the issue comment and the log).

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
| `AGENT_AUTOCREATE_LABELS` | empty | Globs of labels triage may create, e.g. `phase:*` |
| `AGENT_MODEL` / `AGENT_EFFORT` | `claude-sonnet-5-5` / `high` | Implement and fix agents |
| `AGENT_TRIAGE_MODEL` / `AGENT_TRIAGE_EFFORT` | `claude-opus-5-5` / `high` | Triage agent |
| `AGENT_PERMISSION_MODE` | `auto` | `acceptEdits` is stricter: anything not on the allow list is refused |
| `AGENT_MAX_PARALLEL` | `2` | Agents at once |
| `AGENT_POLL_SECONDS` | `300` | Time between rounds |
| `AGENT_MAX_ATTEMPTS` / `AGENT_MAX_FIXES` | `2` / `3` | Attempts and fix rounds before `agent-blocked` |
| `AGENT_MAX_TURNS` / `AGENT_TRIAGE_MAX_TURNS` | `150` / `80` | Turn limit per agent / triage run |
| `AGENT_TRIAGE_MAX_ACTIONS` | `15` | Changes applied per triage |
| `AGENT_PAUSE_AT_UTILIZATION` | `0.8` | Stop starting agents when a usage window passes this share |
| `AGENT_LIMIT_PAUSE_SECONDS` | `1800` | Wait when a limit hits and no reset time is known |
| `AGENT_IGNORE_CHECKS` | empty | CI check names (comma-separated) that never trigger a fix |
| `AGENT_IGNORE_FEEDBACK_USERS` | `github-actions[bot]` | Users whose comments are never feedback |
| `AGENT_CLEAN_REVIEW_USER` | `claude[bot]` | A "No issues found" comment from this user is not feedback |
| `AGENT_TRUSTED_ASSOCIATIONS` | `OWNER MEMBER COLLABORATOR` | GitHub author associations whose comments count as feedback and whose issues triage may give `agent-ok` (`*` = everyone) |
| `AGENT_TRUSTED_USERS` | the value of `AGENT_CLEAN_REVIEW_USER` | Logins trusted whatever their association (review bots) |
| `AGENT_NOTIFY` | `1` | macOS notifications |
| `AGENT_LOG_DAYS` | `14` | Log retention |
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
- **Denied commands** (built in): `gh pr merge`, closing PRs or issues, label changes, `gh api`, `gh auth`, `gh repo/secret/variable/workflow/release`, force-push (including `+refspec`), `git rebase`, `git reset --hard`, `git worktree`. Patterns also match in the middle of a command line. Your project's deploy and production commands are **yours to add** in `AGENT_EXTRA_DENY`.
- **Credentials**: the variables in `AGENT_SCRUB_ENV` are removed for the agents and for `AGENT_SETUP_CMD` (an install runs scripts from the worktree); `~/.aws`, `~/.ssh`, `~/.config/gh` and the macOS keychain are denied to the Read tool and to shell commands that name them. Of the main checkout's `.env` files, the Read tool is denied `.env`, `.env.local`, `.env.production` and `.env.*.local`; shell commands are denied when they name `.env.local` or `.env.production`, or any `.env*` file by the main checkout's absolute path. A shell command that reaches a plain `.env` through a relative path matches no rule and is left to the permission classifier, so keep production keys out of the main checkout where you can.
- **MCP**: `--strict-mcp-config` means no MCP servers or claude.ai connectors are loaded.
- **Isolation**: for anything beyond your own trusted repositories, run the loop as a separate OS user, in a VM or in a dev container, with a GitHub token limited to that repository.
- **Main branch**: use branch protection so a PR is required.
- **Triage agent** is read-only (`dontAsk` mode, no Edit/Write/commit/push). It returns proposed issue changes as JSON, and `triage.sh` enforces the rules before applying: it never touches `agent-wip`, `agent-blocked` or `human`; never adds `agent-ok` to a `human` issue; never rewrites an issue that is in progress or blocked; never closes issues; applies at most 15 changes per run. Old issue bodies are saved before rewriting.
- The loop runs from a private copy of the package under `.git/agent-loop/pkg-<pid>/`, so updating the package while a loop runs cannot change that loop.

## State and logs

Everything is under `.git/agent-loop/` (outside version control, shared by all worktrees).

| Path | Content |
|---|---|
| `logs/issue-<n>-<time>-<implement\|fix>.jsonl` | Full conversation (`stream-json`, including usage events) |
| `logs/issue-<n>-<time>-<…>.json` | Final result: `session_id`, turns, approximate API-equivalent cost, `structured_output` |
| `logs/issue-<n>-<time>-<…>.log` | `work.sh` output |
| `logs/triage-<time>.json(l)`, `.applied.log`, `.issue-<n>.old-body.md` | Triage proposal, changes applied, previous issue bodies |
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
libexec/              loop.sh  work.sh  triage.sh  init.sh  verify-hook.sh (the Stop hook)
lib/common.sh         configuration, GitHub helpers, usage-limit handling
prompts/              default implement / fix / triage prompts
templates/            files `init` writes into a project
examples/             a real project's configuration
test/run.sh           offline tests (fake gh, no network): `make test`
```
