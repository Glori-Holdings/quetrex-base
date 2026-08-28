#!/usr/bin/env bash
# developer.md and qa.md must carry a proportionality constraint. Without one,
# agents inflate scope: a 3-line contract fix shipped as 50 lines of added
# prose plus a 230-line test (observed 2026-08-28). reviewer.md already had
# scope discipline; these two had none.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
A="$ROOT/plugins/quetrex-factory/agents"
BASE_SHA="c221ed99b5c22087e49878aa26309ada88efaab2"   # fixed, never `main`

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

# fail-first: neither file constrained scope at the baseline
for f in developer.md qa.md; do
  OLD="$(git -C "$ROOT" show "$BASE_SHA:plugins/quetrex-factory/agents/$f" 2>/dev/null)"
  if [ -z "$OLD" ]; then
    notok "fail-first: baseline $f unreachable at $BASE_SHA"
  elif printf '%s' "$OLD" | grep -qiE 'smallest change|Proportionality|ceiling, not just a floor'; then
    notok "fail-first: baseline $f already constrained scope — this change is a no-op"
  else
    ok "fail-first: baseline $f had no proportionality constraint"
  fi
done

grep -qF 'smallest change that satisfies' "$A/developer.md" \
  && ok "developer.md requires the smallest change that satisfies the criteria" \
  || notok "developer.md has no smallest-change requirement"
grep -qiF 'do not refactor, rename, reformat' "$A/developer.md" \
  && ok "developer.md forbids unrequested refactors/renames/reformats" \
  || notok "developer.md does not forbid unrequested refactors"
grep -qiF 'ceiling, not just a floor' "$A/qa.md" \
  && ok "qa.md caps added tests at one per acceptance criterion" \
  || notok "qa.md has no ceiling on added tests"

echo
echo "agent-proportionality.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
