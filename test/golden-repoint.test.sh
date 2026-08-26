#!/usr/bin/env bash
# test/golden-repoint.test.sh — AC22 of .quetrex/plan/GLOBAL.json: GOLDEN.md
# is doctrine. This task's ONLY license to touch it is the command-name
# rename in drill steps 1 and 2 (/quetrex:login -> /quetrex-setup:login,
# /quetrex:init -> /quetrex-setup:init) — never an invariant, a drill step's
# meaning, or a verdict column.
#
# WHY A MECHANICAL, LINE-BY-LINE CHECK, NOT A PROSE REVIEW. ".claude/CLAUDE.md"
# already states the general rule ("NEVER amend a spec/invariant/doctrine to
# match what an agent built") — this test is what makes that rule
# ENFORCEABLE for this one file, rather than trusting a reviewer to notice.
# For every line the diff touches: the OLD line, after a SINGLE (first-match
# only, matching JS String.prototype.replace's default semantics — GOLDEN.md
# row 2 also names `/quetrex:doctor`, which does NOT move, so a global
# replace would wrongly rename it too and this check would demand the wrong
# thing) substitution of '/quetrex:' -> '/quetrex-setup:', must equal the NEW
# line exactly. Any other difference — reworded prose, a reordered column, a
# deleted/added row — fails loudly.
#
# Compared against 1032770, this branch's merge-base with main (the last
# commit to touch GOLDEN.md before this task) — not a moving ref, so this
# assertion cannot silently go vacuous once this branch merges.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not installed — this check compares diff lines with node"
  echo
  echo "golden-repoint.test.sh: $PASS passed, $FAIL failed"
  exit 0
fi

BASELINE_SHA="1032770"
BASELINE_SHA_FULL="103277068712700cbea040efccfef91a19e8904c"
if ! git -C "$ROOT" cat-file -e "${BASELINE_SHA}^{commit}" 2>/dev/null; then
  git -C "$ROOT" fetch --quiet --depth=1 origin "$BASELINE_SHA_FULL" 2>/dev/null || true
fi
if ! git -C "$ROOT" cat-file -e "${BASELINE_SHA}:GOLDEN.md" 2>/dev/null; then
  notok "baseline commit ${BASELINE_SHA} (or GOLDEN.md at it) is not reachable even after \`git fetch --depth=1 origin ${BASELINE_SHA_FULL}\` — refusing to report a pass having compared against nothing"
  echo
  echo "golden-repoint.test.sh: $PASS passed, $FAIL failed"
  exit 1
fi

DIFF="$(git -C "$ROOT" diff "$BASELINE_SHA" -- GOLDEN.md)"

if [ -z "$DIFF" ]; then
  notok "git diff $BASELINE_SHA -- GOLDEN.md is EMPTY — expected the drill-step 1/2 command rename to have landed"
  echo
  echo "golden-repoint.test.sh: $PASS passed, $FAIL failed"
  exit 1
fi
ok "GOLDEN.md differs from the $BASELINE_SHA baseline (the rename landed)"

RESULT="$(node -e '
  const fs = require("fs");
  const diff = fs.readFileSync(0, "utf8");
  const oldLines = [], newLines = [];
  for (const line of diff.split("\n")) {
    if (line.startsWith("---") || line.startsWith("+++")) continue;
    if (line.startsWith("-")) oldLines.push(line.slice(1));
    else if (line.startsWith("+")) newLines.push(line.slice(1));
  }
  if (oldLines.length !== newLines.length) {
    console.log("NOT OK: removed-line count (" + oldLines.length + ") != added-line count (" + newLines.length + ") — a row was added or deleted outright, not just renamed");
    process.exit(0);
  }
  if (oldLines.length === 0) {
    console.log("NOT OK: 0 changed line pairs found in the diff");
    process.exit(0);
  }
  let bad = 0;
  for (let i = 0; i < oldLines.length; i++) {
    const expected = oldLines[i].replace("/quetrex:", "/quetrex-setup:"); // single-match, like JS default
    if (expected !== newLines[i]) {
      bad++;
      console.log("NOT OK: line differs by more than the command rename:\n  old: " + oldLines[i] + "\n  new: " + newLines[i] + "\n  expected: " + expected);
    }
  }
  if (bad === 0) console.log("OK: " + oldLines.length + " changed line pair(s), each differing ONLY by the /quetrex: -> /quetrex-setup: rename");
' <<< "$DIFF")"

echo "$RESULT"
if printf '%s' "$RESULT" | head -1 | grep -q '^OK:'; then
  ok "every changed line in GOLDEN.md differs from its $BASELINE_SHA predecessor ONLY by the /quetrex: -> /quetrex-setup: rename"
else
  notok "GOLDEN.md was altered beyond the licensed command rename — see the NOT OK detail above"
fi

# The rename must have actually reached the two drill steps this task named.
if grep -q '/quetrex-setup:login' "$ROOT/GOLDEN.md" && grep -q '/quetrex-setup:init' "$ROOT/GOLDEN.md"; then
  ok "GOLDEN.md drill steps 1 and 2 now name /quetrex-setup:login and /quetrex-setup:init"
else
  notok "GOLDEN.md does not name both /quetrex-setup:login and /quetrex-setup:init"
fi

# doctor is untouched by this task's rename — it must still read /quetrex:doctor.
if grep -q '/quetrex:doctor' "$ROOT/GOLDEN.md"; then
  ok "GOLDEN.md's /quetrex:doctor reference is untouched (doctor did not move)"
else
  notok "GOLDEN.md no longer names /quetrex:doctor — doctor.md did not move in this split and should not have been renamed here"
fi

echo
echo "golden-repoint.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
