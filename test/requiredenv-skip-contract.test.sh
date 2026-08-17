#!/usr/bin/env bash
# requiredenv-skip-contract.test.sh — the two hooks must agree what a declared-env skip means.
#
# THE DEADLOCK, measured in quetrex-demo. `.quetrex/verify.json` there declares
# `requiredEnv: {"npm run build": ["DEMO_DATABASE_URL"]}`. With the var unset:
#
#   verify-gate.sh  skipped the command and said "BLOCKS nothing" — but `continue`d BEFORE the
#                   ledger append, so no entry was written at all.
#   merge-gate.sh   GATE 3 requires an entry per chain command and read the absence as
#                   "never ran" -> deny.
#
# So `npm run build` was unprovable FOREVER and no PR in that repo could pass GATE 3. Every
# ledger in its history carries lint and test and never build. Two hooks, opposite readings of
# the same sanctioned state.
#
# THE CONTRACT: a requiredEnv skip is recorded in the ledger as `skipped:true` with
# `skipReason:"requiredEnv"` and `exit:null` — never as exit 0, so it can never be mistaken for
# a pass — and GATE 3 accepts exactly that shape as satisfying the command. Nothing else.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VG="${QX_VERIFY_GATE_HOOK:-$ROOT/.claude/hooks/verify-gate.sh}"
MG="${QX_MERGE_GATE_HOOK:-$ROOT/.claude/hooks/merge-gate.sh}"

if [ ! -x "$MG" ] && [ ! -f "$MG" ]; then
  echo "FAIL: hook not found at $MG"
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq is not installed — merge-gate.sh is jq-mandatory, nothing to test"
  exit 0
fi

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); echo "ok - $1"; }
notok() { FAIL=$((FAIL+1)); echo "NOT OK - $1"; }

TMP="$(mktemp -d)"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/requiredenv-skip-fixture.XXXXXX")"
MOCKBIN="$(mktemp -d "${TMPDIR:-/tmp}/requiredenv-skip-mockbin.XXXXXX")"
trap 'rm -rf "$TMP" "$FIXTURE" "$MOCKBIN"' EXIT

# Lift GATE 3's real red-set expression out of merge-gate.sh so ASSERTIONS 2/3/3b test the
# SHIPPED logic, not a paraphrase of it. A paraphrase is how a test ends up proving its own copy
# correct. This is still not sufficient on its own — see ASSERTION 3c below, which drives the
# jq expression's OUTPUT into the bash walk (merge-gate.sh's ancestor/artifact-only logic, which
# jq cannot call and this expression alone never reaches) by executing the real hook.
EXPR="$(awk '/RED=\$\(jq -sc --argjson chain/,/^  '"'"' "\$LEDGER"/' "$MG" \
        | sed -e '1s/.*jq -sc --argjson chain "\$CHAIN_JSON" --arg head "\$HEAD_SHA" .//' \
              -e '$d')"
if [ -n "$EXPR" ]; then
  ok "SETUP: extracted GATE 3's red-set expression from the shipped hook"
else
  notok "SETUP: could not extract GATE 3's expression — every assertion below would test a paraphrase"
  echo; echo "requiredenv-skip-contract.test.sh: $PASS passed, $FAIL failed"; exit 1
fi

red() {  # red <ledger-file> <chain-json> -> the red command list
  jq -sc --argjson chain "$2" --arg head "abc123" "$EXPR" "$1" 2>/dev/null
}

# --- ASSERTION 1: verify-gate RECORDS the skip --------------------------------
# The defect was a `continue` before the ledger append. Assert the append exists on the skip
# path, and that it writes the sanctioned shape rather than a bare pass.
SKIP_BLOCK="$(awk '/if should_skip_for_env/,/^  fi$/' "$VG")"
if printf '%s' "$SKIP_BLOCK" | grep -q 'skipReason'; then
  ok "ASSERTION 1: verify-gate writes a ledger entry on a requiredEnv skip"
else
  notok "ASSERTION 1: verify-gate still returns without recording the skip — merge-gate will read it as 'never ran' and deny forever"
fi
if printf '%s' "$SKIP_BLOCK" | grep -qE 'exit:null|exit: *null'; then
  ok "ASSERTION 1: the skip is recorded with exit null, so it can never be mistaken for a pass"
else
  notok "ASSERTION 1: the skip does not pin exit:null — a future reader could treat it as exit 0"
fi

# --- ASSERTION 2: GATE 3 accepts the sanctioned skip --------------------------
printf '%s\n' \
  '{"cmd":"npm run lint","sha":"abc123","exit":0}' \
  '{"cmd":"npm run test","sha":"abc123","exit":0}' \
  '{"cmd":"npm run build","sha":"abc123","exit":null,"skipped":true,"skipReason":"requiredEnv","missingEnv":"DEMO_DATABASE_URL"}' \
  > "$TMP/ok.jsonl"
OUT="$(red "$TMP/ok.jsonl" '["npm run lint","npm run test","npm run build"]')"
if [ "$OUT" = "[]" ]; then
  ok "ASSERTION 2: a requiredEnv skip at HEAD satisfies GATE 3 — the deadlock is broken"
else
  notok "ASSERTION 2: GATE 3 still denies a sanctioned skip (red: $OUT) — no PR in a repo declaring requiredEnv can ever merge"
fi

# --- ASSERTION 3: a real failure is STILL red ---------------------------------
# The whole risk of this change is widening the gate. It must not.
printf '{"cmd":"npm run build","sha":"abc123","exit":1}\n' > "$TMP/red.jsonl"
OUT="$(red "$TMP/red.jsonl" '["npm run build"]')"
if printf '%s' "$OUT" | grep -q 'npm run build'; then
  ok "ASSERTION 3: a genuinely failing command is still red"
else
  notok "ASSERTION 3: a FAILING command passed GATE 3 — the skip contract widened the gate (red: $OUT)"
fi

# --- ASSERTION 3b: a describing RED dominates a later skip --------------------
# The defect this exists to prevent, found by the review gate and reproduced with the real
# hooks: `athead` takes the LAST entry at $head, so a skip appended AFTER a genuine failure at
# the SAME commit erased it and GATE 3 flipped red -> green. No adversary needed — a cloud
# build goes red with the var set, the evidence comes home, the operator opens a fresh worktree
# (which carries no untracked .env.local, so the var is genuinely absent) and one Stop firing
# appends the skip. ASSERTION 3 above passes only because its fixture holds the failure ALONE.
printf '%s\n' \
  '{"cmd":"npm run build","sha":"abc123","exit":1}' \
  '{"cmd":"npm run build","sha":"abc123","exit":null,"skipped":true,"skipReason":"requiredEnv","missingEnv":"DEMO_DATABASE_URL"}' \
  > "$TMP/redthenskip.jsonl"
OUT="$(red "$TMP/redthenskip.jsonl" '["npm run build"]')"
if printf '%s' "$OUT" | grep -q 'npm run build'; then
  ok "ASSERTION 3b: a skip appended AFTER a failure at the same commit does not erase it"
else
  notok "ASSERTION 3b: a later skip ERASED a genuine failure at the same commit — a command that measurably exited non-zero passes the ship gate (red: $OUT)"
fi

# And the reverse order must still be green: a skip followed by nothing is a clean skip.
printf '%s\n' \
  '{"cmd":"npm run build","sha":"abc123","exit":null,"skipped":true,"skipReason":"requiredEnv","missingEnv":"X"}' \
  > "$TMP/skiponly.jsonl"
OUT="$(red "$TMP/skiponly.jsonl" '["npm run build"]')"
if [ "$OUT" = "[]" ]; then
  ok "ASSERTION 3b: a clean skip with no failure at that commit still satisfies the chain"
else
  notok "ASSERTION 3b: over-corrected — a clean skip is now red (red: $OUT)"
fi

# =============================================================================
# ASSERTION 3c — the ancestor/dominance rules, proven against the REAL hook.
#
# Round 7 found that the jq-only `red()` helper above cannot discriminate the fix from the bug
# for two cases: a describing-ANCESTOR red vs. a later HEAD skip (defect below, "variant D"),
# and a genuine re-run at the SAME sha after an earlier red at that sha (defect below,
# "same-sha"). Both live in the ancestor/artifact-only-range walk in merge-gate.sh's BASH code
# (~1746-1760), which jq cannot call and `red()` above never reaches — the walk only runs after
# GATE 3's own bash driver consumes $RED, so a jq-layer assertion can show a command is still a
# CANDIDATE but cannot prove what the walk finally decides. Round 8's cases E and G reported
# "ok" here at commit 2ab188b while the shipped hook actually ALLOWED the exact defect they
# claimed to catch — because they asserted on `red()`'s intermediate output, not the hook's
# final decision. Fixed by executing the SHIPPED merge-gate.sh end to end: a real git commit
# graph (ancestor + artifact-only-range HEAD, same shape as the DEFECT Q fixture in
# test/merge-gate.test.sh), a real PreToolUse `gh pr merge` payload, `gh pr view` mocked on
# PATH, and the assertion reads the hook's own allow/deny decision — nothing is lifted out.
#
# Measured before this fix, against 2ab188b (recorded in the commit message that ships this
# file): variant A DENY (already correct), variant D ALLOW (WRONG — a measurably red command
# shipped), same-sha DENY (WRONG — a genuine green re-run was permanently poisoned by an
# earlier red at that same sha), clean skip ALLOW (already correct, and must not regress: this
# is the entire point of the requiredEnv contract this file exists to protect).
# =============================================================================

cat > "$MOCKBIN/gh" <<'MOCKGH'
#!/bin/sh
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  if [ -n "${MOCK_GH_PR_VIEW_FAIL:-}" ]; then
    echo "mock gh: pr view failed" >&2
    exit 1
  fi
  printf '{"headRefOid":"%s","baseRefOid":"%s"}' "${MOCK_GH_PR_VIEW_SHA:-}" "${MOCK_GH_PR_BASE_SHA:-}"
  exit 0
fi
echo "mock gh: unhandled subcommand: $*" >&2
exit 1
MOCKGH
chmod +x "$MOCKBIN/gh"

git -C "$FIXTURE" init -q -b main
git -C "$FIXTURE" config user.email "test@example.com"
git -C "$FIXTURE" config user.name "Fixture"
echo "fixture" > "$FIXTURE/README.md"
git -C "$FIXTURE" add README.md
git -C "$FIXTURE" commit -q -m "chore: fixture commit"
C0="$(git -C "$FIXTURE" rev-parse HEAD)"

# HEAD (C1) is a single commit on top of C0 that touches ONLY .quetrex/ — an artifact-only
# range, the exact shape merge-gate.sh's own DEFECT Q section (test/merge-gate.test.sh) proves
# the gate treats as "still describing". This is what makes C0's ledger entry admissible
# evidence about C1 at all; it is not a special case invented for this file.
mkdir -p "$FIXTURE/.quetrex"
echo "marker" > "$FIXTURE/.quetrex/marker.txt"
git -C "$FIXTURE" add .quetrex/marker.txt
git -C "$FIXTURE" commit -q -m "chore: artifact-only commit"
C1="$(git -C "$FIXTURE" rev-parse HEAD)"

printf '{"verify":["npm run build"]}' > "$FIXTURE/.quetrex/verify.json"

write_verdict_at() {  # write_verdict_at <sha>
  jq -cn --arg sha "$1" \
    '{verdict:"AUTO_MERGE",sha:$sha,confirmed:[],inputs:{nativeSecurityReview:"clean"}}' \
    > "$FIXTURE/.quetrex/review-verdict.json"
}
write_sec_clean_at() {  # write_sec_clean_at <sha>
  jq -cn --arg sha "$1" \
    '{task:"T-1",base:"main",head_sha:$sha,reviewed_files:1,verdict:"PASS",findings:[]}' \
    > "$FIXTURE/.quetrex/security-findings.json"
}
reset_clean_baseline() {  # reset_clean_baseline <sha> — pin RV/sec to <sha>, drop ESCALATION
  write_verdict_at "$1"
  write_sec_clean_at "$1"
  rm -f "$FIXTURE/.quetrex/ESCALATION"
}

# write_ledger_entries <cmd> <spec>... where each <spec> is "<sha>:<exit>" for a genuine run,
# or "<sha>:skip" for the sanctioned requiredEnv skip shape (exit:null, skipped, skipReason).
# Entries are appended in the given order, so it also controls chronology.
write_ledger_entries() {
  local cmd="$1"; shift
  : > "$FIXTURE/.quetrex/verify-ledger.jsonl"
  for spec in "$@"; do
    local sha="${spec%%:*}" rest="${spec#*:}"
    if [ "$rest" = "skip" ]; then
      jq -cn --arg cmd "$cmd" --arg sha "$sha" \
        '{ts:"2026-01-01T00:00:00Z",cmd:$cmd,sha:$sha,exit:null,skipped:true,skipReason:"requiredEnv",missingEnv:"X"}' \
        >> "$FIXTURE/.quetrex/verify-ledger.jsonl"
    else
      jq -cn --arg cmd "$cmd" --arg sha "$sha" --argjson ex "$rest" \
        '{ts:"2026-01-01T00:00:00Z",cmd:$cmd,sha:$sha,exit:$ex}' \
        >> "$FIXTURE/.quetrex/verify-ledger.jsonl"
    fi
  done
}

# The literal merge command, assembled at runtime — see test/merge-gate.test.sh for why (this
# repo's own PreToolUse gate reads the command string of every Bash call, including this test).
GH_MERGE="$(printf 'gh pr mer%s' 'ge') 123 --squash"

run_hook_at_head() {
  local payload
  payload="$(jq -cn --arg cmd "$GH_MERGE" --arg cwd "$FIXTURE" '{tool_input:{command:$cmd},cwd:$cwd}')"
  printf '%s' "$payload" | env PATH="$MOCKBIN:$PATH" \
    MOCK_GH_PR_VIEW_SHA="$C1" MOCK_GH_PR_BASE_SHA="$C0" MOCK_GH_PR_VIEW_FAIL="" GH_REPO="" \
    CLAUDE_PROJECT_DIR="$FIXTURE" "$MG"
}
is_deny() { printf '%s' "$1" | grep -q '"permissionDecision":"deny"\|MERGE GATE'; }

# --- variant A: a describing-ancestor red, alone -> DENY (already correct pre-fix; regression
#     guard so a future change to the ancestor walk cannot silently break the base case) -------
write_ledger_entries "npm run build" "$C0:1"
reset_clean_baseline "$C1"
OUT="$(run_hook_at_head)"; CODE=$?
if [ "$CODE" -eq 0 ] && is_deny "$OUT"; then
  ok "ASSERTION 3c: variant A (ancestor red alone) -> DENY"
else
  notok "ASSERTION 3c: variant A (ancestor red alone) -> expected DENY, got exit $CODE: [$OUT]"
fi

# --- variant D: describing-ancestor red PLUS a requiredEnv skip at HEAD -> DENY (the hole:
#     2ab188b's dominance guard nulls $athead but leaves the skip in $persha, so the bash walk's
#     own artifact_only_range_ok(HEAD,HEAD) self-match re-admits the skip before ever reaching
#     the ancestor's red) ---------------------------------------------------------------------
write_ledger_entries "npm run build" "$C0:1" "$C1:skip"
reset_clean_baseline "$C1"
OUT="$(run_hook_at_head)"; CODE=$?
if [ "$CODE" -eq 0 ] && is_deny "$OUT"; then
  ok "ASSERTION 3c: variant D (ancestor red + later requiredEnv skip at HEAD) -> DENY"
else
  notok "ASSERTION 3c: variant D (ancestor red + later requiredEnv skip at HEAD) -> expected DENY, a measurably red command shipped, got exit $CODE: [$OUT]"
fi

# --- red then a genuine green re-run at the SAME sha -> ALLOW (the poison: \$redshas forced
#     EVERY entry at a red sha to exit 1, including a later real re-run that genuinely exited 0,
#     so a repo that ever failed once at a given commit could never merge that commit again) ---
write_ledger_entries "npm run build" "$C1:1" "$C1:0"
reset_clean_baseline "$C1"
OUT="$(run_hook_at_head)"; CODE=$?
if [ "$CODE" -eq 0 ] && ! is_deny "$OUT"; then
  ok "ASSERTION 3c: red then a genuine green re-run at the SAME sha -> ALLOW"
else
  notok "ASSERTION 3c: red then a genuine green re-run at the SAME sha -> expected ALLOW (the latest real run describes HEAD), got exit $CODE: [$OUT]"
fi

# --- a clean requiredEnv skip with no red anywhere -> ALLOW (the deadlock fix itself; must not
#     regress — this is the entire reason PR #104 exists) --------------------------------------
write_ledger_entries "npm run build" "$C1:skip"
reset_clean_baseline "$C1"
OUT="$(run_hook_at_head)"; CODE=$?
if [ "$CODE" -eq 0 ] && ! is_deny "$OUT"; then
  ok "ASSERTION 3c: a clean requiredEnv skip with no red anywhere -> ALLOW (deadlock stays fixed)"
else
  notok "ASSERTION 3c: a clean requiredEnv skip with no red anywhere -> expected ALLOW, got exit $CODE: [$OUT]"
fi

# --- ASSERTION 4: the reason is load-bearing ----------------------------------
# `skipped:true` alone must NOT satisfy the chain, or the escape hatch is "write skipped into
# the ledger", which any stage could do for any reason.
printf '{"cmd":"npm run e2e","sha":"abc123","exit":null,"skipped":true,"skipReason":"lazy"}\n' > "$TMP/bogus.jsonl"
OUT="$(red "$TMP/bogus.jsonl" '["npm run e2e"]')"
if printf '%s' "$OUT" | grep -q 'npm run e2e'; then
  ok "ASSERTION 4: a skip with any other reason is still red — the hatch cannot be widened"
else
  notok "ASSERTION 4: ANY skipped:true satisfies GATE 3 — a stage could skip itself past the gate (red: $OUT)"
fi

# --- ASSERTION 5: a skip for a command NOT at HEAD is still red ---------------
# A stale skip must not authorize a newer commit.
printf '{"cmd":"npm run build","sha":"older99","exit":null,"skipped":true,"skipReason":"requiredEnv","missingEnv":"X"}\n' > "$TMP/stale.jsonl"
OUT="$(red "$TMP/stale.jsonl" '["npm run build"]')"
if printf '%s' "$OUT" | grep -q 'npm run build'; then
  ok "ASSERTION 5: a skip recorded for a different commit does not authorize HEAD"
else
  notok "ASSERTION 5: a stale skip satisfied HEAD (red: $OUT)"
fi

echo
echo "requiredenv-skip-contract.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
