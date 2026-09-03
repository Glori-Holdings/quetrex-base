#!/usr/bin/env bash
# test/setup-repoint-landed.test.sh — AC21 of .quetrex/plan/GLOBAL.json: the
# /quetrex-setup: repoint actually landed WHERE USERS READ IT, not just
# somewhere in the tree. A repo-wide sweep (test/legacy-command-repoint.test.sh)
# proves the old name is gone; this file proves the NEW name is present in
# the specific surfaces a human or another agent actually reads.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

FILES=(
  ".claude/skills/quetrex-pipeline/SKILL.md"
  "docs/onboarding/quetrex-onboarding.html"
  "GOLDEN.md"
  "plugins/quetrex-setup/commands/doctor.md"
  ".claude/commands/merge.md"
  ".claude/lib/dev-pipeline.md"
  "plugins/quetrex-setup/bin/quetrex-api"
  "plugins/quetrex-factory/scripts/verify-gate.sh"
)

for f in "${FILES[@]}"; do
  if [ ! -f "$f" ]; then
    notok "AC21: $f does not exist"
    continue
  fi
  n="$(grep -c '/quetrex-setup:' "$f" 2>/dev/null || true)"
  n="${n:-0}"
  if [ "$n" -ge 1 ]; then
    ok "AC21: $f contains /quetrex-setup: $n time(s) (>= 1)"
  else
    notok "AC21: $f contains 0 occurrences of /quetrex-setup: — the repoint did not land here"
  fi
done

echo
echo "setup-repoint-landed.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
