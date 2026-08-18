#!/usr/bin/env bash
# quick-chain-on-stop.test.sh — Stop runs the QUICK chain; the FULL chain still
# gates shipping.
#
# WHY. verify-gate.sh has no fast-skip by design, so it fires at the end of every
# turn including pure conversation. Measured 2026-08-18 in this repo: full chain
# 133s, quick chain 0.9s. Paying 133s to answer a question drove the operator
# toward switching the gate off, which is worse than anything it catches.
#
# WHAT MUST REMAIN TRUE, and is what this file pins:
#   1. Stop runs the quick chain when the project declares one.
#   2. Nothing is SKIPPED — a real chain executes every turn. There is no
#      "already verified" record for the gated agent to forge. (A genuine
#      fast-skip was rejected for exactly that: it trusted the agent-writable
#      ledger, and one appended line let a red chain exit 0.)
#   3. A repo with NO verifyQuick still gets the full chain on Stop.
#   4. verifyQuick is not a loophole — it must be a subset of verify[], so
#      an arbitrary replacement is rejected and the full chain runs.
#   5. Red is still red: the quick chain BLOCKS when one of its commands fails.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${QX_VERIFY_GATE_HOOK:-$ROOT/.claude/hooks/verify-gate.sh}"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); echo "ok - $1"; }
notok() { FAIL=$((FAIL+1)); echo "NOT OK - $1"; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable — verify-gate is jq-mandatory"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
MARK="$TMP/marks"; : > "$MARK"

mkrepo() { # mkrepo <dir> <verify-json>
  mkdir -p "$1/.quetrex"; git -C "$1" init --quiet 2>/dev/null
  printf '%s' "$2" > "$1/.quetrex/verify.json"
  git -C "$1" add -A 2>/dev/null; git -C "$1" -c user.email=t@t -c user.name=t commit -qm init 2>/dev/null
}
fire() { # fire <repo> <event> -> stdout
  ( cd "$1" && CLAUDE_PROJECT_DIR="$1" bash "$HOOK" </dev/null 2>/dev/null ) # event via payload below
}
fire_ev() { # fire_ev <repo> <event>
  printf '{"hook_event_name":"%s","cwd":"%s"}' "$2" "$1" | ( cd "$1" && CLAUDE_PROJECT_DIR="$1" bash "$HOOK" 2>/dev/null )
}

# --- 1+2: Stop runs the QUICK commands and NOT the slow one ------------------
R1="$TMP/r1"
mkrepo "$R1" '{"verify":["sh -c \"echo quick >> '"$MARK"'\"","sh -c \"echo SLOW >> '"$MARK"'\""],"verifyQuick":["sh -c \"echo quick >> '"$MARK"'\""]}'
: > "$MARK"; OUT="$(fire_ev "$R1" Stop)"
# grep -c prints 0 AND exits 1 on no match, so `|| echo 0` would emit "0\n0"
# and break the arithmetic test. Count with a pipeline that always exits 0.
Q=$(grep -c '^quick$' "$MARK" 2>/dev/null; true); Q=${Q:-0}
S=$(grep -c '^SLOW$' "$MARK" 2>/dev/null; true); S=${S:-0}
[ "$Q" -ge 1 ] && ok "Stop RAN the quick chain ($Q command(s)) — nothing is skipped, a real check executed" \
                || notok "Stop ran nothing — a turn finished with no verification at all"
[ "$S" -eq 0 ] && ok "Stop did NOT run the slow command — the 133s cost is off the per-turn loop" \
               || notok "Stop still ran the slow command; the change had no effect"

# --- 3: no verifyQuick declared -> full chain on Stop ------------------------
R2="$TMP/r2"
mkrepo "$R2" '{"verify":["sh -c \"echo full >> '"$MARK"'\""]}'
: > "$MARK"; fire_ev "$R2" Stop >/dev/null
F=$(grep -c '^full$' "$MARK" 2>/dev/null; true); [ "${F:-0}" -ge 1 ] \
  && ok "no verifyQuick declared: Stop runs the FULL chain — repos that never opted in are unaffected" \
  || notok "no verifyQuick declared and Stop ran nothing — the fallback is broken"

# --- 4: verifyQuick that is NOT a subset of verify[] is rejected -------------
R3="$TMP/r3"
mkrepo "$R3" '{"verify":["sh -c \"echo full >> '"$MARK"'\""],"verifyQuick":["true"]}'
: > "$MARK"; fire_ev "$R3" Stop >/dev/null
F=$(grep -c '^full$' "$MARK" 2>/dev/null; true); [ "${F:-0}" -ge 1 ] \
  && ok "non-subset verifyQuick rejected: the FULL chain ran — verifyQuick cannot be an arbitrary replacement" \
  || notok "verifyQuick:[\"true\"] replaced the chain — a repo can switch verification off"

# --- 5: red is still red on the quick chain ----------------------------------
R4="$TMP/r4"
mkrepo "$R4" '{"verify":["sh -c \"exit 1\"","sh -c \"echo SLOW >> '"$MARK"'\""],"verifyQuick":["sh -c \"exit 1\""]}'
: > "$MARK"; OUT="$(fire_ev "$R4" Stop)"
printf '%s' "$OUT" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' \
  && ok "a failing quick command BLOCKS the finish — the gate still gates" \
  || notok "a failing quick command did not block; the finish was allowed with the tree red"

echo
echo "quick-chain-on-stop.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
