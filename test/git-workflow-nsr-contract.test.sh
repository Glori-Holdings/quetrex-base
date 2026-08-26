#!/usr/bin/env bash
# test/git-workflow-nsr-contract.test.sh — git-workflow.md's NSR gate must accept an
# `errored`/`not_run`/`not_available_in_env` nativeSecurityReview when the INDEPENDENT
# security-reviewer artifact (.quetrex/security-findings.json) affirmatively proves HEAD
# clean, matching the route merge-gate.sh's GATE 2b already implements
# (plugins/quetrex-factory/scripts/merge-gate.sh's sec_artifact_state()) and reviewer.md's
# independence_ok (route 2).
#
# THE MEASURED DEFECT (QDM-6, Glori-Holdings/quetrex-demo, 2026-08-26). A cloud build
# reached HEAD c26bc72 with qa-report PASS, review-verdict AUTO_MERGE pinned to HEAD,
# security-findings PASS, and the chain re-proved green — and git-workflow REFUSED to open
# the PR anyway: state.json.git_workflow_reason recorded
#   "review-verdict.json .inputs.nativeSecurityReview = \"errored\", not clean|issues"
# because the native `/security-review` SlashCommand does not exist in cloud sessions. That
# rule made EVERY cloud build unshippable, and the card sat at in_progress forever.
#
# THE FIX. git-workflow.md's NSR case (the fenced bash block anchored on
# `RV="$ROOT/.quetrex/review-verdict.json"`) now accepts a non-native NSR value ONLY when
# .quetrex/security-findings.json independently proves the EXACT HEAD commit clean: it must
# exist, parse, carry a `.head_sha` (or `.sha`) equal to HEAD, and record zero open Critical
# findings. Anything short of that still refuses, with the original message.
#
# THIS TEST proves both halves by EXECUTING the real fenced snippet (never a paraphrase of
# it) against a real git fixture:
#   1. FAIL-FIRST: the pre-fix contract at commit 1032770 refuses the exact QDM-6 shape —
#      confirming the defect was real before this fix existed.
#   2. The current (working-tree) contract allows that same shape, and still refuses when
#      the independent artifact is missing, stale, unpinned, or carries an open Critical —
#      i.e. the gate was not simply widened open.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GWMD="$ROOT/plugins/quetrex-factory/agents/git-workflow.md"
PREFIX_SHA="1032770"

[ -f "$GWMD" ] || { echo "FAIL: git-workflow.md not found at $GWMD"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq is not installed — this contract is jq-mandatory"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git is not installed"; exit 0; }

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

# --- extract the NSR-bearing fenced bash block from a git-workflow.md's content -------------
# Anchored on the RV= assignment line that opens Gate 4's block, which the NSR case lives
# inside of in both the pre-fix and post-fix contract. Content-anchored, not line-numbered,
# so it survives drift elsewhere in the file.
extract_block() {
  awk '
    /^```bash$/ { buf=""; next }
    /^```$/ {
      if (buf ~ /RV="\$ROOT\/\.quetrex\/review-verdict\.json"/) { print buf; exit }
      buf=""; next
    }
    { buf = buf $0 "\n" }
  '
}

OLD_CONTENT="$(git -C "$ROOT" show "${PREFIX_SHA}:plugins/quetrex-factory/agents/git-workflow.md" 2>/dev/null)"
if [ -z "$OLD_CONTENT" ]; then
  notok "SETUP: could not read git-workflow.md at $PREFIX_SHA — fail-first half cannot run"
  echo; echo "git-workflow-nsr-contract.test.sh: $PASS passed, $FAIL failed"; exit 1
fi
NEW_CONTENT="$(cat "$GWMD")"

OLD_BLOCK="$(printf '%s\n' "$OLD_CONTENT" | extract_block)"
NEW_BLOCK="$(printf '%s\n' "$NEW_CONTENT" | extract_block)"

if [ -n "$OLD_BLOCK" ]; then
  ok "SETUP: extracted the pre-fix ($PREFIX_SHA) NSR block from the shipped contract"
else
  notok "SETUP: could not extract the pre-fix NSR block — every assertion below would test a paraphrase"
fi
if [ -n "$NEW_BLOCK" ]; then
  ok "SETUP: extracted the current NSR block from the shipped contract"
else
  notok "SETUP: could not extract the current NSR block — every assertion below would test a paraphrase"
fi

if [ -z "$OLD_BLOCK" ] || [ -z "$NEW_BLOCK" ]; then
  echo; echo "git-workflow-nsr-contract.test.sh: $PASS passed, $FAIL failed"; exit 1
fi

# --- mechanical contract grep: the NEW block must reference security-findings.json ----------
if printf '%s' "$NEW_BLOCK" | grep -q 'security-findings.json'; then
  ok "CONTRACT: the current NSR block references .quetrex/security-findings.json"
else
  notok "CONTRACT: the current NSR block never mentions security-findings.json — route 2 (independent agent) is not wired at all"
fi
if printf '%s' "$OLD_BLOCK" | grep -q 'security-findings.json'; then
  notok "CONTRACT: the PRE-FIX block already referenced security-findings.json — the fail-first baseline is not actually pre-fix"
else
  ok "CONTRACT: the pre-fix block had no route-2 escape hatch at all (confirms the fail-first baseline)"
fi

# --- fixture: a real git repo, one commit, RV + SEC pinned to it ---------------------------
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/gwf-nsr-fixture.XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT
git -C "$FIXTURE" init -q -b main
git -C "$FIXTURE" config user.email "test@example.com"
git -C "$FIXTURE" config user.name "Fixture"
echo "fixture" > "$FIXTURE/README.md"
git -C "$FIXTURE" add README.md
git -C "$FIXTURE" commit -q -m "chore: fixture commit"
HEAD_SHA_FIXTURE="$(git -C "$FIXTURE" rev-parse HEAD)"
mkdir -p "$FIXTURE/.quetrex"
RV_FILE="$FIXTURE/.quetrex/review-verdict.json"
SEC_FILE="$FIXTURE/.quetrex/security-findings.json"

write_rv() {  # write_rv <sha> <nativeSecurityReview>
  jq -cn --arg sha "$1" --arg nsr "$2" \
    '{verdict:"AUTO_MERGE",sha:$sha,confirmed:[],inputs:{nativeSecurityReview:$nsr}}' \
    > "$RV_FILE"
}
write_sec_clean() {  # write_sec_clean <head_sha>
  jq -cn --arg sha "$1" \
    '{task:"QDM-6",base:"main",head_sha:$sha,reviewed_files:1,verdict:"PASS",findings:[]}' \
    > "$SEC_FILE"
}
write_sec_critical() {  # write_sec_critical <head_sha>
  jq -cn --arg sha "$1" \
    '{task:"QDM-6",base:"main",head_sha:$sha,findings:[{severity:"critical",status:"open",title:"x"}]}' \
    > "$SEC_FILE"
}

run_block() {  # run_block <block-text>
  env ROOT="$FIXTURE" SEC="$SEC_FILE" bash -c "$1" 2>&1
}
is_refused() { printf '%s' "$1" | grep -q 'REFUSED'; }

# =============================================================================
# PART 1 — FAIL-FIRST: reproduce the exact QDM-6 shape against the PRE-FIX contract.
# nativeSecurityReview="errored", review-verdict pinned to HEAD, security-findings.json
# pinned to the SAME HEAD with zero open Critical (route 2 fully satisfied). The pre-fix
# contract has no concept of route 2 at all, so it must still refuse.
# =============================================================================
write_rv "$HEAD_SHA_FIXTURE" "errored"
write_sec_clean "$HEAD_SHA_FIXTURE"
OUT="$(run_block "$OLD_BLOCK")"
if is_refused "$OUT"; then
  ok "FAIL-FIRST: pre-fix ($PREFIX_SHA) contract REFUSES the exact QDM-6 shape (errored NSR + clean pinned findings) — confirms the defect was real. Refusal: $(printf '%s' "$OUT" | grep REFUSED | head -n1)"
else
  notok "FAIL-FIRST: pre-fix ($PREFIX_SHA) contract did NOT refuse the QDM-6 shape — the fail-first baseline is broken, this test proves nothing. Output: $OUT"
fi

# =============================================================================
# PART 2 — the FIX: the same fixture must now be ALLOWED by the current contract.
# =============================================================================
OUT="$(run_block "$NEW_BLOCK")"
if is_refused "$OUT"; then
  notok "FIX: current contract still REFUSES the QDM-6 shape (errored NSR + clean pinned findings) — the fix did not land. Output: $OUT"
else
  ok "FIX: current contract ALLOWS the QDM-6 shape via the independent security-findings.json route"
fi

# =============================================================================
# PART 3 — regression guards: the gate must not have been simply widened open.
# =============================================================================

# 3a. errored NSR with NO security-findings.json at all -> still REFUSED.
rm -f "$SEC_FILE"
write_rv "$HEAD_SHA_FIXTURE" "errored"
OUT="$(run_block "$NEW_BLOCK")"
if is_refused "$OUT"; then
  ok "REGRESSION: errored NSR with no security-findings.json at all still REFUSES"
else
  notok "REGRESSION: errored NSR with NO independent artifact was ALLOWED — the gate was widened open unconditionally. Output: $OUT"
fi

# 3b. errored NSR with security-findings.json pinned to a DIFFERENT (stale) commit -> REFUSED.
write_sec_clean "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
OUT="$(run_block "$NEW_BLOCK")"
if is_refused "$OUT"; then
  ok "REGRESSION: errored NSR with a security-findings.json pinned to a DIFFERENT commit still REFUSES"
else
  notok "REGRESSION: a STALE independent findings artifact authorized HEAD — the sha pin is not enforced. Output: $OUT"
fi

# 3c. errored NSR with security-findings.json pinned to HEAD but an OPEN CRITICAL -> REFUSED.
write_sec_critical "$HEAD_SHA_FIXTURE"
OUT="$(run_block "$NEW_BLOCK")"
if is_refused "$OUT"; then
  ok "REGRESSION: errored NSR with an OPEN CRITICAL in the pinned findings still REFUSES"
else
  notok "REGRESSION: an open Critical finding did not block the NSR route — GATE 4 was silently bypassed. Output: $OUT"
fi

# 3d. native NSR clean -> still ALLOWED with no security-findings.json needed at all
#     (must not regress the already-working native path).
rm -f "$SEC_FILE"
write_rv "$HEAD_SHA_FIXTURE" "clean"
OUT="$(run_block "$NEW_BLOCK")"
if is_refused "$OUT"; then
  notok "REGRESSION: nativeSecurityReview=clean with no security-findings.json was REFUSED — the native route regressed. Output: $OUT"
else
  ok "REGRESSION: nativeSecurityReview=clean still ALLOWS with no independent artifact needed"
fi

echo
echo "git-workflow-nsr-contract.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
