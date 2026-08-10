#!/usr/bin/env bash
# test/lib/check-sh.sh — `bash -n` every shell file in the plugin/tooling
# tree. Invoked by `npm run check:sh`.
#
# Lives in test/lib/, NOT test/, so test/run-all.sh's `test/*.sh` glob never
# picks this up as a test unit — it is a linter, not a pass/fail assertion
# suite, and running it a second time (redundantly, under a different
# verdict scheme) inside `npm test` would be confusing, not thorough.
#
# WHY THIS FILE EXISTS (not just a `for f in ...; do bash -n "$f" || exit 1;
# done` one-liner, which is what this replaced): that stopped at the FIRST
# bad file, so a second syntax error anywhere later in the glob order was
# invisible until the first was fixed and the check re-run — the exact
# "fix one, discover N more were hidden" defect test/run-all.sh's header
# documents at the suite level. Collect every bad file, report all of them,
# THEN fail.
#
# Usage: bash test/lib/check-sh.sh [root]
#   root defaults to the repo root, so plain `npm run check:sh` checks the
#   real tree. A test can instead point it at a fixture directory with its
#   own bin/*, test/*.sh etc. to prove the collect-everything behavior
#   without ever touching real repo files — see test/check-scripts.test.sh.
set -u
ROOT="${1:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"}"
cd "$ROOT"

N=0
BAD=0
for f in .claude/hooks/*.sh .claude/lib/*.sh .claude/*.sh .claude/skills/*/*.sh .claude/skills/*/scripts/*.sh bin/* test/*.sh test/lib/*.sh; do
  [ -f "$f" ] || continue
  N=$((N + 1))
  if ! ERR="$(bash -n "$f" 2>&1)"; then
    BAD=$((BAD + 1))
    printf 'NOT OK - %s: %s\n' "$f" "$ERR"
  fi
done

if [ "$N" -eq 0 ]; then
  echo "NOT OK - check:sh: matched 0 shell files — the glob patterns are broken or the tree is empty"
  exit 1
fi

if [ "$BAD" -gt 0 ]; then
  echo
  echo "check:sh: FAILED — $BAD of $N shell file(s) have a bash syntax error (see NOT OK lines above)"
  exit 1
fi

echo "ok - check:sh: $N shell file(s) pass bash -n"
