#!/usr/bin/env bash
# test/merge-gate-verdict-pin-order.test.sh — GATE 2 PIN, CHECKED BEFORE THE
# VERDICT (AC8, ONE-COPY).
#
# Run: bash test/merge-gate-verdict-pin-order.test.sh
#
# THE DEFECT THIS CLOSES. GATE 2 used to run the verdict `case` FIRST and only
# pin the sha to HEAD in the AUTO_MERGE arm. A stale (non-AUTO_MERGE) verdict
# was denied by quoting ITS OWN value as the cause — "review verdict is
# 'REWORK'", "review verdict is 'ESCALATE_HUMAN'", "legacy 'APPROVE'" — even
# when the review-gate never actually evaluated the current HEAD at all. That
# told the agent to go fix "confirmed findings" a reviewer never confirmed
# against this commit.
#
# THE FIX changes NO allow path — every non-AUTO_MERGE verdict denied before
# and still denies. It only corrects the REASON: the sha-pin check now runs
# BEFORE the verdict is even consulted, so a stale verdict artifact denies
# with the SAME reason ("the review-gate never ran on this commit") no
# matter what value it happens to record.

set -uo pipefail

# ONE-COPY round 2 hygiene (reviewer-reported): this session's ambient
# environment can carry QUETREX_UNLOCK_FLOOR=1 from unrelated prior work in
# the SAME shell (it is not cleared between unrelated commands), and every
# floor script honors it as the intentional operator unlock. A test that
# asserts a floor DENY without isolating this var silently asserts nothing
# once that happens - unset it here so this file's own "locked" assertions
# are never contaminated by ambient state; any assertion that WANTS the
# unlocked case still sets QUETREX_UNLOCK_FLOOR=1 explicitly on that one
# invocation, which overrides this.
unset QUETREX_UNLOCK_FLOOR

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MERGE_GATE="${QX_MERGE_GATE_HOOK:-$REPO_ROOT/plugins/quetrex-factory/scripts/merge-gate.sh}"

[ -f "$MERGE_GATE" ] || { echo "FAIL: hook not found at $MERGE_GATE"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq is not installed — merge-gate.sh is jq-mandatory, nothing to test"; exit 0; }

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

F="$(mktemp -d "${TMPDIR:-/tmp}/qx-verdict-pin.XXXXXX")"
cleanup() { rm -rf "$F"; }
trap cleanup EXIT

git -C "$F" init -q -b main
git -C "$F" config user.email t@e.com; git -C "$F" config user.name t
echo one > "$F/f.txt"; git -C "$F" add f.txt; git -C "$F" commit -q -m c1
STALE_SHA="$(git -C "$F" rev-parse HEAD)"          # the sha the (stale) verdict will record
echo two > "$F/f.txt"; git -C "$F" add f.txt; git -C "$F" commit -q -m c2   # a REAL code change since STALE_SHA
HEAD_SHA="$(git -C "$F" rev-parse HEAD)"
mkdir -p "$F/.quetrex"
printf '{"branchPrefix":"claude/"}' > "$F/.quetrex/project.json"

run_mg() {
  local payload
  payload="$(jq -cn --arg cwd "$F" '{tool_input:{command:"git push origin main"},cwd:$cwd}')"
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$F" bash "$MERGE_GATE" 2>&1
}
reason_of() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null; }

write_verdict() {  # write_verdict <verdict> <sha>
  jq -cn --arg v "$1" --arg sha "$2" '{verdict:$v, sha:$sha}' > "$F/.quetrex/review-verdict.json"
}

# --- AC8: 5 verdict values, all pinned to the SAME stale sha ---------------
for V in REWORK ESCALATE_HUMAN APPROVE BOGUS_VALUE AUTO_MERGE; do
  write_verdict "$V" "$STALE_SHA"
  OUT="$(run_mg)"
  REASON="$(reason_of "$OUT")"
  if printf '%s' "$REASON" | grep -q 'never ran on this commit'; then
    if printf '%s' "$REASON" | grep -qE "review verdict is '(REWORK|ESCALATE_HUMAN)'|legacy 'APPROVE'"; then
      notok "AC8 ($V): denied for staleness but STILL quoted the stale verdict value as the cause: [$REASON]"
    else
      ok "AC8 ($V): stale verdict ($STALE_SHA != HEAD $HEAD_SHA) denies with the generic 'never ran on this commit' reason, verdict value never quoted"
    fi
  else
    notok "AC8 ($V): stale review-verdict.json (sha=$STALE_SHA, HEAD=$HEAD_SHA) did not deny with 'never ran on this commit': [$OUT]"
  fi
done

# --- AC8: the happy path is unaffected — sha PINNED to HEAD, AUTO_MERGE ----
# still produces 0 deny decisions FROM GATE 2 (a later gate may still deny
# for missing artifacts this fixture never populated — e.g. security
# findings or the verify ledger — but that is a DIFFERENT gate's concern;
# GATE 2's own stale-pin message must not appear).
write_verdict "AUTO_MERGE" "$HEAD_SHA"
OUT="$(run_mg)"
REASON="$(reason_of "$OUT")"
if printf '%s' "$REASON" | grep -q 'never ran on this commit'; then
  notok "AC8 (happy path): AUTO_MERGE pinned to HEAD was denied by GATE 2 as stale — new block on a clean pin: [$OUT]"
else
  ok "AC8 (happy path): AUTO_MERGE pinned to HEAD — GATE 2 emits 0 deny decisions (any later denial is a different gate's concern, e.g. missing artifacts this fixture never populated)"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "merge-gate-verdict-pin-order.test.sh: all checks passed"
else
  echo "merge-gate-verdict-pin-order.test.sh: FAILURES above"
fi
exit "$FAIL"
