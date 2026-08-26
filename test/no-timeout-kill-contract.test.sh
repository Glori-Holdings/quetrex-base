#!/usr/bin/env bash
# test/no-timeout-kill-contract.test.sh — the verify chain is run ONCE per stage with
# an explicit long tool timeout, never killed mid-run and never re-launched.
#
# WHY. 2026-08-26: QA's `npm test` was killed by the Bash tool's 2-minute default
# timeout and re-launched, twice, on a single QA pass — a 7-minute suite ran three
# times. Glen: "What I'm not going to tolerate is processes being respun because of
# a time out." A real app's suite/build/E2E takes minutes; the contracts that run
# the chain must say so, so the rule travels with the plugin to every repo and to
# cloud (where settings.json — and any BASH_DEFAULT_TIMEOUT_MS in it — is discarded).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
A="$ROOT/plugins/quetrex-factory/agents"
PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

for f in qa developer git-workflow; do
  if grep -q 'timeout: 900000' "$A/$f.md"; then
    ok "$f.md names the explicit long tool timeout for chain commands"
  else
    notok "$f.md never tells the agent to pass an explicit long timeout — a >2-minute chain command gets killed and respun"
  fi
  if grep -qiE 'never (be )?(killed|cut off)|never re-?launch|never retried' "$A/$f.md"; then
    ok "$f.md forbids re-launching a chain command cut off by a timeout"
  else
    notok "$f.md does not forbid respinning a timed-out chain command"
  fi
done

# The QA rule must be a Cardinal Rule (violating it is itself a FAIL), not a footnote.
if awk '/^## Cardinal Rules/{f=1} /^## Inputs/{f=0} f' "$A/qa.md" | grep -q 'timeout: 900000'; then
  ok "qa.md carries the rule inside its Cardinal Rules section"
else
  notok "qa.md's timeout rule is not a Cardinal Rule"
fi

b="$(basename "${BASH_SOURCE[0]}")"
echo "$b: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "$b: all checks passed"
[ "$FAIL" -eq 0 ]
