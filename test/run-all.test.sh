#!/usr/bin/env bash
# test/run-all.test.sh — proves test/run-all.sh actually does what its
# header claims: EVERY unit runs, regardless of an earlier unit's failure or
# crash; nothing that fails is ever swallowed as "0 failures"; the exit code
# is non-zero iff anything failed; and the summary names every failing (and
# skipped) unit individually.
#
# THE CENTRAL PROOF (see the NEGATIVE CONTROL near the bottom): this suite
# builds a fixture directory of synthetic test units, one of which
# ("z_unit_after_failures.sh") sorts alphabetically AFTER several failing/
# crashing units. It then runs BOTH the OLD masking pattern
# (`for f in *.sh; do ... || exit 1; done`, exactly what `npm test` used to
# be) and the NEW test/run-all.sh against the SAME fixture directory, and
# shows the old pattern's output does NOT contain z_unit's marker while the
# new one's does. That is the literal defect this file exists to close —
# not simulated, reproduced.
set -uo pipefail

TOOLROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$TOOLROOT/test/run-all.sh"

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

if [ ! -f "$RUNNER" ]; then
  echo "FAIL: runner not found at $RUNNER"
  exit 1
fi

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/run-all-test.XXXXXX")"
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

# =============================================================================
# Fixture directory: 8 synthetic units exercising every verdict this runner
# assigns (ok / FAIL-notok / FAIL-crash-syntax / FAIL-crash-runtime /
# FAIL-vacuous / SKIP / FAIL-nonzero-exit-despite-all-ok), plus one unit that
# sorts alphabetically LAST to prove later units still execute.
# =============================================================================
DIR="$TMPROOT/fixture"
mkdir -p "$DIR"

cat > "$DIR/unitA.sh" <<'EOF'
#!/usr/bin/env bash
echo "ok - A1 marker-unitA"
exit 0
EOF

cat > "$DIR/unitB.sh" <<'EOF'
#!/usr/bin/env bash
echo "ok - B1 marker-unitB"
echo "NOT OK - B2 marker-unitB deliberately red"
exit 1
EOF

# Genuine bash syntax error -> `bash file` fails to even parse, so it exits
# non-zero having printed ZERO ok/NOT OK lines. Must be reported as a
# failure (CRASHED), never swallowed as "0 failures".
cat > "$DIR/unitC_syntax.sh" <<'EOF'
#!/usr/bin/env bash
if [ 1 -eq 1 ]; then
  echo "unterminated
EOF

# Valid syntax, but crashes at runtime before printing a single assertion.
cat > "$DIR/unitD_runtime.sh" <<'EOF'
#!/usr/bin/env bash
echo "marker-unitD boom, dying before any assertion" >&2
exit 7
EOF

# Exits 0, prints chatter, but ZERO ok/NOT OK lines and no SKIP reason.
# Silent-zero-assertions is exactly the failure mode this whole runner
# exists to catch -> must be reported as a failure (VACUOUS).
cat > "$DIR/unitE_vacuous.sh" <<'EOF'
#!/usr/bin/env bash
echo "marker-unitE ran but asserted nothing"
exit 0
EOF

# Legitimate whole-file skip (the repo-wide convention): zero assertions,
# exit 0, but a stated SKIP reason. Must NOT count as a failure.
cat > "$DIR/unitF_skip.sh" <<'EOF'
#!/usr/bin/env bash
echo "SKIP: marker-unitF optional tool not installed, nothing to test"
exit 0
EOF

# Every printed assertion says "ok -", yet the process itself exits
# non-zero (e.g. a crash during cleanup after results were reported).
# Must NOT be read as green just because nothing was printed as NOT OK.
cat > "$DIR/unitG_afterreport_crash.sh" <<'EOF'
#!/usr/bin/env bash
echo "ok - G1 marker-unitG"
echo "marker-unitG crashing after reporting results" >&2
exit 5
EOF

# Sorts alphabetically LAST. Its marker appearing in the output is the
# proof that a later unit still ran despite every earlier one failing or
# crashing.
cat > "$DIR/z_unit_after_failures.sh" <<'EOF'
#!/usr/bin/env bash
echo "ok - Z1 marker-zunit-still-ran"
exit 0
EOF

chmod +x "$DIR"/*.sh

# =============================================================================
# NEGATIVE CONTROL FIRST: reproduce the OLD masking pattern against this
# EXACT fixture directory and prove it really does hide z_unit. This is
# what makes the positive assertions below non-vacuous — without it, a
# runner that ALSO happened to mask z_unit could still pass the positive
# checks by accident of fixture ordering.
# =============================================================================
OLD_OUT="$(cd "$DIR" && { for f in *.sh; do [ -f "$f" ] || continue; bash "$f" || exit 1; done; } 2>&1)"
if ! printf '%s' "$OLD_OUT" | grep -q 'marker-zunit-still-ran'; then
  pass "NEGATIVE CONTROL: the OLD for-loop pattern (npm test's prior shape) never reaches z_unit_after_failures.sh — reproduces the real masking bug on this fixture"
else
  fail "NEGATIVE CONTROL: expected the OLD pattern to mask z_unit, but its marker showed up anyway — the fixture doesn't reproduce the bug, so the positive assertions below would be meaningless"
fi

# =============================================================================
# THE FIX: same fixture, run through test/run-all.sh.
# =============================================================================
NEW_OUT="$(bash "$RUNNER" "$DIR" 2>&1)"; NEW_CODE=$?

# z_unit PASSES, so (by design) its raw echoed marker is never dumped —
# only its one-line summary entry proves it ran (same reasoning as unitA's
# omission from the marker loop below).
if printf '%s' "$NEW_OUT" | grep -qF 'ok    test/z_unit_after_failures.sh'; then
  pass "z_unit_after_failures.sh ran (and passed) despite every earlier unit failing/crashing — the exact masking this file exists to prevent is gone"
else
  fail "z_unit_after_failures.sh is MISSING from the summary — run-all.sh still masks later units (out: [$NEW_OUT])"
fi

if [ "$NEW_CODE" -eq 1 ]; then
  pass "run-all.sh exits 1 when any unit failed"
else
  fail "expected exit 1 (something failed), got $NEW_CODE"
fi

# NOTE: unitA's marker is deliberately NOT checked here. It's a passing
# unit, and passing units' raw per-assertion output is intentionally never
# dumped (that's the readability requirement) — only its one-line summary
# entry proves it ran, which the per-verdict loop below already checks.
for marker in "marker-unitB" "marker-unitD boom" "marker-unitE ran" "marker-unitF optional" "marker-unitG crashing"; do
  if printf '%s' "$NEW_OUT" | grep -qF "$marker"; then
    pass "output contains evidence unit for '$marker' actually ran"
  else
    fail "output is missing evidence for '$marker' — that unit's run was not surfaced"
  fi
done

# --- per-verdict classification (parallel indexed arrays — no associative
# arrays, this repo's shell stays bash-3.2-compatible) ----------------------
UNITS=(
  unitA.sh
  unitB.sh
  unitC_syntax.sh
  unitD_runtime.sh
  unitE_vacuous.sh
  unitF_skip.sh
  unitG_afterreport_crash.sh
  z_unit_after_failures.sh
)
NEEDLES=(
  "ok    test/unitA.sh"
  "FAIL  test/unitB.sh — 1/2 assertion(s) failed"
  "FAIL  test/unitC_syntax.sh — CRASHED"
  "FAIL  test/unitD_runtime.sh — CRASHED"
  "FAIL  test/unitE_vacuous.sh — VACUOUS"
  "SKIP  test/unitF_skip.sh"
  "FAIL  test/unitG_afterreport_crash.sh — exited 5"
  "ok    test/z_unit_after_failures.sh"
)
i=0
while [ "$i" -lt "${#UNITS[@]}" ]; do
  unit="${UNITS[$i]}"
  needle="${NEEDLES[$i]}"
  if printf '%s' "$NEW_OUT" | grep -qF "$needle"; then
    pass "summary line for $unit starts with the expected verdict ('$needle')"
  else
    fail "summary line for $unit did not match — expected something starting '$needle' (out: [$NEW_OUT])"
  fi
  i=$((i + 1))
done

if printf '%s' "$NEW_OUT" | grep -qE '^2 passed, 5 failed, 1 skipped \(8 file\(s\) total\)$'; then
  pass "aggregate tally is exactly 2 passed, 5 failed, 1 skipped (8 files) — matches the fixture composition"
else
  fail "aggregate tally line missing or wrong (out: [$NEW_OUT])"
fi

if printf '%s' "$NEW_OUT" | grep -q "unexpected EOF"; then
  pass "unitC_syntax.sh's full raw output (bash's own parse-failure message) is printed, not swallowed"
else
  fail "unitC_syntax.sh's crash output was not surfaced anywhere in the report (out: [$NEW_OUT])"
fi

# =============================================================================
# GREEN RUN: an all-passing fixture directory must exit 0 and read cleanly
# (no per-unit dump of full output when nothing failed — team asked this
# stay readable, not just correct).
# =============================================================================
DIR_GREEN="$TMPROOT/fixture-green"
mkdir -p "$DIR_GREEN"
cat > "$DIR_GREEN/onlyunit.sh" <<'EOF'
#!/usr/bin/env bash
echo "ok - only assertion"
exit 0
EOF
chmod +x "$DIR_GREEN/onlyunit.sh"
GREEN_OUT="$(bash "$RUNNER" "$DIR_GREEN" 2>&1)"; GREEN_CODE=$?

if [ "$GREEN_CODE" -eq 0 ]; then
  pass "GREEN: run-all.sh exits 0 when every unit passes"
else
  fail "GREEN: expected exit 0, got $GREEN_CODE (out: [$GREEN_OUT])"
fi
if printf '%s' "$GREEN_OUT" | grep -qE '^1 passed, 0 failed, 0 skipped \(1 file\(s\) total\)$'; then
  pass "GREEN: aggregate tally reads 1 passed, 0 failed, 0 skipped"
else
  fail "GREEN: aggregate tally missing or wrong (out: [$GREEN_OUT])"
fi
# Readability: a passing unit's output is never dumped verbatim (only the
# one-line summary entry), so a green run doesn't force a scroll.
GREEN_LINES=$(printf '%s\n' "$GREEN_OUT" | wc -l | tr -d ' ')
if [ "$GREEN_LINES" -le 12 ]; then
  pass "GREEN: output stays short ($GREEN_LINES lines) — readable on an all-pass run"
else
  fail "GREEN: output is $GREEN_LINES lines for a single trivial passing unit — too noisy to be 'readable when everything passes'"
fi

# =============================================================================
# THE OTHER ORIGINAL BUG: `node test/plugin.test.js && for f in test/*.sh...`
# meant a failing plugin.test.js skipped the ENTIRE shell suite via the `&&`.
# Prove a crashing plugin.test.js no longer prevents the .sh units from
# running.
# =============================================================================
DIR_JS="$TMPROOT/fixture-js"
mkdir -p "$DIR_JS"
cat > "$DIR_JS/plugin.test.js" <<'EOF'
console.log('  ok - one check before the crash');
throw new Error('marker-plugintestjs-deliberate-crash');
EOF
cat > "$DIR_JS/shellunit.sh" <<'EOF'
#!/usr/bin/env bash
echo "ok - marker-shellunit-ran-despite-js-crash"
exit 0
EOF
chmod +x "$DIR_JS/shellunit.sh"

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not installed — the plugin.test.js && masking check needs node, skipping that check only"
else
  JS_OUT="$(bash "$RUNNER" "$DIR_JS" 2>&1)"; JS_CODE=$?
  # shellunit.sh PASSES, so (by design) its raw echoed marker is never
  # dumped — only its one-line summary entry proves it ran.
  if printf '%s' "$JS_OUT" | grep -qF 'ok    test/shellunit.sh'; then
    pass "a crashing plugin.test.js no longer prevents the shell suite from running (the old \`&&\` masking bug)"
  else
    fail "shellunit.sh never ran when plugin.test.js crashes first — the && masking bug is still present (out: [$JS_OUT])"
  fi
  if [ "$JS_CODE" -eq 1 ]; then
    pass "exit is still 1 when plugin.test.js crashes, even though the shell unit passed"
  else
    fail "expected exit 1 when plugin.test.js crashes, got $JS_CODE"
  fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "run-all.test.sh: all checks passed"
  exit 0
else
  echo "run-all.test.sh: FAILURES above"
  exit 1
fi
