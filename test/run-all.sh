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
# PARALLELISM (perf). Units are independent processes with no shared state,
# so they run N-wide (N = $RUN_ALL_JOBS if set, else the CPU count, capped at
# 16; RUN_ALL_JOBS=1 reproduces the original one-at-a-time behavior). This is
# split into two phases so the VERDICT LOGIC stays byte-identical to the
# original sequential run_unit: `execute` launches every unit in the
# background (via a bash-3.2-compatible FIFO job-slot semaphore — no `wait
# -n`, no associative arrays) and captures each unit's combined stdout+stderr,
# exit code, and elapsed seconds to its own file under a `mktemp -d`
# directory (removed on EXIT); `classify` then runs SEQUENTIALLY, in stable
# alphabetical label order, reading those captured files and applying the
# exact same FAIL/CRASHED/VACUOUS/UNCORROBORATED/SKIP rules as before. Two
# concurrently-running units can never interleave their output (separate
# files) or race on TOTAL/PASSED/FAILED/SKIPPED/SUMMARY (only touched by the
# single-threaded classify phase).
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
if [ ! -d "$DIR" ]; then
  echo "NOT OK - run-all.sh: directory not found: $DIR" >&2
  exit 1
fi

# Job count: $RUN_ALL_JOBS if set, else the CPU count, capped at 16.
# RUN_ALL_JOBS=1 makes every unit run one-at-a-time (today's original
# behavior, still through the same execute/classify code path).
JOBS="${RUN_ALL_JOBS:-}"
if [ -z "$JOBS" ]; then
  if command -v sysctl >/dev/null 2>&1; then
    JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 1)"
  elif command -v nproc >/dev/null 2>&1; then
    JOBS="$(nproc 2>/dev/null || echo 1)"
  else
    JOBS=1
  fi
fi
case "$JOBS" in *[!0-9]*|'') JOBS=1 ;; esac
[ "$JOBS" -lt 1 ] && JOBS=1
[ "$JOBS" -gt 16 ] && JOBS=16

TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0
SUMMARY=()
START_TS=$(date +%s)

# =============================================================================
# BUILD THE UNIT LIST (no execution yet). Index-based parallel arrays — no
# associative arrays, this file stays bash-3.2 (stock macOS /bin/bash)
# compatible.
# =============================================================================
LABELS=()
KINDS=()   # "js" or "sh"
PATHS=()

PLUGIN_JS="$DIR/plugin.test.js"
if [ -f "$PLUGIN_JS" ]; then
  LABELS+=("test/$(basename "$PLUGIN_JS")")
  KINDS+=("js")
  PATHS+=("$PLUGIN_JS")
else
  # Not fatal — most fixture directories legitimately have no plugin.test.js
  # — but it must never be silent: a real repo whose plugin.test.js went
  # missing (wrong path, bad rebase, accidental delete) should be visible,
  # not just quietly absent from the summary with nothing to explain why.
  echo "note: no plugin.test.js found in $DIR — that unit is not part of this run" >&2
fi

for f in "$DIR"/*.sh; do
  [ -f "$f" ] || continue
  base="$(basename "$f")"
  # Never run the runner on itself, or any non-test-unit helper that happens
  # to live alongside the suite (shared fixtures/libraries, not test files).
  [ "$base" = "$(basename "${BASH_SOURCE[0]}")" ] && continue
  LABELS+=("test/$base")
  KINDS+=("sh")
  PATHS+=("$f")
done

N=${#LABELS[@]}

# ZERO UNITS IS NEVER A GREEN RUN. Without this, an empty/missing/renamed
# test directory silently tallies 0/0/0 and exits 0 — a suite that checked
# nothing, reported as passing, on the exact same "verify chain" that's a
# REQUIRED status check under branch protection. This mirrors the guard
# test/lib/check-sh.sh already has ("matched 0 shell files") and the one
# verify.yml's CI workflow already has ("An empty chain is not a green
# chain") — apply it here too, and apply it BEFORE any `${ARRAY[@]}`
# expansion below: on bash 3.2 (stock macOS /bin/bash — the very
# compatibility this suite claims), expanding an EMPTY array under `set -u`
# is itself a hard crash ("SUMMARY[@]: unbound variable"), so this guard
# also has to fire first to avoid that, not just to avoid a false green.
if [ "$N" -eq 0 ]; then
  echo
  echo "NOT OK - run-all.sh: 0 test files found under $DIR — the directory is missing, renamed, or empty. An empty suite is not a passing suite."
  exit 1
fi

# =============================================================================
# EXECUTE (parallel). Each unit's combined stdout+stderr, exit code, and
# elapsed seconds go to their own files under $JOBDIR (mktemp -d, removed on
# EXIT). Concurrency is capped at $JOBS with a bash-3.2-compatible FIFO
# semaphore: no `wait -n` (added in bash 4.3+), no associative arrays.
# =============================================================================
JOBDIR="$(mktemp -d "${TMPDIR:-/tmp}/run-all.XXXXXX")"
trap 'rm -rf "$JOBDIR"' EXIT

execute_one() {  # <idx>
  local idx="$1"
  local kind="${KINDS[$idx]}" path="${PATHS[$idx]}"
  local outfile="$JOBDIR/$idx.out" codefile="$JOBDIR/$idx.code" timefile="$JOBDIR/$idx.time"
  local start end
  start=$(date +%s)
  if [ "$kind" = "js" ]; then
    node "$path" >"$outfile" 2>&1
  else
    bash "$path" >"$outfile" 2>&1
  fi
  printf '%s' "$?" > "$codefile"
  end=$(date +%s)
  printf '%s' "$((end - start))" > "$timefile"
}

SEM_FIFO="$JOBDIR/sem.fifo"
mkfifo "$SEM_FIFO"
exec 8<>"$SEM_FIFO"
rm -f "$SEM_FIFO"
si=0
while [ "$si" -lt "$JOBS" ]; do printf 'x' >&8; si=$((si + 1)); done

PIDS=()
i=0
while [ "$i" -lt "$N" ]; do
  IFS= read -r -n1 _tok <&8   # acquire a slot (blocks until one is free)
  ( execute_one "$i"; printf 'x' >&8 ) &   # run, then release the slot
  PIDS[$i]="$!"
  i=$((i + 1))
done

i=0
while [ "$i" -lt "$N" ]; do
  wait "${PIDS[$i]}" 2>/dev/null
  i=$((i + 1))
done
exec 8>&-

# =============================================================================
# CLASSIFY (sequential, stable alphabetical label order). Same FAIL/CRASHED/
# VACUOUS/UNCORROBORATED/SKIP rules as the original run_unit — only the
# source of $out/$code changed (captured files instead of a live command).
# =============================================================================
classify_one() {  # <idx>
  local idx="$1"
  local label="${LABELS[$idx]}"
  TOTAL=$((TOTAL + 1))

  local out code elapsed ok_n notok_n total_n skip_line base sentinel_ok
  out="$(cat "$JOBDIR/$idx.out" 2>/dev/null)"
  code="$(cat "$JOBDIR/$idx.code" 2>/dev/null)"
  elapsed="$(cat "$JOBDIR/$idx.time" 2>/dev/null)"
  [ -n "$code" ] || code=1
  [ -n "$elapsed" ] || elapsed=0
  ok_n=$(printf '%s\n' "$out" | grep -c '^[[:space:]]*ok - ')
  notok_n=$(printf '%s\n' "$out" | grep -c '^[[:space:]]*NOT OK - ')
  total_n=$((ok_n + notok_n))
  # ANCHORED, NON-EMPTY ONLY. `^SKIP` alone matched `SKIP:` (empty reason,
  # accepted) and `SKIPPING the slow path...` (not the declared convention
  # at all — and `${skip_line#SKIP}` then chewed into the following word,
  # producing "PING the slow path..."). The stated convention every test
  # file in this repo actually uses is `SKIP: <reason>` — require exactly
  # that, with at least one character of reason, or it isn't a skip.
  skip_line=$(printf '%s\n' "$out" | grep -m1 -E '^SKIP: .+')

  if [ "$total_n" -eq 0 ] && [ "$code" -eq 0 ] && [ -n "$skip_line" ]; then
    SKIPPED=$((SKIPPED + 1))
    SUMMARY+=("SKIP  $label — ${skip_line#SKIP: } (${elapsed}s)")
    return
  fi

  if [ "$notok_n" -gt 0 ]; then
    FAILED=$((FAILED + 1))
    SUMMARY+=("FAIL  $label — $notok_n/$total_n assertion(s) failed (${elapsed}s)")
    printf '\n=== %s (%d/%d assertions failed) ===\n%s\n' "$label" "$notok_n" "$total_n" "$out"
    return
  fi

  if [ "$total_n" -eq 0 ]; then
    FAILED=$((FAILED + 1))
    if [ "$code" -ne 0 ]; then
      SUMMARY+=("FAIL  $label — CRASHED (exit $code, 0 assertions ever ran) (${elapsed}s)")
      printf '\n=== %s (CRASHED, exit %d, 0 assertions ran) ===\n%s\n' "$label" "$code" "$out"
    else
      SUMMARY+=("FAIL  $label — VACUOUS (exited 0, 0 assertions, no SKIP reason given) (${elapsed}s)")
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
    SUMMARY+=("FAIL  $label — exited $code after $ok_n passing assertion(s) (nothing printed as NOT OK, but the process itself failed) (${elapsed}s)")
    printf '\n=== %s (exit %d despite %d/%d assertions printed ok) ===\n%s\n' "$label" "$code" "$ok_n" "$total_n" "$out"
    return
  fi

  # SENTINEL CORROBORATION. grep-counting "ok - " lines across the unit's
  # ENTIRE captured stdout+stderr cannot tell a real pass() call apart from
  # a unit that merely echoes/cats unrelated content which happens to
  # contain lines shaped like "ok - ...": a unit with ZERO real logic that
  # just `cat`s a fixture full of "ok - " text would otherwise be reported
  # as a genuine pass with a populated assertion count — the exact hole the
  # VACUOUS rule exists to close, just reached by inflating the count
  # instead of leaving it at zero. Every real test file in this suite
  # (100% of them, by convention, not by accident) ends its run by echoing
  # its OWN basename followed by ": " (`"$b: all checks passed"` /
  # `"$b: FAILURES above"`), and plugin.test.js ends with a `console.log`
  # of `${passed} passed`. Require that corroborating signal before
  # trusting an all-"ok" count as a genuine pass; a unit that never says
  # who it is doesn't get credited with having run for real.
  base="$(basename "$label")"
  case "$base" in
    *.js) sentinel_ok=$(printf '%s\n' "$out" | grep -c -E '^[0-9]+ passed$') ;;
    *)    sentinel_ok=$(printf '%s\n' "$out" | grep -c -F "${base}: ") ;;
  esac
  if [ "$sentinel_ok" -eq 0 ]; then
    FAILED=$((FAILED + 1))
    SUMMARY+=("FAIL  $label — UNCORROBORATED ($ok_n \"ok -\" line(s) printed, but no self-referential completion sentinel — cannot trust the count) (${elapsed}s)")
    printf '\n=== %s (UNCORROBORATED — %d \"ok -\" line(s), no completion sentinel) ===\n%s\n' "$label" "$ok_n" "$out"
    return
  fi

  PASSED=$((PASSED + 1))
  SUMMARY+=("ok    $label — $ok_n/$total_n assertion(s) passed (${elapsed}s)")
}

# Stable alphabetical order over the unit labels (e.g. "test/plugin.test.js"
# sorts among the "test/*.sh" labels, not always first) — a plain `sort` on
# "label<TAB>idx" pairs, then classify by index.
SORT_INPUT=""
i=0
while [ "$i" -lt "$N" ]; do
  SORT_INPUT="${SORT_INPUT}${LABELS[$i]}	${i}
"
  i=$((i + 1))
done
while IFS="	" read -r _label idx; do
  [ -n "$idx" ] || continue
  classify_one "$idx"
done <<EOF_SORT
$(printf '%s' "$SORT_INPUT" | sort)
EOF_SORT

ELAPSED=$(( $(date +%s) - START_TS ))

echo
echo "=========================== TEST SUMMARY ($((ELAPSED))s) ==========================="
printf '%s\n' "${SUMMARY[@]}"
echo "======================================================================="
echo "$PASSED passed, $FAILED failed, $SKIPPED skipped ($TOTAL file(s) total)"

# THE 5 SLOWEST UNITS (perf). So the next hot spot is visible without
# scrolling the summary above and doing the arithmetic by hand.
echo
echo "slowest unit(s):"
SLOW_INPUT=""
i=0
while [ "$i" -lt "$N" ]; do
  u_elapsed="$(cat "$JOBDIR/$i.time" 2>/dev/null)"
  [ -n "$u_elapsed" ] || u_elapsed=0
  SLOW_INPUT="${SLOW_INPUT}${u_elapsed}	${LABELS[$i]}
"
  i=$((i + 1))
done
printf '%s' "$SLOW_INPUT" | sort -rn | head -5 | while IFS="	" read -r u_elapsed u_label; do
  [ -n "$u_label" ] || continue
  printf '  %ss  %s\n' "$u_elapsed" "$u_label"
done

if [ "$FAILED" -gt 0 ]; then
  echo
  echo "npm test: FAILURES in $FAILED file(s) above — full output for each printed inline before this summary."
  exit 1
fi

echo
echo "npm test: all $TOTAL file(s) accounted for ($PASSED passed, $SKIPPED skipped)."
exit 0
