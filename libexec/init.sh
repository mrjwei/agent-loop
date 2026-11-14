#!/usr/bin/env bash
# Set up the current project for agent-loop, or check the tools it needs.
#   agent-loop init [--force] [--hook] [--workflows] [--plan] [--no-labels] [--dry-run]
#   agent-loop doctor      (init.sh --check)
#   agent-loop labels      (init.sh --labels-only)
set -euo pipefail
. "$(dirname "$0")/../lib/common.sh"

mode=init force=0 hook=0 labels=1 workflows=0 plan=0
for a in "$@"; do
  case "$a" in
    --force) force=1 ;;
    --hook) hook=1 ;;
    --no-hook) hook=0 ;;   # the default since the loop passes its own hook; kept for old scripts
    --workflows) workflows=1 ;;
    --plan) plan=1 ;;
    --no-labels) labels=0 ;;
    --dry-run) DRY=1 ;;
    --check) mode=check ;;
    --labels-only) mode=labels ;;
    *) die "unknown argument: $a" ;;
  esac
done
export DRY=${DRY:-0}

# Who the loop acts as, and whether that is a good account for it (README: "Run the loop as a machine account")
check_account() {
  local me perm
  me=$(gh_user)
  [ -n "$me" ] || { echo "info     could not read the GitHub user gh acts as"; return 0; }
  echo "info     the loop acts as GitHub user $me"
  if [ "$AGENT_NOTIFY" = 1 ] && same_login "$me" "$AGENT_NOTIFY_USER"; then
    echo "WARNING  the loop's gh user ($me) is AGENT_NOTIFY_USER: GitHub does not notify you of your own mentions, so the comments on blocked issues and opened PRs stay silent${AGENT_NOTIFY_CMD:+ (AGENT_NOTIFY_CMD still works)}. Run the loop as a machine account (see the README)"
  fi
  perm=$(gh repo view --json viewerPermission -q .viewerPermission 2>/dev/null || true)
  if [ "$perm" = ADMIN ]; then
    echo "WARNING  $me has admin permission on this repository, and the loop holds its token. Run the loop with a token that can write but not administer (see the README: \"Run the loop as a machine account\")"
  fi
  return 0
}

check_prereqs() {
  local t bad=0
  for t in git jq gh claude; do
    if command -v "$t" >/dev/null 2>&1; then echo "ok       $t ($(command -v "$t"))"
    else echo "MISSING  $t"; bad=1; fi
  done
  if command -v gh >/dev/null 2>&1; then
    if gh auth status >/dev/null 2>&1; then echo "ok       gh is authenticated"; check_account
    else echo "WARNING  gh is not authenticated (run: gh auth login)"; fi
  fi
  if ! git rev-parse --path-format=absolute --git-common-dir >/dev/null 2>&1; then
    echo "MISSING  git >= 2.31 (needs rev-parse --path-format)"; bad=1
  fi
  if command -v claude >/dev/null 2>&1; then
    echo "info     $(claude --version 2>/dev/null | head -1)"
    # Options the loop passes. The CLI stops at the first unknown option, before doing anything: if that is the
    # deliberately bogus last one, every option before it is supported.
    local probe
    probe=$(claude -p --json-schema '{}' --effort high --name x --max-turns 1 --strict-mcp-config --settings '{}' \
      --zz-probe </dev/null 2>&1 || true)
    if echo "$probe" | grep -q "unknown option '--zz-probe'"; then echo "ok       claude supports the options the loop uses"
    else echo "WARNING  claude may be too old for --json-schema / --effort / --name (update it: claude update)"; fi
  fi
  if command -v claude >/dev/null 2>&1; then
    if claude_has_cost_cap; then echo "ok       claude has a spend cap option (--max-budget-usd): AGENT_MAX_COST_PER_RUN works"
    elif [ -n "$AGENT_MAX_COST_PER_RUN" ]; then echo "WARNING  claude has no --max-budget-usd: AGENT_MAX_COST_PER_RUN will be skipped"
    else echo "info     claude has no --max-budget-usd, so AGENT_MAX_COST_PER_RUN could not be used"; fi
  fi
  if git -C "$REPO" remote get-url origin >/dev/null 2>&1; then echo "ok       remote origin: $(git -C "$REPO" remote get-url origin)"
  else echo "WARNING  no 'origin' remote: the loop pushes branches and opens PRs through GitHub"; fi
  if ! git -C "$REPO" symbolic-ref --quiet refs/remotes/origin/HEAD >/dev/null 2>&1 && ! grep -qs '^AGENT_BASE_BRANCH=' "$AGENT_CONF"; then
    echo "WARNING  origin/HEAD is not set, so the base branch defaults to 'main' (fix: git remote set-head origin --auto, or set AGENT_BASE_BRANCH)"
  fi
  echo "info     base branch: $AGENT_BASE_BRANCH, worktrees: $(dirname "$REPO")/$AGENT_WT_PREFIX-<issue>"
  [ -f "$AGENT_CONF" ] && echo "ok       config: $AGENT_CONF" || echo "info     no $AGENT_CONF yet (agent-loop init creates it)"
  return $bad
}

# Write stdin to a file unless it exists (or --force); honours --dry-run
put() { # dest
  local dest=$1
  if [ -e "$dest" ] && [ "$force" != 1 ]; then log "kept existing ${dest#"$REPO"/} (use --force to overwrite)"; cat >/dev/null; return 0; fi
  if [ "$DRY" = 1 ]; then log "[dry-run] would write ${dest#"$REPO"/}"; cat >/dev/null; return 0; fi
  mkdir -p "$(dirname "$dest")"
  cat >"$dest"
  log "wrote ${dest#"$REPO"/}"
}

# Guess setup and verify commands from the project's files (the user edits them afterwards)
detect_commands() {
  SETUP="" VERIFY=""
  local pm s parts=()
  if [ -f "$REPO/package.json" ]; then
    pm=npm
    [ -f "$REPO/pnpm-lock.yaml" ] && pm=pnpm
    [ -f "$REPO/yarn.lock" ] && pm=yarn
    case "$pm" in
      pnpm) SETUP="pnpm install --frozen-lockfile --silent" ;;
      yarn) SETUP="yarn install --frozen-lockfile --silent" ;;
      *) if [ -f "$REPO/package-lock.json" ]; then SETUP="npm ci --silent"; else SETUP="npm install --silent"; fi ;;
    esac
    for s in lint test build; do
      jq -e --arg s "$s" '.scripts[$s]' "$REPO/package.json" >/dev/null 2>&1 && parts+=("$pm run $s")
    done
    [ ${#parts[@]} -gt 0 ] && VERIFY=$(printf '%s && ' "${parts[@]}" | sed 's/ && $//')
  elif [ -f "$REPO/go.mod" ]; then VERIFY="go vet ./... && go test ./..."
  elif [ -f "$REPO/Cargo.toml" ]; then VERIFY="cargo test"
  elif [ -f "$REPO/Makefile" ]; then
    for s in check test; do
      grep -Eq "^$s:" "$REPO/Makefile" && { VERIFY="make $s"; break; }
    done
  fi
  return 0
}

install_hook() {
  local dest="$REPO/.claude/hooks/agent-loop-verify.sh" settings="$REPO/.claude/settings.json"
  local cmd='"$CLAUDE_PROJECT_DIR"/.claude/hooks/agent-loop-verify.sh' new
  put "$dest" <"$PKG_DIR/libexec/verify-hook.sh"
  [ -f "$dest" ] && chmod +x "$dest"
  if [ -f "$settings" ]; then
    new=$(jq --arg cmd "$cmd" --argjson t "$AGENT_VERIFY_TIMEOUT" '
      .hooks = (.hooks // {})
      | .hooks.Stop = ((.hooks.Stop // [])
          | if any(.[]; ((.hooks // []) | any(.[]; (.command // "") | contains("agent-loop-verify")))) then .
            else . + [{hooks: [{type: "command", command: $cmd, timeout: $t}]}] end)' "$settings") ||
      die "could not parse $settings"
    if [ "$new" = "$(jq . "$settings")" ]; then log "Stop hook already in .claude/settings.json"; return 0; fi
    if [ "$DRY" = 1 ]; then log "[dry-run] would add the Stop hook to .claude/settings.json"; return 0; fi
    cp "$settings" "$STATE/settings.json.bak"
    printf '%s\n' "$new" >"$settings"
    log "added the Stop hook to .claude/settings.json (backup: .git/agent-loop/settings.json.bak)"
  else
    new=$(jq -n --arg cmd "$cmd" --argjson t "$AGENT_VERIFY_TIMEOUT" '{hooks: {Stop: [{hooks: [{type: "command", command: $cmd, timeout: $t}]}]}}')
    printf '%s\n' "$new" | put "$settings"
  fi
}

case "$mode" in
  check) check_prereqs; exit $? ;;
  labels) ensure_labels; exit 0 ;;
esac

echo "Checking prerequisites for $REPO"
check_prereqs || die "install the missing tools first"
echo

detect_commands
# The authenticated GitHub user is who the loop's comments mention (AGENT_NOTIFY_USER)
export T_SETUP_CMD="$SETUP" T_VERIFY_CMD="$VERIFY" T_WT_PREFIX="$AGENT_WT_PREFIX" \
  T_NOTIFY_USER="${AGENT_NOTIFY_USER:-$(gh api user -q .login 2>/dev/null || true)}"
render "$PKG_DIR/templates/agent-loop.conf" | put "$REPO/.agent-loop.conf"
put "$PROMPTS_DIR/project.md" <"$PKG_DIR/templates/project.md"
[ "$hook" = 1 ] && install_hook
# The review workflow (see "Review workflow" in the README); an existing file is left alone unless --force
if [ "$workflows" = 1 ]; then
  put "$REPO/.github/workflows/claude-code-review.yml" <"$PKG_DIR/templates/github/claude-code-review.yml"
fi
# The plan template. `status: template` keeps triage and plan-lint from reading the example items as a plan.
if [ "$plan" = 1 ]; then
  sed 's/^status: active$/status: template/' "$PKG_DIR/templates/plan.md" | put "$REPO/docs/plans/TEMPLATE.md"
fi
if [ "$labels" = 1 ]; then
  ensure_labels || log "could not create labels (is gh authenticated, and does the repo have a GitHub remote?)"
fi

cat <<EOF

Done. Next steps:
  1. Edit .agent-loop.conf: check AGENT_SETUP_CMD / AGENT_VERIFY_CMD, and add AGENT_EXTRA_DENY rules for every deploy,
     production-database or cloud command in this project.
  2. Write the project rules the agents cannot guess in ${PROMPTS_DIR#"$REPO"/}/project.md.
  3. Commit .agent-loop.conf and .agent-loop/ so teammates share the settings.
  4. Try it without changes or cost:   agent-loop start --once --dry-run --no-triage
  5. Label one small issue 'agent-ok' and run:   agent-loop start --no-triage
EOF
if [ "$workflows" = 1 ]; then
  cat <<'EOF'

The review workflow is in .github/workflows/claude-code-review.yml. It needs the repository secret CLAUDE_CODE_OAUTH_TOKEN and
the Claude GitHub App. See "Review workflow" in the README for AGENT_IGNORE_CHECKS, AGENT_CLEAN_REVIEW_USER and
AGENT_AUTOMERGE_REQUIRE_REVIEW.
EOF
fi
if [ "$plan" = 1 ]; then
  cat <<'EOF'

The plan template is docs/plans/TEMPLATE.md. Copy it to docs/plans/<name>.md for a real plan and check it with: agent-loop plan-lint
EOF
fi
