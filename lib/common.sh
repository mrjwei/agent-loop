# shellcheck shell=bash
# shellcheck disable=SC2034  # the variables set here are used by the scripts that source this file
# Shared configuration and functions for agent-loop. Sourced by every script in libexec/.
# Written for macOS's stock bash 3.2 (no associative arrays, mapfile or `wait -n`).

# --- Locate the package and the target repository ---
LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PKG_DIR=$(dirname "$LIB_DIR")
LIBEXEC="$PKG_DIR/libexec"

# The target project's main checkout (not a worktree). loop.sh runs from a private copy of the
# package and hands the path down in AGENT_REPO.
if [ -n "${AGENT_REPO:-}" ]; then
  REPO=$AGENT_REPO
else
  _common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
    echo "agent-loop: not inside a git repository (cd into your project, or set AGENT_REPO)" >&2
    exit 1
  }
  REPO=$(cd "$_common/.." && pwd)
  unset _common
fi
STATE="$REPO/.git/agent-loop"   # state and logs (inside .git, shared by all worktrees)

# --- Configuration: defaults < .agent-loop.conf < environment ---
# Exported AGENT_* variables win over the config file. Arrays can only be set in the config file.
# (declare -p quotes values safely, including ones with newlines)
_env_saved=$(for _v in $(compgen -e); do case "$_v" in (AGENT_*) declare -p "$_v" ;; esac; done)
AGENT_CONF=${AGENT_CONF:-$REPO/.agent-loop.conf}
# shellcheck disable=SC1090
if [ -f "$AGENT_CONF" ]; then . "$AGENT_CONF"; fi
eval "$_env_saved"
unset _env_saved _v
AGENT_LOOP_VERSION=$(cat "$PKG_DIR/VERSION" 2>/dev/null || echo dev)

AGENT_MODEL=${AGENT_MODEL:-claude-sonnet-5-5}             # implement / fix agent
AGENT_EFFORT=${AGENT_EFFORT:-high}
AGENT_TRIAGE_MODEL=${AGENT_TRIAGE_MODEL:-claude-opus-5-5} # planning (triage) agent
AGENT_TRIAGE_EFFORT=${AGENT_TRIAGE_EFFORT:-high}
AGENT_PERMISSION_MODE=${AGENT_PERMISSION_MODE:-auto}      # auto: a classifier decides commands not on the allow list; denies always apply
AGENT_MAX_PARALLEL=${AGENT_MAX_PARALLEL:-2}               # agents running at once
AGENT_POLL_SECONDS=${AGENT_POLL_SECONDS:-300}             # how often to look at GitHub
AGENT_MAX_ATTEMPTS=${AGENT_MAX_ATTEMPTS:-2}               # implementation attempts before agent-blocked
AGENT_MAX_FIXES=${AGENT_MAX_FIXES:-3}                     # fix rounds per PR before agent-blocked
AGENT_MAX_TURNS=${AGENT_MAX_TURNS:-150}
AGENT_RUN_TIMEOUT=${AGENT_RUN_TIMEOUT:-3600}              # seconds one implement / fix run may take (0 = no limit)
AGENT_MAX_COST_PER_RUN=${AGENT_MAX_COST_PER_RUN:-}        # API-equivalent dollars per run, via the claude CLI's own cap (empty = off)
AGENT_DAILY_BUDGET=${AGENT_DAILY_BUDGET:-}                # API-equivalent dollars per local day; over it, no agent starts (empty = off; for API-key use)
AGENT_DAILY_TOKEN_BUDGET=${AGENT_DAILY_TOKEN_BUDGET:-}    # tokens (input + output + cache writes) per local day; over it, no agent starts (empty = off; for Pro / Max use)
AGENT_TRIAGE_MAX_TURNS=${AGENT_TRIAGE_MAX_TURNS:-80}
AGENT_TRIAGE_MAX_ACTIONS=${AGENT_TRIAGE_MAX_ACTIONS:-15}  # triage changes applied per run
AGENT_VERIFY_TIMEOUT=${AGENT_VERIFY_TIMEOUT:-600}         # seconds the Stop hook may spend on AGENT_VERIFY_CMD
AGENT_IGNORE_CHECKS=${AGENT_IGNORE_CHECKS:-}              # comma-separated check names that never trigger a fix run
AGENT_NOTIFY=${AGENT_NOTIFY:-1}                           # 0 turns off every notification (the @mention comments and AGENT_NOTIFY_CMD)
AGENT_NOTIFY_USER=${AGENT_NOTIFY_USER:-}                  # GitHub login mentioned in the loop's comments on blocked issues and opened PRs
AGENT_NOTIFY_CMD=${AGENT_NOTIFY_CMD:-}                    # command run with the title and body as arguments (ntfy, Pushover, a Slack webhook, ...)
AGENT_LOG_DAYS=${AGENT_LOG_DAYS:-14}                      # logs older than this are deleted
AGENT_LIMIT_PAUSE_SECONDS=${AGENT_LIMIT_PAUSE_SECONDS:-1800} # wait this long when a usage limit hits without a reset time
AGENT_PAUSE_AT_UTILIZATION=${AGENT_PAUSE_AT_UTILIZATION:-0.8} # stop starting agents when a usage window passes this share (keeps some for you)

AGENT_BASE_BRANCH=${AGENT_BASE_BRANCH:-}                  # default: origin's default branch, else main
AGENT_WT_PREFIX=${AGENT_WT_PREFIX:-$(basename "$REPO")-agent} # worktrees are ../<prefix>-<issue>
AGENT_SETUP_CMD=${AGENT_SETUP_CMD:-}                      # run in each worktree before the agent starts (e.g. dependency install), in the agents' environment
AGENT_VERIFY_CMD=${AGENT_VERIFY_CMD:-}                    # checks that must pass before a PR (told to the agent; used by the Stop hook)
AGENT_LANGUAGE=${AGENT_LANGUAGE:-English}                 # language of commits, PRs, summaries and agent comments
AGENT_PROMPTS_DIR=${AGENT_PROMPTS_DIR:-.agent-loop/prompts} # project prompt overrides (relative to the repo root)
AGENT_PLANS_GLOB=${AGENT_PLANS_GLOB:-}                    # plan files for triage (e.g. 'docs/plans/*.md'); empty disables triage
AGENT_PLANS_ACTIVE_REGEX=${AGENT_PLANS_ACTIVE_REGEX:-^status: active} # a plan counts as active when a line matches; empty = all
AGENT_AUTOCREATE_LABELS=${AGENT_AUTOCREATE_LABELS:-}      # space-separated globs of labels triage may create (e.g. 'phase:*')
AGENT_IGNORE_FEEDBACK_USERS=${AGENT_IGNORE_FEEDBACK_USERS:-github-actions[bot]} # space-separated; their comments never trigger a fix run
AGENT_CLEAN_REVIEW_USER=${AGENT_CLEAN_REVIEW_USER:-claude[bot]} # a "No issues found" comment from this user is not feedback
# Whose words the loop acts on. Comments by anyone else never start a fix run or reach a prompt, and triage never
# adds agent-ok to their issues. On a public repository anyone can comment, so keep this to people you trust.
AGENT_TRUSTED_ASSOCIATIONS=${AGENT_TRUSTED_ASSOCIATIONS:-OWNER MEMBER COLLABORATOR} # GitHub author associations, space-separated ('*' = everyone)
AGENT_TRUSTED_USERS=${AGENT_TRUSTED_USERS:-$AGENT_CLEAN_REVIEW_USER} # space-separated logins trusted whatever their association (review bots)
# Variables removed from the environment of the agents and of AGENT_SETUP_CMD (both run with your own permissions)
AGENT_SCRUB_ENV=${AGENT_SCRUB_ENV:-AWS_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN GOOGLE_APPLICATION_CREDENTIALS AZURE_CLIENT_SECRET SUPABASE_ACCESS_TOKEN SUPABASE_DB_PASSWORD SUPABASE_SERVICE_ROLE_KEY VERCEL_TOKEN VERCEL_ORG_ID VERCEL_PROJECT_ID NPM_TOKEN}
# Variables set in the agents' environment (config-file array of NAME=VALUE)
[ -n "${AGENT_CHILD_ENV+x}" ] || AGENT_CHILD_ENV=(AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null)

if [ -z "$AGENT_BASE_BRANCH" ]; then
  AGENT_BASE_BRANCH=$(git -C "$REPO" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)
  AGENT_BASE_BRANCH=${AGENT_BASE_BRANCH:-main}
fi
BASE_REF="origin/$AGENT_BASE_BRANCH"
case "$AGENT_PROMPTS_DIR" in /*) PROMPTS_DIR=$AGENT_PROMPTS_DIR ;; *) PROMPTS_DIR="$REPO/$AGENT_PROMPTS_DIR" ;; esac

# jq function: is an author (login, author association) trusted? The jq call must pass
# --arg assoc "$AGENT_TRUSTED_ASSOCIATIONS" --arg users "$AGENT_TRUSTED_USERS".
# shellcheck disable=SC2016
JQ_TRUSTED='def trusted($u; $a):
  ($assoc | split(" ") | map(select(. != ""))) as $as | ($users | split(" ") | map(select(. != ""))) as $us
  | (($as | index("*")) != null) or (($as | index($a // "")) != null) or (($us | index($u // "")) != null);'

AGENT_MARKER='🤖 agent:'   # comments that start with this are the agent's own and never count as "new feedback"
L_OK=agent-ok L_WIP=agent-wip L_BLOCKED=agent-blocked L_HUMAN=human

mkdir -p "$STATE/running" "$STATE/count" "$STATE/stamp" "$STATE/logs"

# --- Permissions given to the implement / fix agent ---
# Denies are written so they also match in the middle of a command line (e.g. `tool --flag x deploy`), not only as a prefix.
WORKER_ALLOW=(
  "Bash(git status:*)" "Bash(git diff:*)" "Bash(git log:*)" "Bash(git show:*)" "Bash(git add:*)"
  "Bash(git commit:*)" "Bash(git fetch:*)" "Bash(git merge:*)" "Bash(git push:*)"
  "Bash(gh issue view:*)" "Bash(gh pr view:*)" "Bash(gh pr create:*)" "Bash(gh pr checks:*)"
  "Bash(gh pr diff:*)" "Bash(gh pr comment:*)" "Bash(gh run view:*)" "Bash(gh run list:*)"
  ${AGENT_EXTRA_ALLOW[@]+"${AGENT_EXTRA_ALLOW[@]}"}
)
WORKER_DENY=(
  # GitHub: merge, close, labels, raw API, tokens. Labels: the `gh label` command and the --label / --add-label /
  # --remove-label options (not every command that mentions labels: `gh issue view --json labels` only reads)
  "Bash(*gh *pr merge*)" "Bash(*gh *pr close*)" "Bash(*gh *pr ready*)" "Bash(*gh *issue close*)"
  "Bash(*gh *issue edit*)" "Bash(*gh *issue delete*)" "Bash(*gh api*)" "Bash(*gh label*)" "Bash(*gh * label *)" "Bash(*gh *-label*)" "Bash(*gh auth*)"
  "Bash(*gh *repo *)" "Bash(*gh *secret*)" "Bash(*gh *variable*)" "Bash(*gh *workflow*)" "Bash(*gh *release*)"
  # git: rewriting history (including +refspec force-pushes) and worktree management
  "Bash(git push*--force*)" "Bash(git push* -f*)" "Bash(git push*+*)" "Bash(git rebase:*)"
  "Bash(git reset --hard:*)" "Bash(git worktree:*)"
  # git: pushing to the base branch, as a branch name or as the target of a refspec (branch protection is the real
  # guard; this is a second layer)
  "Bash(git push* ${AGENT_BASE_BRANCH})" "Bash(git push* ${AGENT_BASE_BRANCH} *)"
  "Bash(git push*:${AGENT_BASE_BRANCH})" "Bash(git push*:${AGENT_BASE_BRANCH} *)"
  "Bash(git push*:refs/heads/${AGENT_BASE_BRANCH}*)"
  # Credential stores (Read and Bash). The main checkout's .env files may hold production keys: Read is denied for
  # them, and Bash for commands that name them by absolute path or as .env.local / .env.production. (A relative
  # path to a plain .env matches no rule; a rule for "*.env*" would also deny every command that mentions process.env.)
  "Read(~/.aws/**)" "Bash(*.aws/*)" "Read(~/.ssh/**)" "Read(~/.config/gh/**)" "Bash(*.config/gh*)"
  "Read(~/Library/Keychains/**)" "Bash(security *)" "Bash(*&& security *)"
  "Read(/${REPO}/.env)" "Read(/${REPO}/.env.local)" "Read(/${REPO}/.env.production)" "Read(/${REPO}/.env.*.local)"
  "Bash(*.env.local*)" "Bash(*.env.production*)" "Bash(*${REPO}/.env*)"
  ${AGENT_EXTRA_DENY[@]+"${AGENT_EXTRA_DENY[@]}"}
)
# The triage agent only reads. This also overrides the project's .claude/settings.json allows (git commit, push, ...).
TRIAGE_DENY=(
  "${WORKER_DENY[@]}" Edit Write NotebookEdit
  "Bash(git add:*)" "Bash(git commit:*)" "Bash(git push:*)" "Bash(git merge:*)" "Bash(git checkout:*)" "Bash(git switch:*)"
  "Bash(*gh *create*)" "Bash(*gh *comment*)" "Bash(*gh *edit*)" "Bash(rm:*)"
  ${AGENT_EXTRA_TRIAGE_DENY[@]+"${AGENT_EXTRA_TRIAGE_DENY[@]}"}
)
WORKER_SCHEMA='{"type":"object","required":["status","summary"],"properties":{
  "status":{"type":"string","enum":["pr_opened","fixed","blocked","failed"]},
  "pr_number":{"type":"integer"},
  "summary":{"type":"string","description":"What you did, in '"$AGENT_LANGUAGE"', 1-3 sentences"},
  "blocked_reason":{"type":"string","description":"Only when blocked/failed: what a human must decide or do, in '"$AGENT_LANGUAGE"'"}}}'

log() { printf '%s %s\n' "$(date '+%m-%d %H:%M:%S')" "$*" >&2; }
die() { log "error: $*"; exit 1; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# With DRY=1, commands that change something are printed instead of run
run() { if [ "${DRY:-0}" = 1 ]; then log "[dry-run] $*"; else "$@"; fi; }

# Something needs a person. Two channels, both off with AGENT_NOTIFY=0:
#  - GitHub: the loop's comments on blocked issues and opened PRs mention AGENT_NOTIFY_USER (see `mention`), and GitHub
#    sends the mobile push and the email. (GitHub does not notify you about your own comments, so this works when the
#    loop's `gh` account is not AGENT_NOTIFY_USER.)
#  - AGENT_NOTIFY_CMD: run with the title and body as arguments, and the issue or PR URL in $AGENT_NOTIFY_URL.
# A failing notification is logged and ignored. The usage-limit pause has no issue to comment on, so it only uses the command.
notify() { # title body [url]
  [ "$AGENT_NOTIFY" = 1 ] && [ -n "$AGENT_NOTIFY_CMD" ] || return 0
  [ "${DRY:-0}" = 1 ] && { log "[dry-run] notify: $1: $2"; return 0; }
  AGENT_NOTIFY_TITLE=$1 AGENT_NOTIFY_BODY=$2 AGENT_NOTIFY_URL=${3:-} \
    bash -c "$AGENT_NOTIFY_CMD \"\$@\"" agent-loop-notify "$1" "$2" >/dev/null 2>&1 ||
    log "notification command failed (exit $?); ignored"
  return 0
}

# "@user" for the loop's comments, or nothing when notifications are off or no user is set
mention() { if [ "$AGENT_NOTIFY" = 1 ] && [ -n "$AGENT_NOTIFY_USER" ]; then echo "@${AGENT_NOTIFY_USER#@}"; fi; }

gh_repo() {
  [ -s "$STATE/repo" ] || gh repo view --json nameWithOwner -q .nameWithOwner >"$STATE/repo"
  cat "$STATE/repo"
}

issue_url() { echo "https://${GH_HOST:-github.com}/$(gh_repo)/issues/$1"; }
pr_url() { echo "https://${GH_HOST:-github.com}/$(gh_repo)/pull/$1"; }

wt_of() { echo "$(dirname "$REPO")/$AGENT_WT_PREFIX-$1"; }
br_of() { echo "agent/issue-$1"; }

# --- Running agents (pid files) ---
# loop.sh starts each agent as the leader of its own process group, so stopping the group also stops `claude`
# and everything it started. A `work` run started by hand is not a group leader: stop its children, then it.
stop_agent() { # pid
  kill -TERM -- "-$1" 2>/dev/null && return 0
  pkill -TERM -P "$1" 2>/dev/null || true
  kill -TERM "$1" 2>/dev/null
}
pid_file() { echo "$STATE/running/$1.pid"; }
is_running() { local f; f=$(pid_file "$1"); [ -f "$f" ] && kill -0 "$(cat "$f")" 2>/dev/null; }
running_count() {
  local c=0 f
  for f in "$STATE"/running/*.pid; do
    [ -f "$f" ] || continue
    if kill -0 "$(cat "$f")" 2>/dev/null; then c=$((c + 1)); else rm -f "$f"; fi
  done
  echo "$c"
}

# --- Counters and timestamps (per issue) ---
count_get() { cat "$STATE/count/$1-$2" 2>/dev/null || echo 0; }
count_inc() { local v; v=$(($(count_get "$1" "$2") + 1)); echo "$v" >"$STATE/count/$1-$2"; echo "$v"; }
count_reset() { rm -f "$STATE/count/$1-$2"; }
count_dec() { local v; v=$(($(count_get "$1" "$2") - 1)); [ "$v" -gt 0 ] && echo "$v" >"$STATE/count/$1-$2" || rm -f "$STATE/count/$1-$2"; }
stamp_get() { cat "$STATE/stamp/$1-$2" 2>/dev/null || echo "${3:-1970-01-01T00:00:00Z}"; }
stamp_set() { echo "$3" >"$STATE/stamp/$1-$2"; }
forget_issue() { rm -f "$STATE"/count/*-"$1" "$STATE"/stamp/*-"$1"; }

# --- GitHub ---
label_add() { run gh issue edit "$1" --add-label "$2" >/dev/null; }
label_remove() { run gh issue edit "$1" --remove-label "$2" >/dev/null 2>&1 || true; }
issue_comment() { run gh issue comment "$1" --body "$AGENT_MARKER $2" >/dev/null; }

ensure_labels() {
  local have l
  have=$(gh label list --limit 200 --json name -q '.[].name')
  for l in "$L_OK:07a540:An agent may work on this" "$L_WIP:fbca04:An agent is working on this, or its PR awaits review" \
    "$L_BLOCKED:b60205:The agent stopped and needs a human decision (answer in a comment, then remove this label to resume)" \
    "$L_HUMAN:0e8a16:Work only a person can do (agent-ok is never added)"; do
    echo "$have" | grep -qx "${l%%:*}" && continue
    run gh label create "${l%%:*}" --color "$(echo "$l" | cut -d: -f2)" --description "${l#*:*:}" >/dev/null
  done
}

# All open issues with labels, parent/child links and dependencies (a JSON array). One GraphQL call per 100 issues.
issues_snapshot() {
  local r q pages after="" page
  r=$(gh_repo)
  q='query($o:String!,$r:String!,$after:String){repository(owner:$o,name:$r){
      issues(first:100,after:$after,states:OPEN,orderBy:{field:CREATED_AT,direction:ASC}){
      pageInfo{hasNextPage endCursor}
      nodes{number title body author{login} authorAssociation labels(first:30){nodes{name}} parent{number}
        subIssues(first:50){nodes{number state}} blockedBy(first:30){nodes{number state}}}}}}'
  pages=$(mktemp "$STATE/issues.XXXXXX")
  while :; do
    if [ -n "$after" ]; then page=$(gh api graphql -f o="${r%/*}" -f r="${r#*/}" -f after="$after" -f query="$q")
    else page=$(gh api graphql -f o="${r%/*}" -f r="${r#*/}" -f query="$q"); fi
    printf '%s\n' "$page" | jq -c '.data.repository.issues.nodes' >>"$pages"
    [ "$(printf '%s' "$page" | jq -r '.data.repository.issues.pageInfo.hasNextPage')" = true ] || break
    after=$(printf '%s' "$page" | jq -r '.data.repository.issues.pageInfo.endCursor')
  done
  jq -s 'add // []' "$pages" | snapshot_normalize
  rm -f "$pages"
}

# Raw GraphQL issue nodes (a JSON array on stdin) -> the snapshot format the loop uses
snapshot_normalize() {
    jq 'map({number, title, body: (.body // ""), parent: .parent.number,
             author: .author.login, authorAssociation,
             labels: [.labels.nodes[].name], subIssues: [.subIssues.nodes[] | {number, state}],
             blockedBy: [.blockedBy.nodes[] | select(.state == "OPEN") | .number],
             # a "Depends on: #12, #13" line in the body also counts as a dependency (the Japanese "依存:" is accepted too)
             bodyDeps: [(.body // "") | split("\n")[] | select(test("^\\s*(依存|Depends on|Blocked by)\\s*[:：]"; "i"))
                        | scan("#([0-9]+)") | .[0] | tonumber]})'
}

# Issues an agent can start, lowest number first: agent-ok, not human/blocked, not a parent, all dependencies closed
ready_issues() { # snapshot.json
  jq -r --arg ok "$L_OK" --arg h "$L_HUMAN" --arg b "$L_BLOCKED" '
    [.[].number] as $open
    | .[] | select((.labels | index($ok)) and ((.labels | index($h)) | not) and ((.labels | index($b)) | not))
    | select((.subIssues | length) == 0)
    | select((.blockedBy | length) == 0)
    | select([.bodyDeps[] as $d | $open | index($d)] | all(. == null))
    | .number' "$1"
}

has_label() { # snapshot.json issue label
  jq -e --argjson n "$2" --arg l "$3" '.[] | select(.number == $n) | .labels | index($l)' "$1" >/dev/null
}

# Open PRs on agent branches (JSON array, with the issue number). A PR from a fork is never an agent PR, even when
# its branch is named like one: anyone can open such a PR.
agent_prs() {
  gh pr list --state open --limit 100 --json number,headRefName,headRefOid,isCrossRepository,mergeable,statusCheckRollup |
    jq '[.[] | select(.isCrossRepository | not) | select(.headRefName | test("^agent/issue-[0-9]+$"))
         | {pr: .number, issue: (.headRefName | ltrimstr("agent/issue-") | tonumber), head: .headRefOid, mergeable,
            checks: [.statusCheckRollup[]? | {name: (.name // .context), status: (.status // "COMPLETED"),
                                               conclusion: (.conclusion // .state)}]}]'
}

pr_of_branch() { # branch state(open|merged|closed|all) -> PR number (PRs from forks do not count)
  gh pr list --head "$1" --state "$2" --limit 20 --json number,isCrossRepository \
    -q '[.[] | select(.isCrossRepository | not)][0].number // empty'
}

# The most recent PR of a branch that is no longer open, as "<number> <MERGED|CLOSED>" (PRs from forks do not count)
last_done_pr() { # branch
  gh pr list --head "$1" --state all --limit 30 --json number,state,isCrossRepository \
    -q '[.[] | select((.isCrossRepository | not) and .state != "OPEN")] | max_by(.number) // empty | "\(.number) \(.state)"'
}

# New feedback on a PR since a timestamp. Only from trusted authors (AGENT_TRUSTED_ASSOCIATIONS / AGENT_TRUSTED_USERS):
# the text goes into the fix prompt, so nobody else may put words there. Also excludes ignored bots, the agent's own
# comments and reviews with no comment
pr_feedback() { # pr since
  local r; r=$(gh_repo)
  {
    gh api --paginate "repos/$r/issues/$1/comments" --jq '.[] | {u: .user.login, a: .author_association, t: .created_at, where: "PR comment", b: (.body // "")}'
    gh api --paginate "repos/$r/pulls/$1/comments" --jq '.[] | {u: .user.login, a: .author_association, t: .created_at, where: "\(.path):\(.line // .original_line // "")", b: (.body // "")}'
    gh api --paginate "repos/$r/pulls/$1/reviews" --jq '.[] | {u: .user.login, a: .author_association, t: .submitted_at, where: "review (\(.state))", b: (.body // "")}'
  } | jq -s --arg since "$2" --arg m "$AGENT_MARKER" --arg ign "$AGENT_IGNORE_FEEDBACK_USERS" --arg clean "$AGENT_CLEAN_REVIEW_USER" \
    --arg assoc "$AGENT_TRUSTED_ASSOCIATIONS" --arg users "$AGENT_TRUSTED_USERS" "$JQ_TRUSTED"'
    ($ign | split(" ")) as $ig
    | [.[] | select(.t > $since) | select(.u as $u | $ig | index($u) | not)
         | select(trusted(.u; .a))
         | select((.b | gsub("\\s"; "")) != "") | select(.b | startswith($m) | not)
         | select((.u == $clean and (.b | test("No issues found"))) | not)]'
}

# Why a PR needs a fix run (JSON). Takes one agent_prs entry and the time to read feedback from
pr_fix_reasons() { # pr_json since
  local pr fb
  pr=$(echo "$1" | jq -r .pr)
  fb=$(pr_feedback "$pr" "$2")
  echo "$1" | jq --argjson fb "$fb" --arg ignore "$AGENT_IGNORE_CHECKS" '
    ($ignore | split(",")) as $ig
    | {pr, head, conflict: (.mergeable == "CONFLICTING"),
       failing: [.checks[] | select(.status == "COMPLETED")
                 | select(.conclusion as $c | ["FAILURE", "TIMED_OUT", "ERROR", "ACTION_REQUIRED", "STARTUP_FAILURE"] | index($c))
                 | .name | select(. as $n | $ig | index($n) | not)] | unique,
       feedback: $fb}
    | .needed = (.conflict or (.failing | length > 0) or (.feedback | length > 0))
    | .signature = "\(.head)|\(.conflict)|\(.failing | join(","))|\([.feedback[].t] | max // "")"'
}

# Wait for a human (agent-blocked): comment the reason on the issue and notify
block_issue() { # issue reason
  local cc; cc=$(mention)
  label_add "$1" "$L_BLOCKED"
  label_remove "$1" "$L_WIP"
  issue_comment "$1" "Stopped working on this.

$2

Write your answer or the missing information in a comment on this issue, then remove the \`$L_BLOCKED\` label to resume from where it stopped.${cc:+

cc $cc}"
  count_reset attempts "$1"
  count_reset fixes "$1"
  rm -f "$STATE/stamp/sig-$1"
  notify "Agent stopped (#$1)" "$2" "$(issue_url "$1")"
}

# --- Spend and tokens (from the result files in the logs; no model call) ---
# Result files are logs/issue-<n>-<YYYYMMDD>-<HHMMSS>-<mode>.json and logs/triage-<YYYYMMDD>-<HHMMSS>.json.
# Sum a jq expression over every result file written today (local day)
sum_today() { # jq-expression
  local d f; d=$(date +%Y%m%d)
  for f in "$STATE"/logs/*-"$d"-*.json; do
    [ -f "$f" ] && { jq -r "$1" "$f" 2>/dev/null || true; }
  done | awk '{ s += $1 } END { printf "%.2f", s + 0 }'
}
# API-equivalent dollars spent so far today. On a Pro / Max plan nothing is billed per call: see tokens_today and the plan windows
spend_today() { sum_today '.total_cost_usd // 0'; }
# Tokens used so far today: input + output + cache writes (cache reads are left out: they are cheap and would swamp the sum)
tokens_today() {
  sum_today '(.usage // {}) | (.input_tokens // 0) + (.output_tokens // 0) + (.cache_creation_input_tokens // 0)' | awk '{ printf "%.0f", $1 }'
}
fmt_tokens() { awk -v t="$1" 'BEGIN { if (t >= 1e6) printf "%.1fM", t / 1e6; else if (t >= 1e3) printf "%.0fk", t / 1e3; else printf "%d", t }'; }
# Why no agent may start today: today's spend reached AGENT_DAILY_BUDGET, or today's tokens reached AGENT_DAILY_TOKEN_BUDGET.
# Prints the reason; prints nothing when both are empty or not reached.
budget_reason() {
  local spent tokens
  if [ -n "$AGENT_DAILY_BUDGET" ]; then
    spent=$(spend_today)
    awk -v a="$spent" -v b="$AGENT_DAILY_BUDGET" 'BEGIN { exit !(a + 0 >= b + 0) }' &&
      { echo "\$${spent} of \$${AGENT_DAILY_BUDGET} spent today (AGENT_DAILY_BUDGET)"; return 0; }
  fi
  if [ -n "$AGENT_DAILY_TOKEN_BUDGET" ]; then
    tokens=$(tokens_today)
    awk -v a="$tokens" -v b="$AGENT_DAILY_TOKEN_BUDGET" 'BEGIN { exit !(a + 0 >= b + 0) }' &&
      { echo "$(fmt_tokens "$tokens") of $(fmt_tokens "$AGENT_DAILY_TOKEN_BUDGET") tokens used today (AGENT_DAILY_TOKEN_BUDGET)"; return 0; }
  fi
  return 0
}
over_budget() { [ -n "$(budget_reason)" ]; }

# Does the installed claude CLI have a spend cap option (--max-budget-usd)? The CLI stops at the first unknown option,
# before doing anything: if that is the deliberately bogus last one, the option before it is supported.
claude_has_cost_cap() {
  local probe
  probe=$(claude -p --max-budget-usd 1 --zz-probe </dev/null 2>&1 || true)
  case "$probe" in *"unknown option '--zz-probe'"*) return 0 ;; *) return 1 ;; esac
}

# --- Prompts ---
# A project file in $PROMPTS_DIR replaces the packaged prompt of the same name.
prompt_file() { # name
  if [ -f "$PROMPTS_DIR/$1.md" ]; then echo "$PROMPTS_DIR/$1.md"; else echo "$PKG_DIR/prompts/$1.md"; fi
}

# Replace {{KEY}} in a template with the value of environment variable T_KEY (values may contain newlines and symbols)
render() { # file
  awk '{ line = $0; out = ""
         while (match(line, /[{][{][A-Z_]+[}][}]/)) {
           k = substr(line, RSTART + 2, RLENGTH - 4)
           out = out substr(line, 1, RSTART - 1) ENVIRON["T_" k]; line = substr(line, RSTART + RLENGTH) }
         print out line }' "$1"
}

# Render a prompt with the variables every prompt can use. Callers export T_* for the rest.
render_prompt() { # name
  T_BASE=$AGENT_BASE_BRANCH
  T_LANGUAGE=$AGENT_LANGUAGE
  T_TRUSTED="author association ${AGENT_TRUSTED_ASSOCIATIONS// /, }${AGENT_TRUSTED_USERS:+; or user ${AGENT_TRUSTED_USERS// /, }}"
  if [ -n "$AGENT_VERIFY_CMD" ]; then T_VERIFY="\`$AGENT_VERIFY_CMD\`"
  else T_VERIFY="the project's own checks (see CLAUDE.md, README.md and the CI configuration)"; fi
  T_PROJECT=""
  # project.md: HTML comments (the instructions in the template) are not sent to the agent
  [ -f "$PROMPTS_DIR/project.md" ] && T_PROJECT=$(awk '/<!--/ { c = 1 } !c { print } /-->/ { c = 0 }' "$PROMPTS_DIR/project.md")
  [ -n "$(echo "$T_PROJECT" | tr -d '[:space:]')" ] || T_PROJECT="(none)"
  export T_BASE T_LANGUAGE T_TRUSTED T_VERIFY T_PROJECT
  render "$(prompt_file "$1")"
}

# --- Usage limits (subscription 5-hour / weekly windows, API 429, overload 529) ---
# A run stopped by a limit is not counted as a failure; loop.sh starts no new agents until the limit resets.
PAUSE_FILE="$STATE/paused-until"

# Last result event of a `claude -p --output-format stream-json` recording (JSONL)
result_of() { jq -Rnc '[inputs | fromjson? | select(.type == "result")] | last // empty' "$1" 2>/dev/null; }

# If the recording ended on a usage limit or overload, print the epoch second to resume at; otherwise fail
limit_resume_at() { # stream.jsonl
  local now kind
  now=$(date +%s)
  kind=$(jq -Rnr '[inputs | fromjson?] as $ev
    | ([$ev[] | select(.type == "rate_limit_event") | .rate_limit_info | select(.status == "rejected") | .resetsAt // empty] | last) as $reset
    | ([$ev[] | select(.type == "result")] | last) as $res
    | (($res.result // "") | tostring) as $text
    | ($reset | if type == "number" then (if . > 1e12 then . / 1000 else . end)
                elif type == "string" then ((tonumber? // (sub("\\.[0-9]+"; "") | fromdateiso8601?)) // null)
                else null end) as $sec
    | if $sec != null then ($sec | floor | tostring)
      elif $reset != null then "limit"
      elif $res == null then empty
      elif $res.api_error_status == 429 or ($text | test("hit your .*limit|out of extra usage|usage limit reached|rate.?limit"; "i")) then "limit"
      elif $res.api_error_status == 529 or ($text | test("overloaded"; "i")) then "busy"
      else empty end' "$1" 2>/dev/null) || return 1
  case "$kind" in
    '') return 1 ;;
    limit) echo $((now + AGENT_LIMIT_PAUSE_SECONDS)) ;;
    busy) echo $((now + 300)) ;;
    *) [ "$kind" -gt "$now" ] && echo $((kind + 60)) || echo $((now + 300)) ;;
  esac
}

paused_until() { cat "$PAUSE_FILE" 2>/dev/null || echo 0; }
paused() { [ "$(date +%s)" -lt "$(paused_until)" ]; }
fmt_epoch() { date -r "$1" '+%m/%d %H:%M' 2>/dev/null || date -d "@$1" '+%m/%d %H:%M'; }  # BSD date, then GNU date
pause_until() { # epoch [reason] (only ever extends the current pause)
  local why=${2:-Stopped by a usage limit (or overload)}
  [ "$1" -gt "$(paused_until)" ] || return 0
  echo "$1" >"$PAUSE_FILE"
  log "${why}. Not starting new agents until $(fmt_epoch "$1")"
  notify "Agents paused" "${why}. Resuming at $(fmt_epoch "$1")"
}

# The plan windows (five_hour, seven_day, ...) of the last usage reading in a recording, kept for `agent-loop status`
USAGE_FILE="$STATE/usage-windows.json"
record_usage_windows() { # stream.jsonl
  local w
  w=$(jq -Rnc '[inputs | fromjson? | select(.type == "rate_limit_event") | .rate_limit_info.unifiedWindows // empty] | last // empty' "$1" 2>/dev/null) || return 0
  [ -n "$w" ] || return 0
  jq -nc --argjson w "$w" '{windows: $w}' >"$USAGE_FILE" || true
}
# One line per plan window that has not reset yet: "five_hour 62% (resets 11/14 18:00)"
show_usage_windows() {
  [ -f "$USAGE_FILE" ] || return 0
  local name pct reset
  jq -r --argjson now "$(date +%s)" '.windows | to_entries[]
    | select((.value.resetsAt | type) == "number")
    | (.value.resetsAt | if . > 1e12 then . / 1000 else . end | floor) as $r | select($r > $now)
    | "\(.key) \((.value.utilization // 0) * 100 | floor)% \($r)"' "$USAGE_FILE" 2>/dev/null |
  while read -r name pct reset; do echo "$name $pct (resets $(fmt_epoch "$reset"))"; done
}

# If the last usage reading in a recording is over AGENT_PAUSE_AT_UTILIZATION, pause until that window resets
pause_if_heavy_usage() { # stream.jsonl
  local w
  record_usage_windows "$1"
  w=$(jq -Rnr --argjson t "$AGENT_PAUSE_AT_UTILIZATION" '
    [inputs | fromjson? | select(.type == "rate_limit_event") | .rate_limit_info] | last // empty
    | [.unifiedWindows // {} | to_entries[] | select((.value.utilization // 0) >= $t and (.value.resetsAt | type) == "number")]
    | max_by(.value.resetsAt) // empty
    | "\(.value.resetsAt | if . > 1e12 then . / 1000 else . end | floor) \(.key) \(.value.utilization * 100 | floor)"' "$1" 2>/dev/null) || return 0
  [ -n "$w" ] || return 0
  set -- $w
  pause_until "$(($1 + 60))" "Usage ($2) reached ${3}% (threshold AGENT_PAUSE_AT_UTILIZATION=${AGENT_PAUSE_AT_UTILIZATION})"
}

# --settings JSON for the implement / fix agent: a Stop hook that runs AGENT_VERIFY_CMD before the agent may finish.
# Passed per run, so the project needs no hook of its own and people's interactive sessions are unaffected.
agent_settings() {
  if [ -z "$AGENT_VERIFY_CMD" ]; then echo '{}'; return; fi
  jq -nc --arg cmd "\"$LIBEXEC/verify-hook.sh\" --loop" --argjson t "$AGENT_VERIFY_TIMEOUT" \
    '{hooks: {Stop: [{hooks: [{type: "command", command: $cmd, timeout: $t}]}]}}'
}

# Run a command with credential variables removed from the environment (AGENT_SCRUB_ENV) and AGENT_CHILD_ENV set.
# Credential files are kept away from the agent by the Read/Bash denies in WORKER_DENY. Best effort, not a sandbox.
without_credentials() {
  local args=() v
  for v in $AGENT_SCRUB_ENV; do args+=(-u "$v"); done
  env ${args[@]+"${args[@]}"} ${AGENT_CHILD_ENV[@]+"${AGENT_CHILD_ENV[@]}"} "$@"
}
