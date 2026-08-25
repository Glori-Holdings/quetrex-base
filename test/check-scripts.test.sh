#!/usr/bin/env bash
# test/check-scripts.test.sh — proves test/lib/check-sh.sh and
# test/lib/check-json.sh collect EVERY bad file before failing, instead of
# stopping at the first one (the same defect class as npm test's old
# fail-fast loop — see test/run-all.sh's header and test/run-all.test.sh).
#
# Both scripts accept an optional [root] argument specifically so this file
# can point them at a throwaway fixture directory and prove the
# collect-everything behavior WITHOUT ever writing a broken file into the
# real repo tree.
set -uo pipefail

TOOLROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_SH="$TOOLROOT/test/lib/check-sh.sh"
CHECK_JSON="$TOOLROOT/test/lib/check-json.sh"

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

if [ ! -f "$CHECK_SH" ]; then
  echo "FAIL: check-sh.sh not found at $CHECK_SH"
  exit 1
fi
if [ ! -f "$CHECK_JSON" ]; then
  echo "FAIL: check-json.sh not found at $CHECK_JSON"
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not installed — check-json.sh needs node, nothing to test"
  exit 0
fi

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/check-scripts-test.XXXXXX")"
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

# =============================================================================
# check-sh.sh — a fixture tree with 2 files with real bash syntax errors
# planted deliberately NOT adjacent in glob order, plus 1 good file, so
# "collects both, not just the first" is actually exercised.
# =============================================================================
SHROOT="$TMPROOT/shfix"
mkdir -p "$SHROOT/.claude/hooks" "$SHROOT/.claude/lib" "$SHROOT/.claude/skills/x/scripts" "$SHROOT/bin" "$SHROOT/test"

cat > "$SHROOT/.claude/hooks/aaa-good.sh" <<'EOF'
#!/usr/bin/env bash
echo "fine"
EOF

cat > "$SHROOT/.claude/hooks/bbb-bad-first.sh" <<'EOF'
#!/usr/bin/env bash
if [ 1 -eq 1 ]; then
  echo "unterminated
EOF

cat > "$SHROOT/bin/zzz-bad-last" <<'EOF'
#!/usr/bin/env bash
for x in 1 2 3; do
  echo "$x"
EOF

SH_OUT="$(bash "$CHECK_SH" "$SHROOT" 2>&1)"; SH_CODE=$?

if [ "$SH_CODE" -eq 1 ]; then
  pass "check-sh.sh exits 1 when any file has a syntax error"
else
  fail "check-sh.sh: expected exit 1, got $SH_CODE (out: [$SH_OUT])"
fi
if printf '%s' "$SH_OUT" | grep -qF 'bbb-bad-first.sh'; then
  pass "check-sh.sh reports the FIRST bad file"
else
  fail "check-sh.sh did not report bbb-bad-first.sh (out: [$SH_OUT])"
fi
if printf '%s' "$SH_OUT" | grep -qF 'zzz-bad-last'; then
  pass "check-sh.sh ALSO reports a SECOND bad file that sorts after the first — proves it doesn't stop at the first failure"
else
  fail "check-sh.sh did not report zzz-bad-last (the old for-loop would have stopped before reaching it) (out: [$SH_OUT])"
fi
NOTOK_N="$(printf '%s\n' "$SH_OUT" | grep -c '^NOT OK - ')"
if [ "$NOTOK_N" -eq 2 ]; then
  pass "check-sh.sh reports exactly 2 NOT OK lines — the good file is not misreported"
else
  fail "check-sh.sh: expected exactly 2 NOT OK lines, got $NOTOK_N (out: [$SH_OUT])"
fi

# GREEN: remove the 2 bad files, confirm it goes back to a clean pass.
rm -f "$SHROOT/.claude/hooks/bbb-bad-first.sh" "$SHROOT/bin/zzz-bad-last"
SH_GREEN_OUT="$(bash "$CHECK_SH" "$SHROOT" 2>&1)"; SH_GREEN_CODE=$?
if [ "$SH_GREEN_CODE" -eq 0 ] && printf '%s' "$SH_GREEN_OUT" | grep -qE '^ok - check:sh: 1 shell file'; then
  pass "check-sh.sh: GREEN once the bad files are gone (exit 0, 1 file(s) pass)"
else
  fail "check-sh.sh: expected a clean green pass after removing the bad files, got exit $SH_GREEN_CODE (out: [$SH_GREEN_OUT])"
fi

# 0-files-matched guard: an empty tree must fail loudly, not report a vacuous pass.
EMPTYROOT="$TMPROOT/shempty"
mkdir -p "$EMPTYROOT"
SH_EMPTY_OUT="$(bash "$CHECK_SH" "$EMPTYROOT" 2>&1)"; SH_EMPTY_CODE=$?
if [ "$SH_EMPTY_CODE" -eq 1 ] && printf '%s' "$SH_EMPTY_OUT" | grep -qF 'matched 0 shell files'; then
  pass "check-sh.sh: a tree matching 0 files fails loudly instead of vacuously passing"
else
  fail "check-sh.sh: expected exit 1 naming '0 shell files' for an empty tree, got exit $SH_EMPTY_CODE (out: [$SH_EMPTY_OUT])"
fi

# =============================================================================
# check-json.sh — a fixture tree with 2 of the 8 expected files malformed,
# planted at opposite ends of the fixed file list.
# =============================================================================
JROOT="$TMPROOT/jfix"
mkdir -p "$JROOT/.claude" "$JROOT/.claude/templates" "$JROOT/.quetrex" "$JROOT/.claude-plugin" "$JROOT/hooks" \
  "$JROOT/plugins/quetrex-factory/.claude-plugin" "$JROOT/plugins/quetrex-factory/hooks"

printf '{ this is not json' > "$JROOT/package.json"                       # first in the list, bad
echo '{}' > "$JROOT/.claude/settings.json"
echo '{}' > "$JROOT/.claude/templates/verify.json"
echo '{}' > "$JROOT/.quetrex/verify.json"
echo '{}' > "$JROOT/.claude-plugin/plugin.json"
echo '{}' > "$JROOT/hooks/hooks.json"
echo '{}' > "$JROOT/plugins/quetrex-factory/.claude-plugin/plugin.json"
printf '{ "also": not json' > "$JROOT/plugins/quetrex-factory/hooks/hooks.json"   # last in the list, bad

J_OUT="$(bash "$CHECK_JSON" "$JROOT" 2>&1)"; J_CODE=$?

if [ "$J_CODE" -eq 1 ]; then
  pass "check-json.sh exits 1 when any file is malformed"
else
  fail "check-json.sh: expected exit 1, got $J_CODE (out: [$J_OUT])"
fi
if printf '%s' "$J_OUT" | grep -qF 'NOT OK - package.json'; then
  pass "check-json.sh reports the FIRST bad file (package.json)"
else
  fail "check-json.sh did not report package.json (out: [$J_OUT])"
fi
if printf '%s' "$J_OUT" | grep -qF 'NOT OK - plugins/quetrex-factory/hooks/hooks.json'; then
  pass "check-json.sh ALSO reports the LAST bad file (plugins/quetrex-factory/hooks/hooks.json) — proves the uncaught-throw-stops-the-loop bug is gone"
else
  fail "check-json.sh did not report plugins/quetrex-factory/hooks/hooks.json (the old for-loop would have thrown on package.json and never reached it) (out: [$J_OUT])"
fi
JNOTOK_N="$(printf '%s\n' "$J_OUT" | grep -c '^NOT OK - ')"
if [ "$JNOTOK_N" -eq 2 ]; then
  pass "check-json.sh reports exactly 2 NOT OK lines — the 6 well-formed files are not misreported"
else
  fail "check-json.sh: expected exactly 2 NOT OK lines, got $JNOTOK_N (out: [$J_OUT])"
fi

# GREEN: fix both files, confirm a clean pass.
echo '{}' > "$JROOT/package.json"
echo '{}' > "$JROOT/plugins/quetrex-factory/hooks/hooks.json"
J_GREEN_OUT="$(bash "$CHECK_JSON" "$JROOT" 2>&1)"; J_GREEN_CODE=$?
if [ "$J_GREEN_CODE" -eq 0 ] && printf '%s' "$J_GREEN_OUT" | grep -qE '^ok - check:json: 8 JSON files parse'; then
  pass "check-json.sh: GREEN once both files are fixed (exit 0, 8 files parse)"
else
  fail "check-json.sh: expected a clean green pass after fixing both files, got exit $J_GREEN_CODE (out: [$J_GREEN_OUT])"
fi

# =============================================================================
# A bad [root] must fail loudly, never silently fall back to `cd`'s failure
# leaving the process in the CURRENT directory — which would then lint/
# parse the REAL repo tree and report "ok", having validated the wrong
# thing entirely while claiming to have checked the fixture.
# =============================================================================
BADROOT="$TMPROOT/this-root-does-not-exist-xyz"
SH_BADROOT_OUT="$(bash "$CHECK_SH" "$BADROOT" 2>&1)"; SH_BADROOT_CODE=$?
if [ "$SH_BADROOT_CODE" -eq 1 ] && printf '%s' "$SH_BADROOT_OUT" | grep -qF 'NOT OK - check:sh: cannot cd to root'; then
  pass "check-sh.sh: a nonexistent root fails loudly instead of silently linting the current directory"
else
  fail "check-sh.sh: expected exit 1 naming the bad root, got exit $SH_BADROOT_CODE (out: [$SH_BADROOT_OUT])"
fi

J_BADROOT_OUT="$(bash "$CHECK_JSON" "$BADROOT" 2>&1)"; J_BADROOT_CODE=$?
if [ "$J_BADROOT_CODE" -eq 1 ] && printf '%s' "$J_BADROOT_OUT" | grep -qF 'NOT OK - check:json: cannot cd to root'; then
  pass "check-json.sh: a nonexistent root fails loudly instead of silently checking the current directory"
else
  fail "check-json.sh: expected exit 1 naming the bad root, got exit $J_BADROOT_CODE (out: [$J_BADROOT_OUT])"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "check-scripts.test.sh: all checks passed"
  exit 0
else
  echo "check-scripts.test.sh: FAILURES above"
  exit 1
fi
