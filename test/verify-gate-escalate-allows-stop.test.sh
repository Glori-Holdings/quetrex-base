#!/usr/bin/env bash
# verify-gate-escalate-allows-stop.test.sh
#
# MEASURED DEFECT, 2026-08-25, marketing51 @ fix/pipeline-status-and-cron-watchdog.
# `npm run test` was red. verify-gate.sh escalated at its 3-attempt cap, and then
# kept emitting a `block` on EVERY subsequent Stop: $n increments each invocation
# and never resets while red, so nothing ever took the terminus out of the blocking
# branch. The agent could not end its turn. The runtime finally force-overrode it:
#
#   "A hook blocked the turn from ending 9 consecutive times — overriding and
#    ending turn. For Stop/SubagentStop hooks, check stop_hook_active in the input
#    and return success while it's true."
#
# `stop_hook_active` appeared NOWHERE in the engine.
#
# The escalation text itself says "STOP self-healing. Report this one-line summary
# to the user. Wait for direction." An agent cannot report while it is forbidden to
# finish, so the block defeated its own instruction.
#
# THE CONTRACT THIS PINS:
#   A1  below the cap, a red chain still BLOCKS (self-healing is not weakened)
#   A2  at the cap, it blocks exactly ONCE and the text says ESCALATE
#   A3  past the cap, the stop is ALLOWED — the loop cannot persist
#   A4  stop_hook_active=true at the cap also allows, independently of the counter
#   A5  stop_hook_active=true BELOW the cap still BLOCKS — honoring it earlier
#       would waive attempts 2 and 3 and kill self-healing
#   A6  allowing the STOP never allows the MERGE: .quetrex/ESCALATION is written
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${QX_VERIFY_GATE_HOOK:-$REPO_ROOT/plugins/quetrex-factory/scripts/verify-gate.sh}"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { echo "SKIP - jq unavailable"; exit 0; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/qx-escalate-allows.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

F="$TMPROOT/repo"
mkdir -p "$F/.quetrex"
printf '{"branchPrefix":"claude/"}' > "$F/.quetrex/project.json" 2>/dev/null
git init -q "$F"
git -C "$F" config user.email t@e; git -C "$F" config user.name t
git -C "$F" commit -q --allow-empty -m init
jq -cn '{verify:["false"]}' > "$F/.quetrex/verify.json"   # always red

# run <stop_hook_active|-> -> stdout+stderr, sets RC
run() {
  local sha="$1" payload
  if [ "$sha" = "-" ]; then
    payload="$(jq -cn --arg cwd "$F" '{cwd:$cwd,hook_event_name:"Stop"}')"
  else
    payload="$(jq -cn --arg cwd "$F" --argjson s "$sha" '{cwd:$cwd,hook_event_name:"Stop",stop_hook_active:$s}')"
  fi
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$F" QUETREX_VERIFY_MAX=3 "$HOOK" 2>&1
}
is_block() { printf '%s' "$1" | jq -e 'select(.decision=="block")' >/dev/null 2>&1; }

# --- A1/A2: attempts 1..3 --------------------------------------------------
O1="$(run -)"; O2="$(run -)"; O3="$(run -)"
if is_block "$O1" && is_block "$O2"; then
  pass "A1: attempts 1 and 2 still BLOCK — self-healing is not weakened"
else
  fail "A1: a sub-cap red chain no longer blocks — self-healing is gone. o1=[$O1] o2=[$O2]"
fi
if is_block "$O3" && printf '%s' "$O3" | grep -q 'ESCALATE'; then
  pass "A2: the cap attempt blocks once, with the ESCALATE text"
else
  fail "A2: the cap attempt did not emit an ESCALATE block: [$O3]"
fi

# --- A6: the merge is still barred ----------------------------------------
if [ -f "$F/.quetrex/ESCALATION" ]; then
  pass "A6: .quetrex/ESCALATION is written — merge-gate.sh still refuses; only the STOP is allowed"
else
  fail "A6: no ESCALATION marker — allowing the stop would also let red code merge"
fi

# --- A3: past the cap, the stop is allowed --------------------------------
O4="$(run -)"; RC4=$?
O5="$(run -)"; RC5=$?
if ! is_block "$O4" && [ "$RC4" -eq 0 ] && ! is_block "$O5" && [ "$RC5" -eq 0 ]; then
  pass "A3: past the cap the stop is ALLOWED on every later invocation — the 9-block loop cannot recur"
else
  fail "A3: still blocking past the cap — the measured infinite loop is NOT fixed. o4=[$O4] rc4=$RC4 o5=[$O5] rc5=$RC5"
fi

# --- A4: stop_hook_active allows at the cap, independently of the counter ---
G="$TMPROOT/repo2"; mkdir -p "$G/.quetrex"
printf '{"branchPrefix":"claude/"}' > "$G/.quetrex/project.json"
git init -q "$G"; git -C "$G" config user.email t@e; git -C "$G" config user.name t
git -C "$G" commit -q --allow-empty -m init
jq -cn '{verify:["false"]}' > "$G/.quetrex/verify.json"
echo 3 > "$G/.quetrex/verify-attempts"    # sitting exactly AT the cap
PAY="$(jq -cn --arg cwd "$G" '{cwd:$cwd,hook_event_name:"Stop",stop_hook_active:true}')"
O6="$(printf '%s' "$PAY" | CLAUDE_PROJECT_DIR="$G" QUETREX_VERIFY_MAX=3 "$HOOK" 2>&1)"; RC6=$?
if ! is_block "$O6" && [ "$RC6" -eq 0 ]; then
  pass "A4: stop_hook_active=true at the cap allows the stop — the runtime's own loop-breaker is honored"
else
  fail "A4: stop_hook_active=true was ignored at the cap: [$O6] rc=$RC6"
fi

# --- A5: stop_hook_active must NOT waive self-healing below the cap --------
H="$TMPROOT/repo3"; mkdir -p "$H/.quetrex"
printf '{"branchPrefix":"claude/"}' > "$H/.quetrex/project.json"
git init -q "$H"; git -C "$H" config user.email t@e; git -C "$H" config user.name t
git -C "$H" commit -q --allow-empty -m init
jq -cn '{verify:["false"]}' > "$H/.quetrex/verify.json"
PAY2="$(jq -cn --arg cwd "$H" '{cwd:$cwd,hook_event_name:"Stop",stop_hook_active:true}')"
O7="$(printf '%s' "$PAY2" | CLAUDE_PROJECT_DIR="$H" QUETREX_VERIFY_MAX=3 "$HOOK" 2>&1)"
if is_block "$O7"; then
  pass "A5: stop_hook_active=true BELOW the cap still blocks — attempts 2 and 3 are not waived"
else
  fail "A5: stop_hook_active=true waived self-healing on the FIRST red stop — the gate now allows red on attempt 1: [$O7]"
fi

echo
echo "verify-gate-escalate-allows-stop.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
