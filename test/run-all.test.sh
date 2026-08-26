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
echo "unitA.sh: all checks passed"
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
echo "z_unit_after_failures.sh: all checks passed"
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
# POSITIVE ANCHOR FIRST: prove the old-pattern subshell actually executed
# something (unitB's marker, the file it stops on) before trusting z_unit's
# ABSENCE as meaningful. Without this, the absence check alone would also
# pass against a subshell that ran nothing at all (e.g. a typo'd $DIR, or
# the fixture files failing to get created) — a vacuous negative control.
if printf '%s' "$OLD_OUT" | grep -q 'marker-unitB'; then
  pass "NEGATIVE CONTROL: the OLD pattern's subshell genuinely ran unitB (positive anchor — the absence check below is not vacuous)"
else
  fail "NEGATIVE CONTROL: the OLD pattern's subshell never even reached unitB — the fixture isn't exercising anything, so the absence check below would be meaningless (out: [$OLD_OUT])"
fi
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
echo "onlyunit.sh: all checks passed"
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
echo "shellunit.sh: all checks passed"
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

# =============================================================================
# ZERO UNITS MUST NEVER BE GREEN. Without this guard, an empty/missing/
# renamed test directory silently tallies 0/0/0 and exits 0 — a suite that
# checked nothing, reported as passing, on the exact check ("verify chain")
# that's a REQUIRED status check under branch protection. Mirrors
# test/lib/check-sh.sh's own "matched 0 shell files" guard and CI's own
# "An empty chain is not a green chain" (verify.yml). Checked against BOTH
# an empty existing directory and a directory that doesn't exist, AND
# specifically against bash 3.2 (stock macOS /bin/bash — the very
# compatibility this file's header claims): on 3.2, `"${SUMMARY[@]}"` on an
# EMPTY array under `set -u` is a hard crash, not just a false green, if
# the guard isn't hit first.
# =============================================================================
EMPTY_DIR="$TMPROOT/empty-fixture"
mkdir -p "$EMPTY_DIR"
EMPTY_OUT="$(bash "$RUNNER" "$EMPTY_DIR" 2>&1)"; EMPTY_CODE=$?
if [ "$EMPTY_CODE" -eq 1 ]; then
  pass "ZERO UNITS: an empty existing directory exits 1, not 0"
else
  fail "ZERO UNITS: expected exit 1 for an empty directory, got $EMPTY_CODE (out: [$EMPTY_OUT])"
fi
if printf '%s' "$EMPTY_OUT" | grep -qF 'NOT OK'; then
  pass "ZERO UNITS: an empty directory's failure is reported as NOT OK, not silently"
else
  fail "ZERO UNITS: an empty directory produced no NOT OK line (out: [$EMPTY_OUT])"
fi

MISSING_DIR="$TMPROOT/does-not-exist-at-all-xyz"
MISSING_OUT="$(bash "$RUNNER" "$MISSING_DIR" 2>&1)"; MISSING_CODE=$?
if [ "$MISSING_CODE" -eq 1 ]; then
  pass "ZERO UNITS: a nonexistent directory exits 1, not 0"
else
  fail "ZERO UNITS: expected exit 1 for a nonexistent directory, got $MISSING_CODE (out: [$MISSING_OUT])"
fi

if [ -x /bin/bash ] && /bin/bash --version 2>/dev/null | grep -q 'version 3\.'; then
  BASH32_OUT="$(/bin/bash "$RUNNER" "$EMPTY_DIR" 2>&1)"; BASH32_CODE=$?
  if [ "$BASH32_CODE" -eq 1 ]; then
    pass "ZERO UNITS (bash 3.2 /bin/bash): exits 1 cleanly — not a crash, not a false green"
  else
    fail "ZERO UNITS (bash 3.2 /bin/bash): expected exit 1, got $BASH32_CODE (out: [$BASH32_OUT])"
  fi
  if printf '%s' "$BASH32_OUT" | grep -qi 'unbound variable'; then
    fail "ZERO UNITS (bash 3.2 /bin/bash): crashed with an unbound-variable error instead of a clean guard (out: [$BASH32_OUT])"
  else
    pass "ZERO UNITS (bash 3.2 /bin/bash): no unbound-variable crash"
  fi
else
  echo "SKIP: /bin/bash on this machine is not bash 3.2 — the 3.2-specific empty-array-crash check is skipped (the exit-code guard above still ran under whatever \`bash\` is on PATH)"
fi

# =============================================================================
# SKIP must be the EXACT stated convention (`SKIP: <non-empty reason>`),
# never any line merely starting with the letters SKIP. An empty reason
# (`SKIP:`) or an unrelated word (`SKIPPING ...`) must NOT be treated as a
# legitimate skip — both are VACUOUS (0 assertions, no real stated reason).
# =============================================================================
SKIPFIX="$TMPROOT/skip-fixture"
mkdir -p "$SKIPFIX"
cat > "$SKIPFIX/empty_reason.sh" <<'EOF'
#!/usr/bin/env bash
echo "SKIP:"
exit 0
EOF
cat > "$SKIPFIX/unanchored.sh" <<'EOF'
#!/usr/bin/env bash
echo "SKIPPING the slow path for speed"
exit 0
EOF
cat > "$SKIPFIX/real_skip.sh" <<'EOF'
#!/usr/bin/env bash
echo "SKIP: optional tool not installed, nothing to test"
exit 0
EOF
chmod +x "$SKIPFIX"/*.sh
SKIP_OUT="$(bash "$RUNNER" "$SKIPFIX" 2>&1)"; SKIP_CODE=$?

if printf '%s' "$SKIP_OUT" | grep -qF 'FAIL  test/empty_reason.sh'; then
  pass "SKIP ANCHOR: 'SKIP:' with an empty reason is NOT accepted as a skip"
else
  fail "SKIP ANCHOR: 'SKIP:' with an empty reason was wrongly accepted (out: [$SKIP_OUT])"
fi
if printf '%s' "$SKIP_OUT" | grep -qF 'FAIL  test/unanchored.sh'; then
  pass "SKIP ANCHOR: 'SKIPPING ...' (not the declared convention) is NOT accepted as a skip"
else
  fail "SKIP ANCHOR: 'SKIPPING ...' was wrongly accepted as a skip (out: [$SKIP_OUT])"
fi
# The old bug (`${skip_line#SKIP}` chewing into "SKIPPING...") only ever
# manifested as a mangled "SKIP  <label> — PING the slow path..." SUMMARY
# line for a unit that got (wrongly) classified as a skip. unanchored.sh is
# now correctly classified FAIL/VACUOUS instead (checked above), so no SKIP
# summary line for it can exist at all — check the SUMMARY-line prefix
# specifically, not a blind substring search: unanchored.sh's own raw
# dumped output legitimately contains the literal text "SKIPPING the slow
# path", which itself contains "PING the slow path" as a substring, so a
# plain `grep -qF 'PING the slow path'` over the whole output would
# false-positive on the fixture's own wording, not the bug.
if printf '%s' "$SKIP_OUT" | grep -qF 'SKIP  test/unanchored.sh'; then
  fail "SKIP ANCHOR: the old chewed-prefix bug produced a SKIP summary line for unanchored.sh (out: [$SKIP_OUT])"
else
  pass "SKIP ANCHOR: no SKIP summary line exists for unanchored.sh — the chewed-prefix bug's output shape is gone"
fi
if printf '%s' "$SKIP_OUT" | grep -qF 'SKIP  test/real_skip.sh — optional tool not installed'; then
  pass "SKIP ANCHOR: a genuine 'SKIP: <reason>' line is still correctly accepted, with the reason intact"
else
  fail "SKIP ANCHOR: a genuine skip was wrongly rejected or its reason mangled (out: [$SKIP_OUT])"
fi
if [ "$SKIP_CODE" -eq 1 ]; then
  pass "SKIP ANCHOR: overall exit is 1 (the 2 fake skips are real failures, despite 1 genuine skip alongside them)"
else
  fail "SKIP ANCHOR: expected exit 1, got $SKIP_CODE"
fi

# =============================================================================
# ASSERTION COUNT MUST NOT INFLATE FROM ECHOED/CATTED TEXT. A unit with
# ZERO real test logic that merely dumps content shaped like "ok - ..."
# must not be credited with a genuine pass just because the raw line count
# is non-zero — that is the VACUOUS hole reached by inflation instead of
# by staying at zero, and it defeats the whole point of the VACUOUS rule.
# =============================================================================
FAKEFIX="$TMPROOT/fake-fixture"
mkdir -p "$FAKEFIX"
cat > "$FAKEFIX/fakepass.sh" <<'EOF'
#!/usr/bin/env bash
cat <<'INNER'
ok - fake assertion 1
ok - fake assertion 2
INNER
exit 0
EOF
chmod +x "$FAKEFIX/fakepass.sh"
FAKE_OUT="$(bash "$RUNNER" "$FAKEFIX" 2>&1)"; FAKE_CODE=$?
if printf '%s' "$FAKE_OUT" | grep -qF 'FAIL  test/fakepass.sh — UNCORROBORATED'; then
  pass "ASSERTION INFLATION: a unit that only cats fake 'ok - ' lines is rejected as UNCORROBORATED, never counted as a real pass"
else
  fail "ASSERTION INFLATION: the fake pass was accepted as real (out: [$FAKE_OUT])"
fi
if [ "$FAKE_CODE" -eq 1 ]; then
  pass "ASSERTION INFLATION: overall exit is 1"
else
  fail "ASSERTION INFLATION: expected exit 1, got $FAKE_CODE"
fi

# =============================================================================
# OVERFLOW CLAMP (review finding): an all-digit RUN_ALL_JOBS wider than int64
# must clamp to the cap and complete, not hang with an empty semaphore.
# `timeout` is GNU coreutils (absent on stock macOS): use it or gtimeout when
# present so a regression shows as exit 124 instead of a hung suite; without
# either, run bare — the pre-fix runner would then hang here, which is still a
# loud red, never a false green.
if command -v timeout >/dev/null 2>&1; then OVF_TO="timeout 60"
elif command -v gtimeout >/dev/null 2>&1; then OVF_TO="gtimeout 60"
else OVF_TO=""; fi
OVF_OUT="$(RUN_ALL_JOBS=99999999999999999999 $OVF_TO bash "$RUNNER" "$DIR" 2>&1)"; OVF_CODE=$?
if [ "$OVF_CODE" -ne 124 ] && printf '%s' "$OVF_OUT" | grep -q 'TEST SUMMARY' && ! printf '%s' "$OVF_OUT" | grep -q 'integer expected'; then
  pass "OVERFLOW CLAMP: RUN_ALL_JOBS wider than int64 completes with a summary (exit $OVF_CODE, no integer-expected errors)"
else
  fail "OVERFLOW CLAMP: RUN_ALL_JOBS=99999999999999999999 hung or errored (exit $OVF_CODE)"
fi

# =============================================================================
# PARALLEL PARITY. run-all.sh now executes units N-wide by default (execute)
# and classifies them sequentially afterward (classify) — this must produce
# EXACTLY the same per-unit verdicts, counts, and exit code as
# RUN_ALL_JOBS=1 (today's original one-at-a-time behavior) on the SAME mixed
# pass/fail/vacuous/crash fixture ($DIR, built above). Per-unit elapsed
# seconds legitimately differ between the two runs (a real wall-clock
# measurement, not a deterministic value), so it is stripped before
# comparing — everything else must match byte-for-byte.
# =============================================================================
strip_elapsed() { printf '%s\n' "$1" | sed -E 's/ \([0-9]+s\)$//'; }

SEQ_OUT="$(RUN_ALL_JOBS=1 bash "$RUNNER" "$DIR" 2>&1)"; SEQ_CODE=$?
PAR_OUT="$(bash "$RUNNER" "$DIR" 2>&1)"; PAR_CODE=$?

SEQ_CLASS="$(strip_elapsed "$SEQ_OUT" | grep -E '^(ok    |FAIL  |SKIP  )' | sort)"
PAR_CLASS="$(strip_elapsed "$PAR_OUT" | grep -E '^(ok    |FAIL  |SKIP  )' | sort)"
if [ -n "$SEQ_CLASS" ] && [ "$SEQ_CLASS" = "$PAR_CLASS" ]; then
  pass "PARALLEL PARITY: RUN_ALL_JOBS=1 and default-parallel produce IDENTICAL per-unit classifications for the mixed pass/fail/vacuous/crash fixture"
else
  fail "PARALLEL PARITY: classification mismatch between sequential and parallel runs (sequential=[$SEQ_CLASS] parallel=[$PAR_CLASS])"
fi

if [ "$SEQ_CODE" = "$PAR_CODE" ]; then
  pass "PARALLEL PARITY: exit codes match between sequential and parallel runs ($SEQ_CODE)"
else
  fail "PARALLEL PARITY: exit codes differ (sequential=$SEQ_CODE parallel=$PAR_CODE)"
fi

SEQ_TALLY="$(printf '%s' "$SEQ_OUT" | grep -E '^[0-9]+ passed, [0-9]+ failed, [0-9]+ skipped')"
PAR_TALLY="$(printf '%s' "$PAR_OUT" | grep -E '^[0-9]+ passed, [0-9]+ failed, [0-9]+ skipped')"
if [ -n "$SEQ_TALLY" ] && [ "$SEQ_TALLY" = "$PAR_TALLY" ]; then
  pass "PARALLEL PARITY: aggregate tally matches between sequential and parallel runs ($SEQ_TALLY)"
else
  fail "PARALLEL PARITY: aggregate tally differs (sequential=[$SEQ_TALLY] parallel=[$PAR_TALLY])"
fi

if printf '%s' "$PAR_OUT" | grep -qF 'slowest unit(s):'; then
  pass "PARALLEL PARITY: the parallel run reports the slowest unit(s) after the summary"
else
  fail "PARALLEL PARITY: no slowest-unit(s) report found in the parallel run's output (out: [$PAR_OUT])"
fi

# =============================================================================
# PARALLEL CRASH CAPTURE. A unit that writes PARTIAL output and then crashes
# mid-run, running CONCURRENTLY alongside other units under the default
# (parallel) job count, must still be captured in full (never truncated by
# a sibling unit's own output landing in the same file) and classified
# exactly as it would be run alone.
# =============================================================================
DIR_CRASH="$TMPROOT/fixture-partial-crash"
mkdir -p "$DIR_CRASH"
cat > "$DIR_CRASH/unitX_sleep1.sh" <<'EOF'
#!/usr/bin/env bash
sleep 1
echo "ok - X1 marker-unitX-concurrent"
echo "unitX_sleep1.sh: all checks passed"
exit 0
EOF
cat > "$DIR_CRASH/unitY_sleep2.sh" <<'EOF'
#!/usr/bin/env bash
sleep 1
echo "ok - Y1 marker-unitY-concurrent"
echo "unitY_sleep2.sh: all checks passed"
exit 0
EOF
# Writes SOME output (one real assertion, one plain marker line), THEN
# crashes with a non-zero exit and no closing "NOT OK" line — proves the
# partial pre-crash output survives concurrent capture (each unit writes to
# its own dedicated file, never a shared stream) and is classified via the
# "exited N after M passing assertion(s)" branch, not silently swallowed.
cat > "$DIR_CRASH/unitZ_partial_crash.sh" <<'EOF'
#!/usr/bin/env bash
echo "ok - Z1 marker-unitZ-partial-before-crash"
echo "marker-unitZ-mid-output-before-crash-should-not-be-truncated"
exit 42
EOF
chmod +x "$DIR_CRASH"/*.sh
CRASH_OUT="$(bash "$RUNNER" "$DIR_CRASH" 2>&1)"; CRASH_CODE=$?

if printf '%s' "$CRASH_OUT" | grep -qF 'marker-unitZ-mid-output-before-crash-should-not-be-truncated'; then
  pass "PARALLEL CRASH CAPTURE: partial output written before a mid-run crash is captured in full (not truncated) while other units run concurrently"
else
  fail "PARALLEL CRASH CAPTURE: partial pre-crash output is missing — parallel capture truncated or corrupted it (out: [$CRASH_OUT])"
fi
if printf '%s' "$CRASH_OUT" | grep -qF 'FAIL  test/unitZ_partial_crash.sh — exited 42 after 1 passing assertion'; then
  pass "PARALLEL CRASH CAPTURE: the mid-run crash is classified correctly (exited 42 after 1 passing assertion) despite concurrent siblings"
else
  fail "PARALLEL CRASH CAPTURE: unitZ_partial_crash.sh was not classified as expected (out: [$CRASH_OUT])"
fi
if printf '%s' "$CRASH_OUT" | grep -qF 'ok    test/unitX_sleep1.sh'; then
  pass "PARALLEL CRASH CAPTURE: a concurrently-running sibling unit is still classified correctly (no cross-contamination)"
else
  fail "PARALLEL CRASH CAPTURE: unitX_sleep1.sh missing/misclassified (out: [$CRASH_OUT])"
fi
if [ "$CRASH_CODE" -eq 1 ]; then
  pass "PARALLEL CRASH CAPTURE: overall exit is 1 (one unit crashed)"
else
  fail "PARALLEL CRASH CAPTURE: expected exit 1, got $CRASH_CODE"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "run-all.test.sh: all checks passed"
  exit 0
else
  echo "run-all.test.sh: FAILURES above"
  exit 1
fi
