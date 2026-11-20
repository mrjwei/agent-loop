#!/usr/bin/env bash
# Check that plan files are in the form triage relies on: every item (a "### P1-03 Title" heading) is about one PR and has a
# Size (S, M or L), a Risk (low or high), an Owner (agent or human), at least one Acceptance line, a unique id, and
# "Depends on" ids that some plan defines. Plain bash and awk: no model call, no GitHub, usable in CI. Exit 1 on any error.
# Usage: agent-loop plan-lint [files...]      (default: the files of AGENT_PLANS_GLOB)
# A plan with `status: template` (docs/plans/TEMPLATE.md) is skipped, so the template's example ids cannot clash with yours.
# Messages are "file:line: message". Ids are defined by every plan in AGENT_PLANS_GLOB plus the files named on the command line.
set -euo pipefail
. "$(dirname "$0")/../lib/common.sh"

abs_path() { # file -> its absolute, symlink-free path (so one file is never counted under two names)
  local d; d=$(cd "$(dirname "$1")" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$d" "$(basename "$1")"
}
is_template() { grep -Eq '^status:[[:space:]]*template[[:space:]]*$' "$1"; }

targets=()
for a in "$@"; do
  case "$a" in
    -h | --help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown argument: $a" ;;
    *) [ -f "$a" ] || { echo "plan-lint: no such file: $a" >&2; exit 2; }
       targets+=("$(abs_path "$a")") ;;
  esac
done

# Every plan of AGENT_PLANS_GLOB (the glob is relative to the project root), as absolute paths
glob_files() {
  local f
  [ -n "$AGENT_PLANS_GLOB" ] || return 0
  # shellcheck disable=SC2086  # the glob is meant to expand
  (cd "$REPO" && for f in $AGENT_PLANS_GLOB; do [ -f "$f" ] && abs_path "$f"; done) || true
}

if [ ${#targets[@]} -eq 0 ]; then
  while IFS= read -r f; do targets+=("$f"); done < <(glob_files)
  [ ${#targets[@]} -gt 0 ] || die "no plan files: name them, or set AGENT_PLANS_GLOB in .agent-loop.conf (e.g. 'docs/plans/*.md')"
fi

# All plans (the ids that exist) and the ones to check; a template is left out of both
all=$({ glob_files; printf '%s\n' "${targets[@]}"; } | sort -u | while IFS= read -r f; do is_template "$f" || echo "$f"; done)
check=$(printf '%s\n' "${targets[@]}" | sort -u | while IFS= read -r f; do is_template "$f" || echo "$f"; done)
[ -n "$check" ] || { echo "plan-lint: nothing to check (only templates)"; exit 0; }

# shellcheck disable=SC2016  # awk program
prog='
function id_ok(s) { return s ~ /^[A-Za-z][A-Za-z0-9]*-[0-9]+$/ }
function shown(f) { sub("^" root "/", "", f); return f }
function err(line, msg) { print shown(file) ":" line ": " msg; nerr++ }
# the value after "Key:", up to a space, "·", "|", "," or ";"
function val(line, key,   s) {
  if (match(line, "(^|[^A-Za-z])" key "[ \t]*:[ \t]*[^ \t·|,;]+")) {
    s = substr(line, RSTART, RLENGTH); sub(/^[^:]*:[ \t]*/, "", s); return s
  }
  return ""
}
function flush(   v) {
  if (!inItem) return
  if (size == "") err(start, "item " id " has no Size (S, M or L)")
  else if (toupper(size) !~ /^[SML]$/) err(start, "item " id ": Size must be S, M or L (got \"" size "\")")
  if (risk == "") err(start, "item " id " has no Risk (low or high)")
  else if (tolower(risk) !~ /^(low|high)$/) err(start, "item " id ": Risk must be low or high (got \"" risk "\")")
  if (owner == "") err(start, "item " id " has no Owner (agent or human)")
  else if (tolower(owner) !~ /^(agent|human)$/) err(start, "item " id ": Owner must be agent or human (got \"" owner "\")")
  if (acc == 0) err(start, "item " id " has no Acceptance line (an \"Acceptance:\" line followed by at least one criterion)")
  inItem = 0
}
function newfile() { flush(); infence = 0; accBlock = 0; prevfile = FILENAME; file = FILENAME }
FNR == 1 { newfile() }
/^[ \t]*(```|~~~)/ { infence = !infence; next }
infence { next }
# an item starts at a "### ID title" heading; any other heading of level 1-3 ends the item
/^#(#)?(#)?[ \t]/ {
  if (pass == 2) flush()
  inItem = 0
  if ($0 ~ /^###[ \t]+[^ \t]+/ && id_ok($2)) {
    if (pass == 1) {
      if ($2 in def) dup[FILENAME SUBSEP FNR] = def[$2]
      else def[$2] = shown(FILENAME) ":" FNR
    } else {
      id = $2; start = FNR; inItem = 1; size = risk = owner = ""; acc = 0; accBlock = 0; items++
      if ((FILENAME SUBSEP FNR) in dup) err(FNR, "duplicate item id " id " (first defined at " dup[FILENAME SUBSEP FNR] ")")
    }
  }
  next
}
pass == 2 && inItem {
  if ($0 ~ /^[-*][ \t]+/) {
    accBlock = 0
    if (val($0, "Size") != "") size = val($0, "Size")
    if (val($0, "Risk") != "") risk = val($0, "Risk")
    if (val($0, "Owner") != "") owner = val($0, "Owner")
    if ($0 ~ /^[-*][ \t]+Depends on[ \t]*:/) {
      rest = $0; sub(/^[-*][ \t]+Depends on[ \t]*:/, "", rest)
      n = split(rest, tok, /[^A-Za-z0-9-]+/)
      for (i = 1; i <= n; i++) if (id_ok(tok[i]) && !(tok[i] in def)) err(FNR, "item " id " depends on " tok[i] ", which no plan defines")
    }
    if ($0 ~ /^[-*][ \t]+Acceptance[ \t]*:/) {
      accBlock = 1; rest = $0; sub(/^[-*][ \t]+Acceptance[ \t]*:[ \t]*/, "", rest)
      if (rest ~ /[^ \t]/) acc++
    }
  } else if (accBlock && $0 ~ /^[ \t]+[-*][ \t]+[^ \t]/) acc++
}
END { if (pass == 2) flush(); print "@" items + 0 " " nerr + 0 }
'
# Pass 1 reads every plan (ids), pass 2 the ones to check. Command-line "pass=N" assignments take effect between the files.
all_files=(); while IFS= read -r f; do all_files+=("$f"); done <<<"$all"
check_files=(); while IFS= read -r f; do check_files+=("$f"); done <<<"$check"
out=$(awk -v root="$(cd "$REPO" && pwd -P)" "$prog" pass=1 "${all_files[@]}" pass=2 "${check_files[@]}" | LC_ALL=C sort -t: -k1,1 -k2,2n -s)
summary=$(printf '%s\n' "$out" | grep '^@' | tail -1 || true)
printf '%s\n' "$out" | grep -v '^@' || true
n=${summary#@}; items=${n% *}; errors=${n#* }
if [ "${errors:-0}" -gt 0 ]; then
  echo "plan-lint: $errors error(s) in $items item(s)" >&2
  exit 1
fi
echo "plan-lint: $items item(s) in $(printf '%s\n' "$check" | grep -c .) file(s): ok"
