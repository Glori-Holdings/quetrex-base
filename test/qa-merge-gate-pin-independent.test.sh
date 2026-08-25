#!/usr/bin/env bash
# test/qa-merge-gate-pin-independent.test.sh — INDEPENDENT QA adversarial
# coverage for ONE-COPY item (c)/(d): merge-gate.sh GATE 1's
# branch-pinned ESCALATION marker (re-pinned from sha-ancestor to branch by
# the C4 review fix — see the GATE 1 (c) section below), and GATE 2's
# verdict-pin reason fix.
#
# Written independently of the developer's own escalation-sha-pin.test.sh
# and merge-gate-verdict-pin-order.test.sh — own fixture, own payloads.
#
# Run: bash test/qa-merge-gate-pin-independent.test.sh

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
MERGE_GATE="$REPO_ROOT/plugins/quetrex-factory/scripts/merge-gate.sh"

[ -f "$MERGE_GATE" ] || { echo "FAIL: merge-gate.sh not found at $MERGE_GATE"; exit 1; }
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq is not installed"
  exit 0
fi

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/qa-merge-gate-pin.XXXXXX")"
cleanup() { rm -rf "$FIXTURE"; }
trap cleanup EXIT

git -C "$FIXTURE" init -q -b main
git -C "$FIXTURE" config user.email "qa@example.com"
git -C "$FIXTURE" config user.name "QA Fixture"
echo "one" > "$FIXTURE/README.md"
git -C "$FIXTURE" add README.md
git -C "$FIXTURE" commit -q -m "commit one"
SHA_ONE=$(git -C "$FIXTURE" rev-parse HEAD)

echo "two" >> "$FIXTURE/README.md"
git -C "$FIXTURE" add README.md
git -C "$FIXTURE" commit -q -m "commit two"
SHA_TWO=$(git -C "$FIXTURE" rev-parse HEAD)
HEAD_SHA="$SHA_TWO"

mkdir -p "$FIXTURE/.quetrex"
printf '{"branchPrefix":"claude/"}' > "$FIXTURE/.quetrex/project.json"
printf '{"verify":["true"]}' > "$FIXTURE/.quetrex/verify.json"

write_green_ledger_at() {  # write_green_ledger_at <sha>
  local sha="$1"
  jq -cn --arg sha "$sha" --arg cwd "$FIXTURE" \
    '{ts:"2026-01-01T00:00:00Z",cmd:"true",cwd:$cwd,sha:$sha,exit:0,tail:""}' \
    > "$FIXTURE/.quetrex/verify-ledger.jsonl"
}
write_green_ledger_at "$HEAD_SHA"

PUSH_PAYLOAD=$(jq -cn --arg cwd "$FIXTURE" '{tool_input:{command:"git push origin main"},cwd:$cwd}')

run_gate() {
  printf '%s' "$PUSH_PAYLOAD" | CLAUDE_PROJECT_DIR="$FIXTURE" bash "$MERGE_GATE" 2>&1
}

denies() {  # denies <out> <code>
  local out="$1" code="$2"
  [ "$code" -eq 2 ] || printf '%s' "$out" | grep -qE '"(permissionDecision|decision)"[[:space:]]*:[[:space:]]*"(deny|block)"'
}
reason_of() {
  printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // .reason // empty' 2>/dev/null
}

reset_artifacts() { rm -f "$FIXTURE/.quetrex/ESCALATION" "$FIXTURE/.quetrex/review-verdict.json"; }

# =============================================================================
# GATE 1 (c): legacy non-JSON marker still denies
# =============================================================================
reset_artifacts
printf 'review-gate: rework cap reached, escalating to human' > "$FIXTURE/.quetrex/ESCALATION"
# Give GATE 2 a clean AUTO_MERGE-at-HEAD verdict so a denial can ONLY come
# from GATE 1, not fall through to GATE 2's own deny.
jq -cn --arg sha "$HEAD_SHA" '{verdict:"AUTO_MERGE",sha:$sha}' > "$FIXTURE/.quetrex/review-verdict.json"
OUT=$(run_gate); CODE=$?
if denies "$OUT" "$CODE" && printf '%s' "$(reason_of "$OUT")$OUT" | grep -q "ESCALATE_HUMAN"; then
  ok "GATE1: legacy non-JSON ESCALATION marker still denies (ESCALATE_HUMAN)"
else
  notok "GATE1: legacy marker expected deny+ESCALATE_HUMAN, got code=$CODE out=[$OUT]"
fi

# =============================================================================
# GATE 1 (c) — CORRECTED for the C4 review fix. GATE 1 no longer asks "is
# the marker's sha an ancestor of HEAD" (a plain `git commit --amend`
# satisfies that despite staying on the same branch and losing nothing —
# the exact defect C4 found and fixed). It now asks "does the marker name a
# DIFFERENT branch than the one being evaluated". A marker with a sha that
# is NOT an ancestor of HEAD, but on the SAME branch, must still DENY.
# =============================================================================
reset_artifacts
# Build a sha that exists in THIS repo's object db but is provably not an
# ancestor of HEAD: a commit on an unrelated orphan branch.
git -C "$FIXTURE" checkout -q --orphan unrelated-branch
git -C "$FIXTURE" rm -rq --cached . >/dev/null 2>&1 || true
rm -f "$FIXTURE/README.md"
echo "unrelated" > "$FIXTURE/UNRELATED.md"
git -C "$FIXTURE" add UNRELATED.md
git -C "$FIXTURE" commit -q -m "unrelated commit"
UNRELATED_SHA=$(git -C "$FIXTURE" rev-parse HEAD)
rm -f "$FIXTURE/UNRELATED.md"
git -C "$FIXTURE" checkout -qf main

# (c1) marker names the DIFFERENT branch it actually came from -> ignored,
# falls through to a clean GATE 2 allow.
jq -cn --arg sha "$UNRELATED_SHA" --arg branch "unrelated-branch" '{sha:$sha,branch:$branch,reason:"stale escalation from another branch"}' > "$FIXTURE/.quetrex/ESCALATION"
jq -cn --arg sha "$HEAD_SHA" '{verdict:"AUTO_MERGE",sha:$sha}' > "$FIXTURE/.quetrex/review-verdict.json"
OUT=$(run_gate); CODE=$?
if ! denies "$OUT" "$CODE"; then
  ok "GATE1: JSON marker naming a DIFFERENT branch is ignored — falls through to a clean GATE2 allow"
else
  notok "GATE1: expected the stale/different-branch marker to be ignored (allow), got code=$CODE out=[$OUT]"
fi

# (c2) C4: the SAME non-ancestor sha, but WITHOUT a branch field (the old
# marker shape, or a same-branch amend that the old ancestor test would
# have wrongly cleared) — must DENY. A marker that cannot prove it names a
# different branch is never treated as stale, regardless of its sha.
jq -cn --arg sha "$UNRELATED_SHA" '{sha:$sha,reason:"no branch recorded"}' > "$FIXTURE/.quetrex/ESCALATION"
OUT=$(run_gate); CODE=$?
if denies "$OUT" "$CODE"; then
  ok "C4/GATE1: a non-ancestor sha with NO branch field still denies (fail-closed — the old ancestor test is gone)"
else
  notok "C4/GATE1: expected deny for a branchless marker regardless of its sha, got code=$CODE out=[$OUT]"
fi

# (c3) C4: the marker names the SAME branch ("main") as the one being
# evaluated, with a sha that is neither HEAD nor an ancestor of it — the
# exact shape a same-branch rebase/amend produces. Must still DENY.
jq -cn --arg sha "$UNRELATED_SHA" --arg branch "main" '{sha:$sha,branch:$branch,reason:"same branch, unrelated sha (amend/rebase shape)"}' > "$FIXTURE/.quetrex/ESCALATION"
OUT=$(run_gate); CODE=$?
if denies "$OUT" "$CODE"; then
  ok "C4/GATE1: marker names the SAME branch (main) even with an unrelated sha -> still denies (amend/rebase no longer clears it)"
else
  notok "C4/GATE1: expected deny for a same-branch marker regardless of its sha, got code=$CODE out=[$OUT]"
fi

# Sanity: a marker sha that actually IS an ancestor of HEAD (commit one, on
# the main line), same branch, still denies too.
jq -cn --arg sha "$SHA_ONE" --arg branch "main" '{sha:$sha,branch:$branch,reason:"escalation, ancestor of HEAD"}' > "$FIXTURE/.quetrex/ESCALATION"
OUT=$(run_gate); CODE=$?
if denies "$OUT" "$CODE"; then
  ok "GATE1 sanity: marker sha that IS an ancestor of HEAD, same branch, still denies"
else
  notok "GATE1 sanity: expected deny for ancestor-sha marker, got code=$CODE out=[$OUT]"
fi
reset_artifacts

# =============================================================================
# GATE 2 (d): verdict REWORK pinned to a different sha yields the
# "never ran on this commit" reason, not the REWORK reason
# =============================================================================
jq -cn --arg sha "$SHA_ONE" '{verdict:"REWORK",sha:$sha}' > "$FIXTURE/.quetrex/review-verdict.json"
OUT=$(run_gate); CODE=$?
REASON="$(reason_of "$OUT")$OUT"
if denies "$OUT" "$CODE" && printf '%s' "$REASON" | grep -q "never ran on this commit" && ! printf '%s' "$REASON" | grep -Eq "review verdict is ['\"]REWORK['\"]"; then
  ok "GATE2: REWORK pinned to a stale sha denies with 'never ran on this commit', not the REWORK reason"
else
  notok "GATE2: expected 'never ran on this commit' and no quoted REWORK value, got code=$CODE out=[$OUT]"
fi

# Sanity: REWORK pinned to the ACTUAL HEAD still denies (no allow path
# opened) — it need not necessarily quote REWORK, but it must still be a
# denial with a review-gate-related reason.
jq -cn --arg sha "$HEAD_SHA" '{verdict:"REWORK",sha:$sha}' > "$FIXTURE/.quetrex/review-verdict.json"
OUT=$(run_gate); CODE=$?
if denies "$OUT" "$CODE"; then
  ok "GATE2 sanity: REWORK pinned to actual HEAD still denies"
else
  notok "GATE2 sanity: expected REWORK-at-HEAD to still deny, got code=$CODE out=[$OUT]"
fi

# Sanity: the happy path is untouched — AUTO_MERGE pinned to HEAD, no
# ESCALATION, allows.
reset_artifacts
jq -cn --arg sha "$HEAD_SHA" '{verdict:"AUTO_MERGE",sha:$sha}' > "$FIXTURE/.quetrex/review-verdict.json"
OUT=$(run_gate); CODE=$?
if ! denies "$OUT" "$CODE"; then
  ok "GATE2 sanity: AUTO_MERGE pinned to HEAD still allows (no regression on the happy path)"
else
  notok "GATE2 sanity: expected AUTO_MERGE-at-HEAD to allow, got code=$CODE out=[$OUT]"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "qa-merge-gate-pin-independent.test.sh: all checks passed"
else
  echo "qa-merge-gate-pin-independent.test.sh: FAILURES above"
fi
exit "$FAIL"
