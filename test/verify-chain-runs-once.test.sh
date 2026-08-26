#!/usr/bin/env bash
# test/verify-chain-runs-once.test.sh — the full verify chain in .quetrex/verify.json
# must run EXACTLY ONCE per pipeline, by QA, which appends sha-pinned lines to
# .quetrex/verify-ledger.jsonl. reviewer.md and git-workflow.md must NOT re-run the
# whole chain themselves — they trust the ledger because it is sha-pinned: for every
# command in verify.json's `.verify[]`, its MOST RECENT ledger line must carry
# `exit == 0` AND `sha == HEAD`. A stage may run ONLY the specific commands that lack
# a green line at HEAD (never the whole chain for its own sake), and must append its
# own sha-pinned lines for whatever it ran.
#
# THE MEASURED WASTE (Glen, 2026-08-26, on top of PR #127). Before this fix, the
# multi-minute verify chain ran three times per pipeline run — once each in QA,
# reviewer, and git-workflow — pure waste, because reviewer.md and git-workflow.md's
# contracts both said "re-run the chain yourself" regardless of what the ledger
# already proved at HEAD.
#
# This test is a mechanical grep contract over the two shipped agent files (never a
# paraphrase): it proves the old "re-run unconditionally" wording is gone, and the
# new sha-pinned-ledger-trust wording (and machinery) is present, without regressing
# the existing "never re-point the verdict" anchoring rule.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REVIEWER="$ROOT/plugins/quetrex-factory/agents/reviewer.md"
GITWORKFLOW="$ROOT/plugins/quetrex-factory/agents/git-workflow.md"

[ -f "$REVIEWER" ] || { echo "FAIL: reviewer.md not found at $REVIEWER"; exit 1; }
[ -f "$GITWORKFLOW" ] || { echo "FAIL: git-workflow.md not found at $GITWORKFLOW"; exit 1; }

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

# =============================================================================
# (a) reviewer.md must contain NO line instructing an unconditional re-run of the
#     whole verify chain.
# =============================================================================
BAD_REVIEWER_LINES="$(grep -inE 're-run the (verify )?chain yourself|re-run the verify chain and require|Prove green yourself' "$REVIEWER")"
if [ -z "$BAD_REVIEWER_LINES" ]; then
  ok "reviewer.md contains no 're-run the chain yourself' / 're-run the verify chain and require' / 'Prove green yourself' wording"
else
  notok "reviewer.md still instructs an unconditional chain re-run: $BAD_REVIEWER_LINES"
fi

# =============================================================================
# (b) git-workflow.md must contain NO line describing the old full-chain re-run.
# =============================================================================
BAD_GW_LINES="$(grep -inE 're-run the FULL|Full-chain sha-pin re-verification|proving it again at the actual HEAD' "$GITWORKFLOW")"
if [ -z "$BAD_GW_LINES" ]; then
  ok "git-workflow.md contains no 're-run the FULL' / 'Full-chain sha-pin re-verification' / 'proving it again at the actual HEAD' wording"
else
  notok "git-workflow.md still describes the old full-chain re-run: $BAD_GW_LINES"
fi

# =============================================================================
# (c) reviewer.md's verify_green block (Step 3) must reference BOTH
#     verify-ledger.jsonl and a HEAD-sha comparison, within the Step 3 section.
# =============================================================================
STEP3_BLOCK="$(awk '
  /^## Step 3/ { infield=1 }
  /^## Step 4/ { infield=0 }
  infield { print }
' "$REVIEWER")"

if [ -z "$STEP3_BLOCK" ]; then
  notok "reviewer.md: could not extract a '## Step 3' ... '## Step 4' section at all — the file structure changed unexpectedly"
else
  ok "reviewer.md: extracted the Step 3 section for the verify_green assertion"
fi

if printf '%s' "$STEP3_BLOCK" | grep -q 'verify-ledger.jsonl'; then
  ok "reviewer.md Step 3 references verify-ledger.jsonl"
else
  notok "reviewer.md Step 3 never references verify-ledger.jsonl — verify_green is not reading the ledger at all"
fi

if printf '%s' "$STEP3_BLOCK" | grep -qE 'HEAD_SHA|sha == ?\$?HEAD|sha == HEAD'; then
  ok "reviewer.md Step 3 references a HEAD_SHA / sha==HEAD comparison"
else
  notok "reviewer.md Step 3 never compares a ledger line's sha to HEAD — the sha-pin cannot be enforced"
fi

# =============================================================================
# (d) git-workflow.md's §2a must contain the phrase "NOT re-run" (case-insensitive).
# =============================================================================
if grep -qiE 'not re-run' "$GITWORKFLOW"; then
  ok "git-workflow.md contains 'NOT re-run' (or 'not re-run')"
else
  notok "git-workflow.md never states the chain is NOT re-run here — §2a's new framing is missing"
fi

# =============================================================================
# (e) POSITIVE CONTROL: both files still forbid re-pointing the verdict/ledger.
#     This proves assertions (a)/(b) above are not just widening the gate open —
#     the surrounding anchoring discipline must still be intact.
# =============================================================================
if grep -qi 'never re-point the verdict' "$GITWORKFLOW"; then
  ok "git-workflow.md still forbids re-pointing the verdict (positive control)"
else
  notok "git-workflow.md no longer forbids re-pointing the verdict — the anchoring discipline regressed"
fi

if grep -qi 'never re-point\|re-review — never re-pin' "$REVIEWER"; then
  ok "reviewer.md still forbids re-pinning a stale verdict without re-review (positive control)"
else
  notok "reviewer.md no longer forbids re-pinning without re-review — the anchoring discipline regressed"
fi

echo
echo "verify-chain-runs-once.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
