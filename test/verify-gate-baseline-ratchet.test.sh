#!/usr/bin/env bash
# test/verify-gate-baseline-ratchet.test.sh
#   contract test for the PRE-EXISTING RED baseline + green ratchet in
#   plugins/quetrex-factory/scripts/verify-gate.sh
#
# Run: bash test/verify-gate-baseline-ratchet.test.sh
#
# THE OPERATOR-VISIBLE DEFECT THIS PINS DOWN (measured 2026-08-27, QDM-14).
# verify-gate.sh runs the chain on EVERY Stop and SubagentStop and, by explicit
# design, had no skip path: "every checkout always runs the chain". On a
# GREENFIELD task — build a Next.js app into an empty repo — the very first
# chain command (`npm run lint`) cannot exist until a developer writes the
# package.json script that defines it. So:
#
#   turn 1 -> chain red -> block "fix it"  (self-heal attempt 1)
#   turn 2 -> chain red -> block "fix it"  (self-heal attempt 2)
#   turn 3 -> chain red -> CAP -> .quetrex/ESCALATION written -> pipeline dead
#
# The build died at turn 3, before the architect finished, and the cloud run
# published nothing but its heartbeat commit. Evidence in quetrex-demo:
# ESCALATION reason "verify self-heal cap reached (3 attempts) on `npm run
# lint`", verify-attempts 7, verify-gate-failed.log 'npm error Missing script:
# "lint"', every ledger line pinned to the empty base commit.
#
# The gate could not tell "the agent broke it" from "the code does not exist
# yet", so the gate that exists to stop unfinished work from SHIPPING was
# instead stopping work from STARTING.
#
# THE FIX, AND WHY IT WEAKENS NOTHING. A failing command is measured against
# the BASE of the current work — the merge-base with the default branch. (The
# default branch itself gets NO baseline: there is no earlier commit to measure
# against, so it fails closed exactly as before. See AC4.) A command that
# already failed at that base is
# PRE-EXISTING RED: it is recorded, reported, and does not block or count
# toward the self-heal cap. The instant that command is observed green it is
# pinned in .quetrex/verify-baseline.json `greenSince` and can NEVER be
# pre-existing again — breaking it blocks exactly as before.
#
# It can only affect whether work CONTINUES, never whether it SHIPS: a
# pre-existing ledger line carries a non-zero `exit`, so it is not a green,
# and merge-gate.sh GATE 3 still refuses any merge without a green full-chain
# ledger pinned to HEAD. A fully forged baseline file merges nothing.
#
# AC1  greenfield feature branch, command missing at base  -> ALLOW + report,
#      no attempts increment, no ESCALATION            (FAILS pre-change)
# AC2  command GREEN at base, broken on the branch       -> BLOCKS (the floor)
# AC3  ratchet: red at base, observed green once, then broken -> BLOCKS
# AC4  default branch, red chain (clean tree)            -> BLOCKS + escalates
#      (the floor: no baseline excuse exists on main)
# AC5  default branch, DIRTY tree, red chain             -> BLOCKS (the floor)
# AC6  a pre-existing red never clears a prior ESCALATION and never resets
#      the self-heal counter — it is not a green
# AC7  the ledger records the pre-existing failure with its real non-zero
#      exit and preexisting:true — never exit 0

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${QX_VERIFY_GATE_HOOK:-$REPO_ROOT/plugins/quetrex-factory/scripts/verify-gate.sh}"

[ -f "$HOOK" ] || { echo "FAIL: hook not found at $HOOK"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/verify-baseline-test.XXXXXX")"
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

# --- fixture ---------------------------------------------------------------
# A repo whose verify chain is a single script. Whether that script exists (and
# what it exits) at the BASE commit versus on the branch is the entire variable
# under test. No npm, no network — the mechanism is identical and this runs in
# milliseconds.
CHAIN_CMD='bash ./lint.sh'

mk_repo() {  # mk_repo <path> <base-lint-state: missing|green|red>
  local d="$1" base_state="$2"
  mkdir -p "$d/.quetrex"
  git -C "$d" init -q -b main 2>/dev/null || { git init -q -b main "$d"; }
  git -C "$d" config user.email "test@example.com"
  git -C "$d" config user.name "Fixture"
  printf '{"projectCode":"FIX","branchPrefix":"claude/"}\n' > "$d/.quetrex/project.json"
  jq -cn --arg c "$CHAIN_CMD" '{verify:[$c]}' > "$d/.quetrex/verify.json"
  echo 'fixture' > "$d/README.md"
  case "$base_state" in
    green) printf 'exit 0\n' > "$d/lint.sh" ;;
    red)   printf 'echo "lint failure at base"; exit 1\n' > "$d/lint.sh" ;;
    missing) : ;;
  esac
  git -C "$d" add -A
  git -C "$d" commit -q -m "chore: fixture base"
}

branch_off() {  # branch_off <path> <branch>
  git -C "$1" checkout -q -b "$2"
}

commit_all() {  # commit_all <path> <msg>
  git -C "$1" add -A
  git -C "$1" commit -q -m "$2"
}

# run_hook <cwd> <event> -> stdout; sets RC
RC=0
run_hook() {
  local cwd="$1" event="${2:-Stop}" payload out
  payload="$(jq -cn --arg cwd "$cwd" --arg e "$event" '{cwd:$cwd,hook_event_name:$e}')"
  out="$(printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$cwd" QUETREX_VERIFY_MAX=3 \
        QUETREX_VERIFY_FULL=1 "$HOOK" 2>/dev/null)"
  RC=$?
  printf '%s' "$out"
}

is_block() {  # is_block <hook stdout> -> 0 if it is a block decision
  printf '%s' "$1" | jq -e '.decision == "block"' >/dev/null 2>&1
}

attempts_of() { local f="$1/.quetrex/verify-attempts"; [ -f "$f" ] && cat "$f" || echo 0; }

# --------------------------------------------------------------------------
# AC1 — greenfield: the chain command does not exist at the base commit.
# This is QDM-14 exactly. Pre-change the hook blocks here and escalates on the
# third stop; post-change it allows and reports.
# --------------------------------------------------------------------------
R1="$TMPROOT/ac1"; mk_repo "$R1" missing; branch_off "$R1" claude/FIX-1
# The agent has started work: a file exists that is not the chain command.
echo 'console.log(1)' > "$R1/app.js"; commit_all "$R1" "feat: first slice"

OUT="$(run_hook "$R1")"
if is_block "$OUT"; then
  fail "AC1: a chain command missing at the base commit still BLOCKS the stop (this is the QDM-14 kill)"
else
  pass "AC1: a chain command missing at the base commit does not block the stop"
fi

if printf '%s' "$OUT" | grep -q 'VERIFY PRE-EXISTING RED'; then
  pass "AC1: the pre-existing red is reported on the allow path"
else
  fail "AC1: no 'VERIFY PRE-EXISTING RED' report — a silent allow is indistinguishable from a green"
fi

# Three more stops must never reach the cap, because a pre-existing red is not
# a self-heal attempt.
run_hook "$R1" >/dev/null; run_hook "$R1" >/dev/null; run_hook "$R1" >/dev/null
if [ -f "$R1/.quetrex/ESCALATION" ]; then
  fail "AC1: four stops on a pre-existing red wrote .quetrex/ESCALATION — the pipeline is dead at turn 3"
else
  pass "AC1: repeated stops on a pre-existing red never write ESCALATION"
fi
if [ "$(attempts_of "$R1")" = "0" ]; then
  pass "AC1: a pre-existing red does not increment the self-heal counter"
else
  fail "AC1: self-heal counter is $(attempts_of "$R1") — a pre-existing red must not consume attempts"
fi

# --------------------------------------------------------------------------
# AC2 — THE FLOOR. The command is GREEN at base and the agent breaks it.
# Nothing about the baseline may excuse this.
# --------------------------------------------------------------------------
R2="$TMPROOT/ac2"; mk_repo "$R2" green; branch_off "$R2" claude/FIX-2
printf 'echo "broken by the agent"; exit 1\n' > "$R2/lint.sh"; commit_all "$R2" "feat: break lint"

OUT="$(run_hook "$R2")"
if is_block "$OUT"; then
  pass "AC2 (floor): breaking a command that was green at base still BLOCKS"
else
  fail "AC2 (floor): a regression against a green base was allowed — the gate was weakened"
fi

# --------------------------------------------------------------------------
# AC3 — THE RATCHET. Red at base, made green on the branch, then broken again.
# Once observed green the command can never be pre-existing again.
# --------------------------------------------------------------------------
R3="$TMPROOT/ac3"; mk_repo "$R3" missing; branch_off "$R3" claude/FIX-3
printf 'exit 0\n' > "$R3/lint.sh"; commit_all "$R3" "feat: add lint"
OUT="$(run_hook "$R3")"
if is_block "$OUT"; then
  fail "AC3: a genuinely green chain blocked"
else
  pass "AC3: the chain is green once the branch supplies the command"
fi

printf 'echo "regressed"; exit 1\n' > "$R3/lint.sh"; commit_all "$R3" "fix: regress lint"
OUT="$(run_hook "$R3")"
if is_block "$OUT"; then
  pass "AC3 (ratchet): once observed green, breaking it BLOCKS even though base was red"
else
  fail "AC3 (ratchet): a command observed green fell back to pre-existing — the ratchet does not hold"
fi

# --------------------------------------------------------------------------
# AC4 — THE FLOOR on the default branch. There is no earlier base to measure
# against there, so nothing may be excused: a red chain on main BLOCKS and
# escalates exactly as it always has, clean tree or not.
#
# This is not incidental. An earlier draft of this change added a
# "default-clean" mode that excused red on an unmodified main, and
# test/verify-gate.test.sh rejected it on sight — AC4(i)/AC4(ii)/AC6(i..iii)
# and ADV-A/D/E/F/G/H/I all commit a deliberately red chain on a clean main and
# require a block, several of them as anti-reintroduction controls for the
# main-checkout-deferral fail-open (SEC-1, high) deleted in 2026-08-21. This
# case pins that refusal inside the baseline suite too, so the idea cannot come
# back through this door.
# --------------------------------------------------------------------------
R4="$TMPROOT/ac4"; mk_repo "$R4" red
OUT="$(run_hook "$R4")"
if is_block "$OUT"; then
  pass "AC4 (floor): a red chain on a CLEAN default branch still BLOCKS — no baseline excuse on main"
else
  fail "AC4 (floor): red on a clean default branch was excused — that is the SEC-1 main-deferral fail-open under a new name"
fi
run_hook "$R4" >/dev/null; run_hook "$R4" >/dev/null
if [ -f "$R4/.quetrex/ESCALATION" ]; then
  pass "AC4 (floor): the self-heal cap on the default branch still escalates"
else
  fail "AC4 (floor): the cap no longer writes ESCALATION on the default branch"
fi

# --------------------------------------------------------------------------
# AC6 — a pre-existing red is not a green: it must not clear a prior
# ESCALATION nor reset the self-heal counter.
# --------------------------------------------------------------------------
R6="$TMPROOT/ac6"; mk_repo "$R6" missing; branch_off "$R6" claude/FIX-6
echo 'x' > "$R6/app.js"; commit_all "$R6" "feat: slice"
printf '{"sha":"%s","branch":"claude/FIX-6","reason":"prior"}' \
  "$(git -C "$R6" rev-parse HEAD)" > "$R6/.quetrex/ESCALATION"
echo 2 > "$R6/.quetrex/verify-attempts"
run_hook "$R6" >/dev/null
if [ -f "$R6/.quetrex/ESCALATION" ]; then
  pass "AC6: a pre-existing red does not clear a standing ESCALATION"
else
  fail "AC6: a pre-existing red cleared a standing ESCALATION — it was treated as a green"
fi
if [ "$(attempts_of "$R6")" = "2" ]; then
  pass "AC6: a pre-existing red leaves the self-heal counter untouched"
else
  fail "AC6: self-heal counter moved to $(attempts_of "$R6") — expected an untouched 2"
fi

# --------------------------------------------------------------------------
# AC7 — the ledger tells the truth: the real non-zero exit, marked
# preexisting:true, never exit 0.
# --------------------------------------------------------------------------
LED="$R1/.quetrex/verify-ledger.jsonl"
if [ -f "$LED" ] && jq -e --arg c "$CHAIN_CMD" \
     'select(.cmd == $c) | (.preexisting == true) and (.exit != 0) and (.exit != null)' \
     "$LED" >/dev/null 2>&1; then
  pass "AC7: the ledger records the pre-existing failure with its real non-zero exit and preexisting:true"
else
  fail "AC7: no ledger line marking the pre-existing red with a real non-zero exit"
fi
if [ -f "$LED" ] && jq -e --arg c "$CHAIN_CMD" 'select(.cmd == $c) | .exit == 0' "$LED" >/dev/null 2>&1; then
  fail "AC7: a pre-existing red was recorded as exit 0 — that would let merge-gate read it as proof"
else
  pass "AC7: a pre-existing red is never recorded as a green"
fi

# Self-referential completion sentinel: test/run-all.sh requires a line naming
# THIS file, so a suite that dies half-way cannot be scored on the "ok -" lines
# it managed to print before it died.
echo
echo "verify-gate-baseline-ratchet.test.sh: $([ "$FAIL" -eq 0 ] && echo "all assertions passed" || echo "FAILURES above")"
exit "$FAIL"
