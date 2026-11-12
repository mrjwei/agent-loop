#!/usr/bin/env bash
# Offline tests for agent-loop: no network, no GitHub, no claude. A fake `gh` answers the calls under test.
# Usage: test/run.sh        (exit status 0 = all passed)
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/agent-loop-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
pass=0 fail=0
ok() { pass=$((pass + 1)); printf 'ok    %s\n' "$1"; }
ng() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
check() { # name expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else ng "$1" "expected [$2] got [$3]"; fi
}

# --- A project repo with an origin, and a fake gh ---
git init -q --bare "$T/origin.git"
git init -q -b main "$T/proj"
git -C "$T/proj" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$T/proj" remote add origin "$T/origin.git"
git -C "$T/proj" push -q origin main
git -C "$T/proj" fetch -q origin
mkdir -p "$T/bin" "$T/fixtures"
cat >"$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Fake gh for test/run.sh
case "$*" in
  "repo view"*) echo "o/r" ;;
  "api graphql"*"after=CURSOR1"*) cat "$FIX/page2.json" ;;
  "api graphql"*) cat "$FIX/page1.json" ;;
  "api --paginate repos/o/r/issues/5/comments"*)
    echo '{"u":"alice","t":"2026-01-02T00:00:00Z","where":"PR comment","b":"Please rename foo"}'
    echo '{"u":"alice","t":"2025-12-01T00:00:00Z","where":"PR comment","b":"old, already handled"}'
    echo '{"u":"me","t":"2026-01-03T00:00:00Z","where":"PR comment","b":"🤖 agent: done"}'
    echo '{"u":"github-actions[bot]","t":"2026-01-03T00:00:00Z","where":"PR comment","b":"deploy preview"}' ;;
  "api --paginate repos/o/r/pulls/5/reviews"*)
    echo '{"u":"claude[bot]","t":"2026-01-04T00:00:00Z","where":"review (COMMENTED)","b":"No issues found."}'
    echo '{"u":"bob","t":"2026-01-04T00:00:00Z","where":"review (APPROVED)","b":""}' ;;
  "api --paginate"*) ;;
  *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$T/bin/gh"
node() { # number title labels-json extra-json
  local x=${4:-}; [ -n "$x" ] || x='{}'
  jq -nc --argjson n "$1" --arg t "$2" --argjson l "$3" --argjson x "$x" \
    '{number: $n, title: $t, body: "", labels: {nodes: ($l | map({name: .}))}, parent: null,
      subIssues: {nodes: []}, blockedBy: {nodes: []}} + $x'
}
{
  echo '{"data":{"repository":{"issues":{"pageInfo":{"hasNextPage":true,"endCursor":"CURSOR1"},"nodes":['
  node 1 ready '["agent-ok"]'; echo ,
  node 2 human '["agent-ok","human"]'; echo ,
  node 3 blocked '["agent-ok","agent-blocked"]'; echo ,
  node 4 parent '["agent-ok"]' '{"subIssues":{"nodes":[{"number":9,"state":"CLOSED"}]}}'; echo ,
  node 5 'graph-blocked' '["agent-ok"]' '{"blockedBy":{"nodes":[{"number":1,"state":"OPEN"}]}}'
  echo ']}}}}'
} >"$T/fixtures/page1.json"
{
  echo '{"data":{"repository":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":['
  node 6 'body-dep-open' '["agent-ok"]' '{"body":"Depends on: #1, #99"}'; echo ,
  node 7 'body-dep-closed' '["agent-ok"]' '{"body":"text\n依存： #98"}'; echo ,
  node 8 'graph-dep-closed' '["agent-ok"]' '{"blockedBy":{"nodes":[{"number":97,"state":"CLOSED"}]}}'; echo ,
  node 10 'no-label' '[]'
  echo ']}}}}'
} >"$T/fixtures/page2.json"
export PATH="$T/bin:$PATH" FIX="$T/fixtures" AGENT_REPO="$T/proj" AGENT_NOTIFY=0
cd "$T/proj" || exit 1

# --- Syntax with the bash the scripts target (macOS 3.2 when present) ---
B=/bin/bash; [ -x "$B" ] || B=bash
for f in "$ROOT"/bin/agent-loop "$ROOT"/lib/common.sh "$ROOT"/libexec/*.sh; do
  if "$B" -n "$f" 2>"$T/err"; then ok "syntax ${f#"$ROOT"/}"; else ng "syntax ${f#"$ROOT"/}" "$(cat "$T/err")"; fi
done

# --- Configuration precedence: environment > .agent-loop.conf > default ---
cat >"$T/proj/.agent-loop.conf" <<'EOF'
AGENT_MAX_PARALLEL=5
AGENT_LANGUAGE=Japanese
AGENT_SETUP_CMD='from conf'
AGENT_EXTRA_DENY=("Bash(*deploy*)")
EOF
out=$(AGENT_MAX_PARALLEL=7 AGENT_SETUP_CMD=$'line1\nline2 "q" $x' "$B" -c '
  . "$0/lib/common.sh"
  printf "%s|%s|%s|%s|" "$AGENT_MAX_PARALLEL" "$AGENT_LANGUAGE" "$AGENT_POLL_SECONDS" "$AGENT_SETUP_CMD"
  printf "%s" "${WORKER_DENY[${#WORKER_DENY[@]}-1]}"' "$ROOT")
check "config: env > conf > default, multi-line env values" $'7|Japanese|300|line1\nline2 "q" $x|Bash(*deploy*)' "$out"
rm -f "$T/proj/.agent-loop.conf"

# shellcheck disable=SC1091
. "$ROOT/lib/common.sh"
set +e

# --- Prompt rendering ---
printf 'a {{N}} b {{VAL}} {{new1}} {{UNSET}}.\n' >"$T/tpl.md"
check "render: placeholders, symbols, lowercase refs kept" 'a 12 b x&y\1/z {{new1}} .' \
  "$(T_N=12 T_VAL='x&y\1/z' render "$T/tpl.md")"
mkdir -p "$PROMPTS_DIR"
printf '<!--\ninstructions\n-->\n- rule one\n' >"$PROMPTS_DIR/project.md"
out=$(T_N=3 T_BRANCH=agent/issue-3 render_prompt implement)
case "$out" in *"- rule one"*) ok "render_prompt: project rules inserted" ;; *) ng "render_prompt: project rules inserted" ;; esac
case "$out" in *instructions*) ng "render_prompt: HTML comments stripped" ;; *) ok "render_prompt: HTML comments stripped" ;; esac
case "$out" in *"{{"[A-Z]*) ng "render_prompt: no placeholders left" "$(echo "$out" | grep -o '{{[A-Z_]*}}' | head -3)" ;; *) ok "render_prompt: no placeholders left" ;; esac
rm -rf "$T/proj/.agent-loop"

# --- Issue snapshot (2 pages) and readiness ---
issues_snapshot >"$T/issues.json"
check "issues_snapshot: follows pagination" 9 "$(jq length "$T/issues.json")"
check "issues_snapshot: body dependencies parsed" '[1,99]|[98]' \
  "$(jq -c '.[] | select(.number == 6) | .bodyDeps' "$T/issues.json")|$(jq -c '.[] | select(.number == 7) | .bodyDeps' "$T/issues.json")"
check "ready_issues: agent-ok, not human/blocked/parent, dependencies closed" '1 7 8' \
  "$(ready_issues "$T/issues.json" | tr '\n' ' ' | sed 's/ $//')"

# --- PR fix reasons ---
pr='{"pr":5,"issue":3,"head":"abc","mergeable":"CONFLICTING","checks":[
  {"name":"test","status":"COMPLETED","conclusion":"FAILURE"},{"name":"claude-review","status":"COMPLETED","conclusion":"FAILURE"},
  {"name":"lint","status":"IN_PROGRESS","conclusion":null},{"name":"build","status":"COMPLETED","conclusion":"SUCCESS"}]}'
AGENT_IGNORE_CHECKS=claude-review
r=$(pr_fix_reasons "$pr" 2026-01-01T00:00:00Z)
check "pr_fix_reasons: conflict, failing checks minus ignored" 'true ["test"] true' \
  "$(echo "$r" | jq -r '"\(.conflict) \(.failing | tojson) \(.needed)"')"
check "pr_fix_reasons: feedback skips old, own, ignored bots, clean reviews, empty reviews" '["Please rename foo"]' \
  "$(echo "$r" | jq -c '[.feedback[].b]')"
check "pr_fix_reasons: nothing new means no fix" false \
  "$(pr_fix_reasons '{"pr":5,"head":"abc","mergeable":"MERGEABLE","checks":[]}' 2026-02-01T00:00:00Z | jq .needed)"

# --- Usage limits ---
now=$(date +%s)
printf '%s\n' '{"type":"system"}' "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"status\":\"rejected\",\"resetsAt\":$((now + 3600))}}" \
  '{"type":"result","subtype":"success","is_error":true,"result":"limit"}' >"$T/limit.jsonl"
check "limit_resume_at: rejected window resumes after its reset" $((now + 3660)) "$(limit_resume_at "$T/limit.jsonl")"
printf '%s\n' '{"type":"result","is_error":true,"api_error_status":429,"result":"x"}' >"$T/429.jsonl"
r=$(limit_resume_at "$T/429.jsonl"); d=$((r - now - AGENT_LIMIT_PAUSE_SECONDS))
[ "$d" -ge 0 ] && [ "$d" -le 5 ] && ok "limit_resume_at: 429 without a reset waits AGENT_LIMIT_PAUSE_SECONDS" || ng "limit_resume_at: 429" "$r"
printf '%s\n' '{"type":"result","subtype":"success","result":"{\"status\":\"pr_opened\"}"}' >"$T/ok.jsonl"
limit_resume_at "$T/ok.jsonl" >/dev/null && ng "limit_resume_at: a normal run is not a limit" || ok "limit_resume_at: a normal run is not a limit"
rm -f "$PAUSE_FILE"
printf '%s\n' "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"status\":\"allowed\",\"unifiedWindows\":{\"five_hour\":{\"utilization\":0.5,\"resetsAt\":$((now + 100))},\"seven_day\":{\"utilization\":0.91,\"resetsAt\":$((now + 9000))}}}}" >"$T/heavy.jsonl"
pause_if_heavy_usage "$T/heavy.jsonl" 2>/dev/null
check "pause_if_heavy_usage: pauses until the heavy window resets" $((now + 9060)) "$(paused_until)"
rm -f "$PAUSE_FILE"

# --- Agent settings (Stop hook) ---
AGENT_VERIFY_CMD=''
check "agent_settings: no verify command, no hook" '{}' "$(agent_settings)"
AGENT_VERIFY_CMD='make test'
check "agent_settings: Stop hook runs verify-hook.sh --loop" "\"$LIBEXEC/verify-hook.sh\" --loop 600" \
  "$(agent_settings | jq -r '.hooks.Stop[0].hooks[0] | "\(.command) \(.timeout)"')"

# --- verify-hook.sh ---
hook() { (cd "$T/proj" && CLAUDE_PROJECT_DIR="$T/proj" "$B" "$ROOT/libexec/verify-hook.sh" "$@" 2>/dev/null); }
echo x >"$T/proj/new.txt"
echo '{}' | AGENT_VERIFY_CMD=false hook --loop; check "verify-hook: failing checks block stopping (exit 2)" 2 $?
echo '{}' | AGENT_VERIFY_CMD=true hook --loop; check "verify-hook: passing checks let it stop" 0 $?
echo '{"stop_hook_active": true}' | AGENT_VERIFY_CMD=false hook --loop; check "verify-hook: second stop is allowed" 0 $?
echo '{}' | AGENT_LOOP_RUN=1 AGENT_VERIFY_CMD=false hook; check "verify-hook: project copy steps aside in loop runs" 0 $?
printf "AGENT_VERIFY_CMD=false\n" >"$T/proj/.agent-loop.conf"
echo '{}' | env -u AGENT_VERIFY_CMD "$B" -c 'cd "$1" && CLAUDE_PROJECT_DIR="$1" "$2" "$3/libexec/verify-hook.sh"' _ "$T/proj" "$B" "$ROOT" 2>/dev/null
check "verify-hook: project copy reads .agent-loop.conf" 2 $?
rm -f "$T/proj/new.txt" "$T/proj/.agent-loop.conf"
echo '{}' | AGENT_VERIFY_CMD=false hook --loop; check "verify-hook: nothing changed, nothing to verify" 0 $?

# --- CLI ---
check "cli: version" "$(cat "$ROOT/VERSION")" "$("$ROOT/bin/agent-loop" version)"
"$ROOT/bin/agent-loop" nope >/dev/null 2>&1; check "cli: unknown command exits 2" 2 $?

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
