#!/usr/bin/env bash
# test/update-check.test.sh — behavioural test for the SessionStart update-check
# hook, now shipped inside quetrex-setup
# (plugins/quetrex-setup/scripts/quetrex-update-check.sh).
#
# Run: bash test/update-check.test.sh
#
# The hook is NON-BLOCKING (informational), so there is no deny/allow to prove.
# Its contract instead is print-vs-silent, and THAT is what this test pins,
# across the THREE components the hook now resolves independently
# (quetrex-setup's own manifest; `quetrex` and `quetrex-factory` from
# installed_plugins.json — see AC13):
#   1. BEHIND (quetrex-setup)  -> prints a one-line "/quetrex-setup:update" nudge
#                                  naming quetrex-setup.
#   2. BEHIND (quetrex)        -> prints, naming Quetrex.
#   3. BEHIND (factory)        -> prints, naming quetrex-factory.
#   4. ALL CURRENT             -> prints an explicit "latest" confirmation
#                                  naming all three components.
#   5. UNRESOLVABLE component  -> a component with no installed version to
#                                  compare (no override, no installed_plugins
#                                  file) is OMITTED from the confirmation —
#                                  never vouched for.
#   6. OFFLINE, no cache       -> prints NOTHING and exits 0 (offline-safe).
#
# The hook's decision is driven entirely by env overrides (QX_UPDATE_*), so the
# whole test runs offline against a fixture marketplace file — no network, no
# real plugin install.

set -uo pipefail

# ONE-COPY round 2 hygiene (reviewer-reported): this session's ambient
# environment can carry QUETREX_UNLOCK_FLOOR=1 from unrelated prior work in
# the SAME shell (it is not cleared between unrelated commands), and every
# floor script honors it as the intentional operator unlock. A test that
# asserts a floor DENY without isolating this var silently asserts nothing
# once that happens - unset it here so this file's own "locked" assertions
# are never contaminated by ambient state; any assertion that WANTS the
# unlocked case still sets QUETREX_UNLOCK_FLOOR=1 explicitly on that one
# invocation, which overrides this.
unset QUETREX_UNLOCK_FLOOR

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO_ROOT/plugins/quetrex-setup/scripts/quetrex-update-check.sh"

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

# A fixture marketplace manifest: quetrex-setup latest 1.1.0, quetrex latest
# 2.6.0, quetrex-factory latest 1.8.0.
MARKET="$WORK/marketplace.json"
cat > "$MARKET" <<'JSON'
{
  "name": "quetrex",
  "plugins": [
    { "name": "quetrex-setup", "version": "1.1.0" },
    { "name": "quetrex", "version": "2.6.0" },
    { "name": "quetrex-factory", "version": "1.8.0" }
  ]
}
JSON

# When QX_UPDATE_INSTALLED_* is empty the hook falls back to DISCOVERING the
# versions from the ambient session: quetrex-setup's own version from
# ${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json, and `quetrex`/
# `quetrex-factory` from installed_plugins.json. Claude Code exports
# CLAUDE_PLUGIN_ROOT to hooks, so a suite run from a Stop/SessionStart hook
# would read the REAL repo's manifest and see a version the test never set.
# Strip the discovery inputs (and point installed_plugins.json at a file that
# does not exist) for every hook invocation so the test is driven purely by
# QX_UPDATE_*, exactly as this file's header claims.
hook_env() { env -u CLAUDE_PROJECT_DIR -u CLAUDE_PLUGIN_ROOT "$@"; }
NO_INSTALLED_PLUGINS_FILE="$WORK/no-such-installed_plugins.json"

# run_hook <cache-subdir> — invokes the hook with a private cache dir and the
# fixture marketplace file, capturing stdout. Extra env is taken from the
# caller's environment (INSTALLED_*/OFFLINE/etc. set inline before the call).
run_hook() {
  local cachedir="$WORK/$1"; shift
  CLAUDE_PLUGIN_DATA="$cachedir" \
  QX_UPDATE_MARKETPLACE_FILE="$MARKET" \
  QX_UPDATE_TTL_SECONDS="${QX_UPDATE_TTL_SECONDS:-86400}" \
  QX_UPDATE_INSTALLED_PLUGINS_FILE="${QX_UPDATE_INSTALLED_PLUGINS_FILE:-$NO_INSTALLED_PLUGINS_FILE}" \
    hook_env bash "$HOOK" </dev/null
}

# --- 1. behind on quetrex-setup -> prints and names quetrex-setup -----------
OUT="$(QX_UPDATE_INSTALLED_SETUP=1.0.0 QX_UPDATE_INSTALLED_QUETREX=2.6.0 QX_UPDATE_INSTALLED_FACTORY=1.8.0 run_hook c1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '/quetrex-setup:update' \
   && printf '%s' "$OUT" | grep -q 'quetrex-setup' && printf '%s' "$OUT" | grep -q '1.1.0'; then
  pass "behind on quetrex-setup prints an update nudge naming quetrex-setup"
else
  fail "behind on quetrex-setup should print a /quetrex-setup:update nudge naming quetrex-setup 1.1.0 (got: '$OUT', rc=$RC)"
fi

# --- 2. behind on quetrex -> prints, naming Quetrex --------------------------
OUT="$(QX_UPDATE_INSTALLED_SETUP=1.1.0 QX_UPDATE_INSTALLED_QUETREX=2.5.0 QX_UPDATE_INSTALLED_FACTORY=1.8.0 run_hook c2)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '/quetrex-setup:update' \
   && printf '%s' "$OUT" | grep -q 'Quetrex' && printf '%s' "$OUT" | grep -q '2.6.0'; then
  pass "behind on quetrex prints an update nudge naming Quetrex"
else
  fail "behind on quetrex should name Quetrex 2.6.0 (got: '$OUT', rc=$RC)"
fi

# --- 3. behind on the factory pin -> prints, naming quetrex-factory ----------
OUT="$(QX_UPDATE_INSTALLED_SETUP=1.1.0 QX_UPDATE_INSTALLED_QUETREX=2.6.0 QX_UPDATE_INSTALLED_FACTORY=1.0.0 run_hook c3)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'quetrex-factory' \
   && printf '%s' "$OUT" | grep -q '1.8.0'; then
  pass "behind on the factory pin prints, naming quetrex-factory"
else
  fail "behind on factory should name quetrex-factory (got: '$OUT', rc=$RC)"
fi

# --- 4. current on all three -> CONFIRMS explicitly, naming all three -------
# Silence used to mean both "you are current" and "I could not check". Those are
# not the same claim and must not look the same, so being current now says so.
OUT="$(QX_UPDATE_INSTALLED_SETUP=1.1.0 QX_UPDATE_INSTALLED_QUETREX=2.6.0 QX_UPDATE_INSTALLED_FACTORY=1.8.0 run_hook c4)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'latest' \
   && printf '%s' "$OUT" | grep -q 'quetrex-setup' \
   && printf '%s' "$OUT" | grep -q 'Quetrex' \
   && printf '%s' "$OUT" | grep -q '1.1.0' && printf '%s' "$OUT" | grep -q '2.6.0' && printf '%s' "$OUT" | grep -q '1.8.0'; then
  pass "up-to-date states it explicitly, naming all three components"
else
  fail "up-to-date must confirm 'latest' and name all three components (got: '$OUT', rc=$RC)"
fi

# --- 5. an unresolvable component is OMITTED, never vouched for -------------
# quetrex-factory has no override and no installed_plugins.json to read, so it
# cannot be resolved; the up-to-date line must name quetrex-setup and Quetrex
# but say nothing about the factory engine.
OUT="$(QX_UPDATE_INSTALLED_SETUP=1.1.0 QX_UPDATE_INSTALLED_QUETREX=2.6.0 QX_UPDATE_INSTALLED_FACTORY="" run_hook c5)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'quetrex-setup' \
   && printf '%s' "$OUT" | grep -q 'Quetrex' && ! printf '%s' "$OUT" | grep -q 'engine'; then
  pass "an unresolvable component (factory) is omitted, never vouched for"
else
  fail "unresolvable factory must be omitted from the confirmation, never claimed (got: '$OUT', rc=$RC)"
fi

# --- 6. offline with no cache -> SILENT, exit 0 ------------------------------
# No marketplace file, offline forced, empty cache dir => nothing to compare.
OUT="$(CLAUDE_PLUGIN_DATA="$WORK/c6" QX_UPDATE_MARKETPLACE_FILE="" QX_UPDATE_OFFLINE=1 \
       QX_UPDATE_INSTALLED_PLUGINS_FILE="$NO_INSTALLED_PLUGINS_FILE" \
       QX_UPDATE_INSTALLED_SETUP=1.0.0 QX_UPDATE_INSTALLED_QUETREX=2.0.0 QX_UPDATE_INSTALLED_FACTORY=1.0.0 \
       hook_env bash "$HOOK" </dev/null)"; RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  pass "offline with no cache is silent and exits 0"
else
  fail "offline/no-cache must be silent, exit 0 (got: '$OUT', rc=$RC)"
fi

# --- 7. nothing to compare (no installed versions at all) -> silent, exit 0 -
OUT="$(CLAUDE_PLUGIN_DATA="$WORK/c7" QX_UPDATE_MARKETPLACE_FILE="$MARKET" \
       QX_UPDATE_INSTALLED_PLUGINS_FILE="$NO_INSTALLED_PLUGINS_FILE" \
       QX_UPDATE_INSTALLED_SETUP="" QX_UPDATE_INSTALLED_QUETREX="" QX_UPDATE_INSTALLED_FACTORY="" \
       hook_env bash "$HOOK" </dev/null)"; RC=$?
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
