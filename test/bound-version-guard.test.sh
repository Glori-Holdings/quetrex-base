#!/usr/bin/env bash
# bound-version-guard.test.sh — proves G1 (HOOKFIX, .quetrex/plan/HOOKFIX.json):
# a session bound to a STALE plugin cache is surfaced to the operator, once,
# non-blocking, with a remedy — and the guard never wedges a session, never
# executes anything it discovers, and never double-prints when registered in
# TWO plugin roots (HOOKFIX correction 1).
#
# EVERY ASSERTION DRIVES THE SHIPPED SCRIPT
# .claude/hooks/quetrex-bound-version-guard.sh end to end via its real
# SessionStart stdin payload, against a synthetic plugin-cache tree this file
# builds itself (real .claude-plugin/plugin.json files, a real
# installed_plugins.json fixture), with CLAUDE_PLUGIN_ROOT and PATH set to
# that tree — the only test seams the plan allows (plus
# QX_BOUND_INSTALLED_PLUGINS_FILE for the installed map and
# QX_BOUND_GUARD_STATE_DIR, a hygiene knob for the session-dedup marker so
# parallel test runs never collide).
#
# AC8:  a stale factory bind is reported, once, naming both versions + restart.
# AC9:  everything up to date -> completely silent.
# AC10: three degraded environments -> silent and non-blocking, never a stack
#       trace.
# CORRECTION 1 (2026-08-21): the guard can now run TWICE in one session (both
# plugin roots register it) — a second invocation for the SAME session_id
# must stay silent; a DIFFERENT session_id must still evaluate for real.
# AC11 (fail-first): the script does not exist on the pre-change baseline, and
# the pre-change mechanism (quetrex-update-check.sh) cannot see this class of
# staleness at all.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="${QX_BOUND_VERSION_GUARD_HOOK:-$ROOT/.claude/hooks/quetrex-bound-version-guard.sh}"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); echo "ok - $1"; }
notok() { FAIL=$((FAIL+1)); echo "NOT OK - $1"; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; echo; echo "bound-version-guard.test.sh: $PASS passed, $FAIL failed"; exit 0; }

if [ ! -f "$GUARD" ]; then
  echo "NOT OK - quetrex-bound-version-guard.sh not found at $GUARD"
  echo
  echo "bound-version-guard.test.sh: 0 passed, 1 failed"
  exit 1
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

mkplugin() {  # mkplugin <root> <name> <version>
  mkdir -p "$1/.claude-plugin"
  jq -cn --arg n "$2" --arg v "$3" '{name:$n,version:$v}' > "$1/.claude-plugin/plugin.json"
}
mkinstalled() {  # mkinstalled <file> <name@marketplace=version> ...
  # Builds the `.plugins["<name>@<marketplace>"] = [{version,installPath}]`
  # shape by folding each pair into an accumulator object with jq (rather
  # than string-concatenating raw JSON), so every key/value is properly
  # jq-escaped regardless of what test literal is passed.
  local f="$1"; shift
  local acc='{"plugins":{}}' pair name ver
  for pair in "$@"; do
    name="${pair%%=*}"; ver="${pair#*=}"
    acc="$(jq -cn --argjson acc "$acc" --arg n "$name" --arg v "$ver" \
      '$acc | .plugins[$n] = [{version:$v,installPath:"x"}]')"
  done
  printf '%s' "$acc" > "$f"
}
fire() {  # fire <session_id> [extra env assignments...] -> stdout
  local sid="$1"; shift
  jq -cn --arg s "$sid" '{hook_event_name:"SessionStart",session_id:$s}' \
    | env "$@" bash "$GUARD" 2>"$TMP/stderr.$$"
}

STATE_DIR="$TMP/state"

# =============================================================================
# AC8 — a stale factory bind is reported once, naming both versions + restart,
# and does NOT name the current (non-stale) plugin.
# =============================================================================
QROOT8="$TMP/cache/quetrex/quetrex/2.5.3"
FROOT8="$TMP/cache/quetrex/quetrex-factory/1.7.1"
mkdir -p "$FROOT8/bin"
mkplugin "$QROOT8" quetrex 2.5.3
mkplugin "$FROOT8" quetrex-factory 1.7.1
mkinstalled "$TMP/installed8.json" "quetrex@quetrex=2.5.3" "quetrex-factory@quetrex=1.7.2"

OUT8="$(fire sess-ac8 \
  CLAUDE_PLUGIN_ROOT="$QROOT8" \
  PATH="$FROOT8/bin:/usr/bin:/bin" \
  QX_BOUND_INSTALLED_PLUGINS_FILE="$TMP/installed8.json" \
  QX_BOUND_GUARD_STATE_DIR="$STATE_DIR")"
CODE8=$?
LINES8=$(printf '%s\n' "$OUT8" | grep -c .)

[ "$CODE8" -eq 0 ] && ok "AC8: exit 0" || notok "AC8: expected exit 0, got $CODE8"
[ "$LINES8" -eq 1 ] && ok "AC8: exactly 1 stdout line" || notok "AC8: expected exactly 1 stdout line, got $LINES8 (out: [$OUT8])"
printf '%s' "$OUT8" | grep -q 'quetrex-factory' && ok "AC8: names quetrex-factory" || notok "AC8: does not name quetrex-factory [$OUT8]"
printf '%s' "$OUT8" | grep -q '1\.7\.1' && ok "AC8: names the bound version 1.7.1" || notok "AC8: does not name 1.7.1 [$OUT8]"
printf '%s' "$OUT8" | grep -q '1\.7\.2' && ok "AC8: names the installed version 1.7.2" || notok "AC8: does not name 1.7.2 [$OUT8]"
printf '%s' "$OUT8" | grep -qi 'restart' && ok "AC8: mentions restart (case-insensitive)" || notok "AC8: does not mention restart [$OUT8]"
printf '%s' "$OUT8" | grep -q 'quetrex 2\.5\.3' && notok "AC8: incorrectly names the non-stale quetrex 2.5.3 [$OUT8]" \
  || ok "AC8: does not name the non-stale 'quetrex 2.5.3'"

# --- CORRECTION 1: a SECOND invocation, SAME session_id -> fully silent -----
OUT8B="$(fire sess-ac8 \
  CLAUDE_PLUGIN_ROOT="$QROOT8" \
  PATH="$FROOT8/bin:/usr/bin:/bin" \
  QX_BOUND_INSTALLED_PLUGINS_FILE="$TMP/installed8.json" \
  QX_BOUND_GUARD_STATE_DIR="$STATE_DIR")"
CODE8B=$?
[ "$CODE8B" -eq 0 ] && [ -z "$OUT8B" ] \
  && ok "CORRECTION 1: a second invocation for the SAME session_id (simulating dual plugin-root registration) is fully silent — no double-print" \
  || notok "CORRECTION 1: second invocation for the same session_id printed again (out: [$OUT8B]) — dual registration would double-print"

# --- a DIFFERENT session_id still evaluates for real ------------------------
OUT8C="$(fire sess-ac8-other \
  CLAUDE_PLUGIN_ROOT="$QROOT8" \
  PATH="$FROOT8/bin:/usr/bin:/bin" \
  QX_BOUND_INSTALLED_PLUGINS_FILE="$TMP/installed8.json" \
  QX_BOUND_GUARD_STATE_DIR="$STATE_DIR")"
LINES8C=$(printf '%s\n' "$OUT8C" | grep -c .)
[ "$LINES8C" -eq 1 ] \
  && ok "CORRECTION 1: a DIFFERENT session_id still evaluates and prints for real — dedup is per-session, not global" \
  || notok "CORRECTION 1: a different session_id did not print (out: [$OUT8C]) — dedup is incorrectly global"

# =============================================================================
# AC9 — everything up to date -> completely silent.
# =============================================================================
mkinstalled "$TMP/installed9.json" "quetrex@quetrex=2.5.3" "quetrex-factory@quetrex=1.7.1"
OUT9="$(fire sess-ac9 \
  CLAUDE_PLUGIN_ROOT="$QROOT8" \
  PATH="$FROOT8/bin:/usr/bin:/bin" \
  QX_BOUND_INSTALLED_PLUGINS_FILE="$TMP/installed9.json" \
  QX_BOUND_GUARD_STATE_DIR="$STATE_DIR")"
CODE9=$?
BYTES9=$(printf '%s' "$OUT9" | wc -c | tr -d ' ')
STDERR9_BYTES=$(wc -c < "$TMP/stderr.$$" 2>/dev/null | tr -d ' '); STDERR9_BYTES=${STDERR9_BYTES:-0}
[ "$CODE9" -eq 0 ] && ok "AC9: exit 0" || notok "AC9: expected exit 0, got $CODE9"
[ "$BYTES9" -eq 0 ] && ok "AC9: 0 bytes on stdout" || notok "AC9: expected 0 stdout bytes, got $BYTES9 (out: [$OUT9])"
[ "$STDERR9_BYTES" -eq 0 ] && ok "AC9: 0 bytes on stderr" || notok "AC9: expected 0 stderr bytes, got $STDERR9_BYTES"

# =============================================================================
# AC10 — three degraded environments: silent and non-blocking in all three.
# =============================================================================
DEGRADED_OK=0

# (a) installed_plugins.json absent
OUTA="$(fire sess-ac10a \
  CLAUDE_PLUGIN_ROOT="$QROOT8" \
  PATH="$FROOT8/bin:/usr/bin:/bin" \
  QX_BOUND_INSTALLED_PLUGINS_FILE="$TMP/does-not-exist.json" \
  QX_BOUND_GUARD_STATE_DIR="$STATE_DIR")"
CODEA=$?
BYTESA=$(printf '%s' "$OUTA" | wc -c | tr -d ' ')
STDERRA=$(cat "$TMP/stderr.$$" 2>/dev/null)
[ "$CODEA" -eq 0 ] && [ "$BYTESA" -eq 0 ] && DEGRADED_OK=$((DEGRADED_OK+1)) \
  || echo "# AC10(a) failed: code=$CODEA bytes=$BYTESA"
printf '%s' "$STDERRA" | grep -Eq 'Traceback|SyntaxError|line [0-9]+:' \
  && notok "AC10(a): stderr looks like an interpreter error [$STDERRA]" \
  || ok "AC10(a): installed_plugins.json absent — no interpreter-error shape on stderr"

# (b) installed_plugins.json malformed
echo "not json" > "$TMP/bad.json"
OUTB="$(fire sess-ac10b \
  CLAUDE_PLUGIN_ROOT="$QROOT8" \
  PATH="$FROOT8/bin:/usr/bin:/bin" \
  QX_BOUND_INSTALLED_PLUGINS_FILE="$TMP/bad.json" \
  QX_BOUND_GUARD_STATE_DIR="$STATE_DIR")"
CODEB=$?
BYTESB=$(printf '%s' "$OUTB" | wc -c | tr -d ' ')
STDERRB=$(cat "$TMP/stderr.$$" 2>/dev/null)
[ "$CODEB" -eq 0 ] && [ "$BYTESB" -eq 0 ] && DEGRADED_OK=$((DEGRADED_OK+1)) \
  || echo "# AC10(b) failed: code=$CODEB bytes=$BYTESB"
printf '%s' "$STDERRB" | grep -Eq 'Traceback|SyntaxError|line [0-9]+:' \
  && notok "AC10(b): stderr looks like an interpreter error [$STDERRB]" \
  || ok "AC10(b): installed_plugins.json malformed — no interpreter-error shape on stderr"

# (c) PATH=/usr/bin only, CLAUDE_PLUGIN_ROOT unset
OUTC="$(printf '%s' "$(jq -cn --arg s sess-ac10c '{hook_event_name:"SessionStart",session_id:$s}')" \
  | env -u CLAUDE_PLUGIN_ROOT PATH="/usr/bin:/bin" \
      QX_BOUND_INSTALLED_PLUGINS_FILE="$TMP/installed8.json" \
      QX_BOUND_GUARD_STATE_DIR="$STATE_DIR" \
      bash "$GUARD" 2>"$TMP/stderr.$$")"
CODEC=$?
BYTESC=$(printf '%s' "$OUTC" | wc -c | tr -d ' ')
STDERRC=$(cat "$TMP/stderr.$$" 2>/dev/null)
[ "$CODEC" -eq 0 ] && [ "$BYTESC" -eq 0 ] && DEGRADED_OK=$((DEGRADED_OK+1)) \
  || echo "# AC10(c) failed: code=$CODEC bytes=$BYTESC"
printf '%s' "$STDERRC" | grep -Eq 'Traceback|SyntaxError|line [0-9]+:' \
  && notok "AC10(c): stderr looks like an interpreter error [$STDERRC]" \
  || ok "AC10(c): PATH=/usr/bin only, CLAUDE_PLUGIN_ROOT unset — no interpreter-error shape on stderr"

[ "$DEGRADED_OK" -eq 3 ] \
  && ok "AC10: 3 of 3 degraded invocations exit 0 with 0 stdout bytes" \
  || notok "AC10: only $DEGRADED_OK of 3 degraded invocations were exit-0/silent"

# =============================================================================
# AC11 — FAIL-FIRST: the guard does not exist on the pre-change baseline, and
# the pre-change mechanism (quetrex-update-check.sh) cannot see this class of
# staleness — proven by driving IT against the same AC8 fixture.
# =============================================================================
BASELINE_MISSING=0
if git -C "$ROOT" show origin/main:.claude/hooks/quetrex-bound-version-guard.sh >/dev/null 2>&1; then
  notok "AC11 FAIL-FIRST: quetrex-bound-version-guard.sh unexpectedly EXISTS at origin/main — it should be new in this branch"
elif git -C "$ROOT" show main:.claude/hooks/quetrex-bound-version-guard.sh >/dev/null 2>&1; then
  notok "AC11 FAIL-FIRST: quetrex-bound-version-guard.sh unexpectedly EXISTS at main — it should be new in this branch"
else
  BASELINE_MISSING=1
  ok "AC11 FAIL-FIRST: quetrex-bound-version-guard.sh does not exist at origin/main or main — this is new machinery, not a modification"
fi

OLD_CHECK="$ROOT/.claude/hooks/quetrex-update-check.sh"
if [ -f "$OLD_CHECK" ]; then
  OUT_OLD="$(jq -cn --arg s sess-ac8-baseline '{hook_event_name:"SessionStart",session_id:$s}' \
    | env CLAUDE_PLUGIN_ROOT="$QROOT8" PATH="$FROOT8/bin:/usr/bin:/bin" \
        QX_UPDATE_OFFLINE=1 \
        bash "$OLD_CHECK" 2>/dev/null)"
  LINES_OLD=$(printf '%s\n' "$OUT_OLD" | grep -c .)
  [ "$LINES_OLD" -eq 0 ] \
    && ok "AC11 FAIL-FIRST: the pre-change mechanism (quetrex-update-check.sh) prints 0 lines for the AC8 stale-bind fixture — it answers a different question (installed vs marketplace-latest) and cannot see PATH-bound staleness at all" \
    || notok "AC11 FAIL-FIRST: quetrex-update-check.sh unexpectedly printed something for the AC8 fixture ($LINES_OLD line(s): [$OUT_OLD]) — cannot demonstrate the gap this guard closes"
else
  echo "SKIP: quetrex-update-check.sh not found — cannot demonstrate the pre-change mechanism's blind spot"
fi

[ "$BASELINE_MISSING" -eq 1 ] || true

echo
echo "bound-version-guard.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
