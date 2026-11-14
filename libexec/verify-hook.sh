#!/usr/bin/env bash
# Claude Code Stop hook: before Claude stops, run AGENT_VERIFY_CMD. If it fails, exit 2 so the failure is fed back and
# Claude keeps working. Does nothing when no command is configured or nothing has changed against the base branch.
#
#   verify-hook.sh --loop   passed by agent-loop to every implement / fix agent (work.sh --settings)
#   verify-hook.sh          a copy installed into a project by `agent-loop init --hook`, for interactive sessions
input=$(cat)
from_loop=0
[ "${1:-}" = --loop ] && from_loop=1
# A project copy steps aside inside agent-loop runs, which already pass their own (the checks would run twice)
[ "$from_loop" = 0 ] && [ "${AGENT_LOOP_RUN:-}" = 1 ] && exit 0
# Already retried once: let it stop; CI is the backstop
echo "$input" | grep -q '"stop_hook_active": *true' && exit 0
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0

if [ "$from_loop" = 0 ]; then
  # Read the project's config: this checkout's copy first, then the main checkout's (agent worktrees). Environment wins.
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0
  main_repo=$(cd "$common/.." && pwd)
  env_cmd=${AGENT_VERIFY_CMD:-} env_base=${AGENT_BASE_BRANCH:-}
  for c in "${AGENT_CONF:-}" "$PWD/.agent-loop.conf" "$main_repo/.agent-loop.conf"; do
    # shellcheck disable=SC1090
    if [ -n "$c" ] && [ -f "$c" ]; then . "$c"; break; fi
  done
  [ -n "$env_cmd" ] && AGENT_VERIFY_CMD=$env_cmd
  [ -n "$env_base" ] && AGENT_BASE_BRANCH=$env_base
fi
[ -n "${AGENT_VERIFY_CMD:-}" ] || exit 0

base=${AGENT_BASE_BRANCH:-}
[ -n "$base" ] || base=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
base=${base:-main}

# Nothing changed against the base branch (questions, planning): nothing to verify
if git diff --quiet HEAD 2>/dev/null && [ -z "$(git ls-files --others --exclude-standard)" ] \
  && git diff --quiet "origin/$base...HEAD" 2>/dev/null; then
  exit 0
fi
# In a loop run, work.sh names a file that exists while the last check failed, so that the next attempt can be told
# the run ended with failing checks (the second stop is allowed even then)
mark=${AGENT_LOOP_VERIFY_MARK:-}
out=$(bash -c "$AGENT_VERIFY_CMD" 2>&1) || {
  [ -z "$mark" ] || echo failed >"$mark" 2>/dev/null
  echo "Checks failed (AGENT_VERIFY_CMD). Fix them before finishing:" >&2
  echo "$out" | tail -40 >&2
  exit 2   # exit 2 = block stopping, feed stderr back to the agent
}
[ -z "$mark" ] || rm -f "$mark"
exit 0
