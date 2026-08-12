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

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); echo "ok - $1"; }
notok() { FAIL=$((FAIL+1)); echo "NOT OK - $1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Lift GATE 3's real red-set expression out of merge-gate.sh so this tests the SHIPPED logic,
# not a paraphrase of it. A paraphrase is how a test ends up proving its own copy correct.
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

# --- ASSERTION 3c: a red at a DESCRIBING ANCESTOR is not erased either ---------
# Round 7. ASSERTION 3b scoped the guard to $head — but GATE 3 treats an artifact-only-range
# ANCESTOR as describing too, so a red there was still erased by a later skip (case E), and a
# clean skip at $head shadowed it entirely without the bash walk ever seeing it (case G).
# Reachable without an adversary: the artifact-only hatch fires on any commit touching nothing
# outside .quetrex/, which is the ordinary /quetrex:init shape — this repo has two in its last
# 300 commits. Cloud build goes red at X, an init touch-up lands an artifact-only commit, a
# fresh worktree carries no untracked .env.local, one Stop firing appends the skip.
#
# KNOWN INADEQUATE — recorded, not hidden. These drive the jq expression ONLY, and I verified
# they pass against the pre-fix gate as well, so they do NOT discriminate the fix from the bug.
# The artifact-only-range logic lives in the bash walk (merge-gate.sh ~1738-1753) that jq never
# reaches, so cases E and G can only be settled by executing the REAL hook with a PR-merge
# payload, the way test/verify-gate.test.sh drives verify-gate.sh. Until that exists, the fix
# above rests on the reviewer's hook-level reproduction, not on this file. Do not read these
# two lines as coverage.
for case in "anc:1|anc:skip|E red-then-skip at an ancestor" \
            "anc:1|h1:skip|G red at an ancestor, skip at HEAD"; do
  led="${case%%|*}"; rest="${case#*|}"; second="${rest%%|*}"; label="${rest#*|}"
  : > "$TMP/anc.jsonl"
  for part in "$led" "$second"; do
    sha="${part%%:*}"; kind="${part#*:}"
    if [ "$kind" = "skip" ]; then
      printf '{"cmd":"npm run build","sha":"%s","exit":null,"skipped":true,"skipReason":"requiredEnv","missingEnv":"X"}\n' "$sha" >> "$TMP/anc.jsonl"
    else
      printf '{"cmd":"npm run build","sha":"%s","exit":%s}\n' "$sha" "$kind" >> "$TMP/anc.jsonl"
    fi
  done
  OUT="$(red "$TMP/anc.jsonl" '["npm run build"]')"
  if printf '%s' "$OUT" | grep -q 'npm run build'; then
    ok "ASSERTION 3c: $label — stays a candidate, the walk decides"
  else
    notok "ASSERTION 3c: $label — the skip ERASED a genuine failure and the command left the gate green (red: $OUT)"
  fi
done

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
