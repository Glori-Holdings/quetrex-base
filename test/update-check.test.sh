#!/usr/bin/env bash
# test/update-check.test.sh — behavioural test for the SessionStart update-check
# hook (.claude/hooks/quetrex-update-check.sh).
#
# Run: bash test/update-check.test.sh
#
# The hook is NON-BLOCKING (informational), so there is no deny/allow to prove.
# Its contract instead is print-vs-silent, and THAT is what this test pins:
#   1. BEHIND (quetrex)        -> prints a one-line "run /quetrex:update" nudge.
#   2. BEHIND (factory pin)    -> prints, naming quetrex-factory.
#   3. CURRENT                 -> prints NOTHING (silent when up-to-date).
#   4. OFFLINE, no cache       -> prints NOTHING and exits 0 (offline-safe).
#   5. OFFLINE, fresh cache    -> still reports from cache (no network needed).
#   6. ALWAYS exits 0          -> a SessionStart hook must never wedge a session.
#
# The hook's decision is driven entirely by env overrides (QX_UPDATE_*), so the
# whole test runs offline against a fixture marketplace file — no network, no
# real plugin install.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO_ROOT/.claude/hooks/quetrex-update-check.sh"

if [ ! -f "$HOOK" ]; then
  echo "FAIL: hook not found at $HOOK"
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not installed — the hook parses JSON with node"
  exit 0
fi

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qx-update-check.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# A fixture marketplace manifest: quetrex latest 2.4.0, factory latest 1.5.0.
MARKET="$WORK/marketplace.json"
cat > "$MARKET" <<'JSON'
{
  "name": "quetrex",
  "plugins": [
    { "name": "quetrex", "version": "2.4.0" },
    { "name": "quetrex-factory", "version": "1.5.0" }
  ]
}
JSON

# run_hook <cache-subdir> — invokes the hook with a private cache dir and the
# fixture marketplace file, capturing stdout. Extra env is taken from the
# caller's environment (INSTALLED/OFFLINE/etc. set inline before the call).
run_hook() {
  local cachedir="$WORK/$1"; shift
  CLAUDE_PLUGIN_DATA="$cachedir" \
  QX_UPDATE_MARKETPLACE_FILE="$MARKET" \
  QX_UPDATE_TTL_SECONDS="${QX_UPDATE_TTL_SECONDS:-86400}" \
    bash "$HOOK" </dev/null
}

# --- 1. behind on quetrex -> prints and mentions /quetrex:update -------------
OUT="$(QX_UPDATE_INSTALLED_QUETREX=2.0.0 QX_UPDATE_INSTALLED_FACTORY=1.5.0 run_hook c1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '/quetrex:update' \
   && printf '%s' "$OUT" | grep -q '2.4.0'; then
  pass "behind on quetrex prints an update nudge"
else
  fail "behind on quetrex should print a /quetrex:update nudge (got: '$OUT', rc=$RC)"
fi

# --- 1b. behind on the REAL 2.0.0 -> 2.0.1 engine bump -----------------------
# Proves the update-notification engine fires on the actual version bump this
# workstream ships (plugin.json 2.0.0 -> 2.0.1 / marketplace.json quetrex
# 2.0.1), against a fixture marketplace declaring 2.0.1 as latest.
REAL_MARKET="$WORK/real-bump-marketplace.json"
cat > "$REAL_MARKET" <<'JSON'
{
  "name": "quetrex",
  "plugins": [
    { "name": "quetrex", "version": "2.0.1" },
    { "name": "quetrex-factory", "version": "1.5.0" }
  ]
}
JSON
OUT="$(CLAUDE_PLUGIN_DATA="$WORK/c1b" QX_UPDATE_MARKETPLACE_FILE="$REAL_MARKET" \
       QX_UPDATE_TTL_SECONDS="${QX_UPDATE_TTL_SECONDS:-86400}" \
       QX_UPDATE_INSTALLED_QUETREX=2.0.0 QX_UPDATE_INSTALLED_FACTORY=1.5.0 \
       bash "$HOOK" </dev/null)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '/quetrex:update' \
   && printf '%s' "$OUT" | grep -q '2.0.1'; then
  pass "the 2.0.0 -> 2.0.1 engine bump fires a /quetrex:update nudge naming 2.0.1"
else
  fail "installed 2.0.0 against a 2.0.1 fixture should print a /quetrex:update nudge naming 2.0.1 (got: '$OUT', rc=$RC)"
fi

# --- 2. behind on the factory pin -> prints, naming quetrex-factory ----------
OUT="$(QX_UPDATE_INSTALLED_QUETREX=2.4.0 QX_UPDATE_INSTALLED_FACTORY=1.0.0 run_hook c2)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'quetrex-factory' \
   && printf '%s' "$OUT" | grep -q '1.5.0'; then
  pass "behind on the factory pin prints, naming quetrex-factory"
else
  fail "behind on factory should name quetrex-factory (got: '$OUT', rc=$RC)"
fi

# --- 3. current on both -> SILENT --------------------------------------------
OUT="$(QX_UPDATE_INSTALLED_QUETREX=2.4.0 QX_UPDATE_INSTALLED_FACTORY=1.5.0 run_hook c3)"; RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  pass "current on both versions is silent"
else
  fail "up-to-date should print nothing (got: '$OUT', rc=$RC)"
fi

# --- 4. offline with no cache -> SILENT, exit 0 ------------------------------
# No marketplace file, offline forced, empty cache dir => nothing to compare.
OUT="$(CLAUDE_PLUGIN_DATA="$WORK/c4" QX_UPDATE_MARKETPLACE_FILE="" QX_UPDATE_OFFLINE=1 \
       QX_UPDATE_INSTALLED_QUETREX=2.0.0 QX_UPDATE_INSTALLED_FACTORY=1.0.0 \
       bash "$HOOK" </dev/null)"; RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  pass "offline with no cache is silent and exits 0"
else
  fail "offline/no-cache must be silent, exit 0 (got: '$OUT', rc=$RC)"
fi

# --- 5. offline but a fresh cache exists -> reports from cache ---------------
# Prime a cache by a normal (fixture-file) run, then force offline and confirm
# it still reports without any marketplace source.
CACHE5="$WORK/c5"
QX_UPDATE_INSTALLED_QUETREX=2.4.0 QX_UPDATE_INSTALLED_FACTORY=1.5.0 run_hook c5 >/dev/null 2>&1
if [ ! -f "$CACHE5/update-check.cache" ]; then
  fail "expected a primed cache file under $CACHE5"
else
  OUT="$(CLAUDE_PLUGIN_DATA="$CACHE5" QX_UPDATE_MARKETPLACE_FILE="" QX_UPDATE_OFFLINE=1 \
         QX_UPDATE_INSTALLED_QUETREX=2.0.0 QX_UPDATE_INSTALLED_FACTORY=1.5.0 \
         bash "$HOOK" </dev/null)"; RC=$?
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '2.4.0'; then
    pass "offline with a fresh cache still reports from cache"
  else
    fail "offline+fresh-cache should report from cache (got: '$OUT', rc=$RC)"
  fi
fi

# --- 6. nothing to compare (no installed versions) -> silent, exit 0 --------
OUT="$(CLAUDE_PLUGIN_DATA="$WORK/c6" QX_UPDATE_MARKETPLACE_FILE="$MARKET" \
       QX_UPDATE_INSTALLED_QUETREX="" QX_UPDATE_INSTALLED_FACTORY="" \
       bash "$HOOK" </dev/null)"; RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  pass "no installed versions to compare is silent, exit 0"
else
  fail "no-installed-versions must be silent, exit 0 (got: '$OUT', rc=$RC)"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "update-check.test.sh: all checks passed"
  exit 0
else
  echo "update-check.test.sh: FAILURES above"
  exit 1
fi
