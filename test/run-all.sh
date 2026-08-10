#!/usr/bin/env bash
# test/run-all.sh — the ONE runner for every test unit: test/plugin.test.js
# (if present) plus every test/*.sh file. `npm test` invokes this instead of
# a `&&`/`|| exit 1` chain.
#
# WHY THIS EXISTS. `npm test` used to be:
#   node test/plugin.test.js && for f in test/*.sh; do ... || exit 1; done
# Two independent short-circuits, both landmines:
#   (a) if plugin.test.js exited non-zero, the `&&` meant NOT ONE shell test
#       file ever ran — the whole shell suite (hundreds of assertions) was
#       silently absent from every report, not merely unreported.
#   (b) the `for` loop's `|| exit 1` stopped at the FIRST failing .sh file —
#       every file alphabetically after it never ran either.
# This was discovered for real: env-derive.test.sh (early alphabetically)
# went red in CI, and because of (b) verify-gate.test.sh (later
# alphabetically, ~200 assertions) never executed on CI AT ALL while that
# was true — not "ran and passed", not "skipped and said so": never invoked,
# with the CI summary reading as a single, unrelated failure. Fixing the one
# reported failure would have shipped straight past two more (see AC26/
# ADV-H, a `stat -f`/`stat -c` portability bug in that same masked file).
#
# So: run EVERY unit unconditionally, ALWAYS. Collect a pass/fail/skip
# verdict per unit. Never let one unit's crash hide another's assertions.
# Print a summary that names every failing unit and how many assertions
# failed in it, so a red run is diagnosable without scrolling. Exit non-zero
# if ANY unit failed — this is a gate, not a report.
#
# Usage: bash test/run-all.sh [dir]
#   dir defaults to the directory this script lives in (test/), so plain
#   `bash test/run-all.sh` runs the real suite. A harness can instead point
#   it at a fixture directory of synthetic ok-/NOT-OK-emitting files to
#   prove the aggregation logic itself in isolation — see
#   test/run-all.test.sh, which does exactly that.
#
# VERDICT PER UNIT — a unit is exactly one of:
#   ok    - exited 0, printed >=1 "ok - "/"NOT OK - " line, 0 of them NOT OK.
#   FAIL  - printed >=1 "NOT OK - " line (regardless of exit code — a unit
#           that reports its own failures must never be read as green just
#           because something upstream forgot to `exit 1`), OR exited
#           non-zero with zero "ok -"/"NOT OK - " lines at all (a syntax
#           error, uncaught exception, or crash before any assertion even
#           ran — reported as CRASHED, never silently swallowed as "0
#           failures"), OR exited 0 with zero assertion lines and no
#           declared reason (VACUOUS — see below).
#   SKIP  - exited 0, printed zero assertion lines, AND printed a line
#           starting with `SKIP` (the repo-wide convention every test file
#           already uses for "an optional tool this file needs isn't
#           installed here"). Informational, not a failure, but never
#           silent: it is named in the summary every single run.
#
# WHY VACUOUS (0 assertions, exit 0, no stated reason) COUNTS AS A FAILURE.
# This runner exists because a whole file's worth of coverage silently
# stopped running and nobody could tell from the report. A test file that
# executes, exits 0, and asserts NOTHING is the exact same failure mode by
# a different mechanism (emptied out, commented out, an early `return`
# added by mistake, a refactor that orphaned every check behind a condition
# that's now always false) — and "exit 0" alone is indistinguishable from
# "this file's checks all genuinely passed". The one thing that tells them
# apart is a stated reason, so an INTENTIONAL whole-file skip must say why
# (`echo "SKIP: ..."`, which every file in this repo already does for
# missing optional tools) — that is the ONLY way to get a pass on zero
# assertions. Silence is never accepted as evidence of anything.
set -u

DIR="${1:-"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"}"

TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0
SUMMARY=()
START_TS=$(date +%s)

run_unit() {  # run_unit <label> <command...>
  local label="$1"; shift
  TOTAL=$((TOTAL + 1))

  local out code ok_n notok_n total_n skip_line
  out="$("$@" 2>&1)"
  code=$?
  ok_n=$(printf '%s\n' "$out" | grep -c '^[[:space:]]*ok - ')
  notok_n=$(printf '%s\n' "$out" | grep -c '^[[:space:]]*NOT OK - ')
  total_n=$((ok_n + notok_n))
  skip_line=$(printf '%s\n' "$out" | grep -m1 '^SKIP')

  if [ "$total_n" -eq 0 ] && [ "$code" -eq 0 ] && [ -n "$skip_line" ]; then
    SKIPPED=$((SKIPPED + 1))
    skip_line="${skip_line#SKIP}"; skip_line="${skip_line#:}"; skip_line="${skip_line# }"
    SUMMARY+=("SKIP  $label — $skip_line")
    return
  fi

  if [ "$notok_n" -gt 0 ]; then
    FAILED=$((FAILED + 1))
    SUMMARY+=("FAIL  $label — $notok_n/$total_n assertion(s) failed")
    printf '\n=== %s (%d/%d assertions failed) ===\n%s\n' "$label" "$notok_n" "$total_n" "$out"
    return
  fi

  if [ "$total_n" -eq 0 ]; then
    FAILED=$((FAILED + 1))
    if [ "$code" -ne 0 ]; then
      SUMMARY+=("FAIL  $label — CRASHED (exit $code, 0 assertions ever ran)")
      printf '\n=== %s (CRASHED, exit %d, 0 assertions ran) ===\n%s\n' "$label" "$code" "$out"
    else
      SUMMARY+=("FAIL  $label — VACUOUS (exited 0, 0 assertions, no SKIP reason given)")
      printf '\n=== %s (VACUOUS — exit 0, 0 assertions, no SKIP reason) ===\n%s\n' "$label" "$out"
    fi
    return
  fi

  if [ "$code" -ne 0 ]; then
    # All assertions reported "ok -" (notok_n==0) yet the process still
    # exited non-zero (e.g. it crashed on cleanup AFTER printing its
    # results). Never read that as green just because every printed
    # assertion happened to pass.
    FAILED=$((FAILED + 1))
    SUMMARY+=("FAIL  $label — exited $code after $ok_n passing assertion(s) (nothing printed as NOT OK, but the process itself failed)")
    printf '\n=== %s (exit %d despite %d/%d assertions printed ok) ===\n%s\n' "$label" "$code" "$ok_n" "$total_n" "$out"
    return
  fi

  PASSED=$((PASSED + 1))
  SUMMARY+=("ok    $label — $ok_n/$total_n assertion(s) passed")
}

PLUGIN_JS="$DIR/plugin.test.js"
[ -f "$PLUGIN_JS" ] && run_unit "test/$(basename "$PLUGIN_JS")" node "$PLUGIN_JS"

for f in "$DIR"/*.sh; do
  [ -f "$f" ] || continue
  base="$(basename "$f")"
  # Never run the runner on itself, or any non-test-unit helper that happens
  # to live alongside the suite (shared fixtures/libraries, not test files).
  [ "$base" = "$(basename "${BASH_SOURCE[0]}")" ] && continue
  run_unit "test/$base" bash "$f"
done

ELAPSED=$(( $(date +%s) - START_TS ))

echo
echo "=========================== TEST SUMMARY ($((ELAPSED))s) ==========================="
printf '%s\n' "${SUMMARY[@]}"
echo "======================================================================="
echo "$PASSED passed, $FAILED failed, $SKIPPED skipped ($TOTAL file(s) total)"

if [ "$FAILED" -gt 0 ]; then
  echo
  echo "npm test: FAILURES in $FAILED file(s) above — full output for each printed inline before this summary."
  exit 1
fi

echo
echo "npm test: all $TOTAL file(s) accounted for ($PASSED passed, $SKIPPED skipped)."
exit 0
