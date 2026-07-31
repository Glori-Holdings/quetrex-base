#!/usr/bin/env bash
# test/merge-gate.test.sh — regression for the merge-gate GATE 3 sha-pin defect.
#
# Run: bash test/merge-gate.test.sh
#
# BUG (fixed by this branch): merge-gate.sh GATE 3 requires the MOST RECENT
# ledger line for every command in the current verify chain to (a) exit 0 AND
# (b) carry `sha == HEAD`. Before the fix, qa.md's ledger writer never wrote a
# `sha` field at all, and the worktree flow never re-pinned the full chain to
# the worktree's own committed HEAD — so a fully clean pipeline could never
# satisfy GATE 3, and merge-gate.sh denied a merge that should have been
# allowed (a chain-of-custody + liveness bug: it fails closed, but it also
# fails closed on GENUINELY clean work).
#
# This test proves merge-gate.sh's actual CONTRACT against a throwaway fixture
# git repo, independent of which upstream stage wrote the sha:
#   1. ALLOW — full verify chain green, EVERY line sha-pinned to HEAD, an
#      AUTO_MERGE verdict pinned to HEAD, no open Critical finding -> the hook
#      emits NOTHING on stdout (no permissionDecision:deny) and exits 0.
#   2. DENY  — same fixture, but the ledger's sha is stale (not HEAD) -> denied.
#   3. DENY  — same fixture, but review-verdict.json is missing -> denied.
#
# A bash test invoking merge-gate.sh directly against a fixture repo, per the
# accepted approach for exercising a PreToolUse hook script outside the actual
# Claude Code runtime.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO_ROOT/.claude/hooks/merge-gate.sh"

if [ ! -x "$HOOK" ] && [ ! -f "$HOOK" ]; then
  echo "FAIL: hook not found at $HOOK"
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq is not installed — merge-gate.sh is jq-mandatory, nothing to test"
  exit 0
fi

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/merge-gate-fixture.XXXXXX")"
cleanup() { rm -rf "$FIXTURE"; }
trap cleanup EXIT

# --- build a minimal, self-contained fixture repo ---------------------------
git -C "$FIXTURE" init -q -b main
git -C "$FIXTURE" config user.email "test@example.com"
git -C "$FIXTURE" config user.name "Fixture"
echo "fixture" > "$FIXTURE/README.md"
git -C "$FIXTURE" add README.md
git -C "$FIXTURE" commit -q -m "chore: fixture commit"
HEAD_SHA="$(git -C "$FIXTURE" rev-parse HEAD)"

mkdir -p "$FIXTURE/.quetrex"
printf '{"verify":["true","echo ok"]}' > "$FIXTURE/.quetrex/verify.json"

write_ledger_at() {  # write_ledger_at <sha>
  local sha="$1"
  : > "$FIXTURE/.quetrex/verify-ledger.jsonl"
  jq -cn --arg sha "$sha" --arg cwd "$FIXTURE" \
    '{ts:"2026-01-01T00:00:00Z",cmd:"true",cwd:$cwd,sha:$sha,exit:0,tail:""}' \
    >> "$FIXTURE/.quetrex/verify-ledger.jsonl"
  jq -cn --arg sha "$sha" --arg cwd "$FIXTURE" \
    '{ts:"2026-01-01T00:00:01Z",cmd:"echo ok",cwd:$cwd,sha:$sha,exit:0,tail:"ok"}' \
    >> "$FIXTURE/.quetrex/verify-ledger.jsonl"
}

# A verdict from a genuinely clean run. `inputs.nativeSecurityReview` must
# record that the native /security-review actually EXECUTED ("clean" or
# "issues"); the gate treats anything else as the reviewer having graded its
# own homework. An AUTO_MERGE without it is not a mergeable state, so the
# happy-path fixture has to carry it.
write_verdict_at() {  # write_verdict_at <sha> [nativeSecurityReview]
  jq -cn --arg sha "$1" --arg nsr "${2:-clean}" \
    '{verdict:"AUTO_MERGE",sha:$sha,confirmed:[],inputs:{nativeSecurityReview:$nsr}}' \
    > "$FIXTURE/.quetrex/review-verdict.json"
}

# The EXACT shape qa.md's run() ledger writer emitted BEFORE this branch's
# fix: {ts,cmd,cwd,exit,tail} with no `sha` field at all. Every command still
# exited 0 -- this is what a fully clean pipeline's ledger looked like
# pre-fix.
write_ledger_no_sha() {
  : > "$FIXTURE/.quetrex/verify-ledger.jsonl"
  jq -cn --arg cwd "$FIXTURE" \
    '{ts:"2026-01-01T00:00:00Z",cmd:"true",cwd:$cwd,exit:0,tail:""}' \
    >> "$FIXTURE/.quetrex/verify-ledger.jsonl"
  jq -cn --arg cwd "$FIXTURE" \
    '{ts:"2026-01-01T00:00:01Z",cmd:"echo ok",cwd:$cwd,exit:0,tail:"ok"}' \
    >> "$FIXTURE/.quetrex/verify-ledger.jsonl"
}

run_hook() {
  local cwd="$1" payload
  payload="$(jq -cn --arg cmd "gh pr merge 123 --squash" --arg cwd "$cwd" \
    '{tool_input:{command:$cmd},cwd:$cwd}')"
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$cwd" "$HOOK"
}

is_deny() { printf '%s' "$1" | grep -q '"permissionDecision":"deny"'; }

# =============================================================================
# 1) ALLOW — full chain green, sha-pinned to HEAD; AUTO_MERGE pinned to HEAD.
#    THIS is the regression: before the fix, no ledger writer in the pipeline
#    ever produced this shape at the worktree's HEAD, so a clean run could
#    never reach this state and the merge was always (wrongly) denied.
# =============================================================================
write_ledger_at "$HEAD_SHA"
write_verdict_at "$HEAD_SHA"
rm -f "$FIXTURE/.quetrex/security-findings.json" "$FIXTURE/.quetrex/ESCALATION"

OUT="$(run_hook "$FIXTURE")"; CODE=$?
if [ "$CODE" -eq 0 ] && [ -z "$OUT" ]; then
  pass "ALLOW: clean sha-pinned chain + AUTO_MERGE -> no deny emitted, exit 0"
else
  fail "ALLOW: expected exit 0 + empty stdout, got exit $CODE stdout: [$OUT]"
fi

# =============================================================================
# 2) DENY — ledger is green but sha-pinned to a DIFFERENT (stale) commit.
# =============================================================================
write_ledger_at "0000000000000000000000000000000000000000"
write_verdict_at "$HEAD_SHA"

OUT="$(run_hook "$FIXTURE")"; CODE=$?
if [ "$CODE" -eq 0 ] && is_deny "$OUT"; then
  pass "DENY: stale (non-HEAD) sha-pinned ledger is denied"
else
  fail "DENY(stale ledger): expected a deny decision, got exit $CODE stdout: [$OUT]"
fi

# =============================================================================
# 3) DENY — review-verdict.json missing entirely (reviewer never ran).
# =============================================================================
write_ledger_at "$HEAD_SHA"
rm -f "$FIXTURE/.quetrex/review-verdict.json"

OUT="$(run_hook "$FIXTURE")"; CODE=$?
if [ "$CODE" -eq 0 ] && is_deny "$OUT"; then
  pass "DENY: missing review-verdict.json is denied"
else
  fail "DENY(no verdict): expected a deny decision, got exit $CODE stdout: [$OUT]"
fi

# =============================================================================
# 4) DENY — the PRE-FIX defect itself: every command exited 0, but the ledger
#    carries no `sha` field at all (qa.md's old shape). GATE 3 cannot trust an
#    unpinned green line, so it must still deny -- proving that WITHOUT the
#    qa.md fix, a fully green pipeline was mechanically unable to merge.
# =============================================================================
write_ledger_no_sha
write_verdict_at "$HEAD_SHA"

OUT="$(run_hook "$FIXTURE")"; CODE=$?
if [ "$CODE" -eq 0 ] && is_deny "$OUT"; then
  pass "DENY (the fixed defect): pre-fix sha-less ledger still denies a green run"
else
  fail "DENY(no-sha ledger): expected a deny decision, got exit $CODE stdout: [$OUT]"
fi

# =============================================================================
# 5) DENY — everything else is green, but the verdict records that the native
#    /security-review never actually ran. This is the EXACT state this repo's
#    own .quetrex/review-verdict.json was in ("not_available_in_env") while
#    still carrying AUTO_MERGE: an auto-merge with no independent security
#    pass behind it. The gate must refuse to ship on the reviewer's own say-so.
# =============================================================================
write_ledger_at "$HEAD_SHA"
write_verdict_at "$HEAD_SHA" "not_available_in_env"
rm -f "$FIXTURE/.quetrex/security-findings.json" "$FIXTURE/.quetrex/ESCALATION"

OUT="$(run_hook "$FIXTURE")"; CODE=$?
if [ "$CODE" -eq 0 ] && is_deny "$OUT"; then
  pass "DENY: AUTO_MERGE without an executed native /security-review is denied"
else
  fail "DENY(no native security pass): expected a deny decision, got exit $CODE stdout: [$OUT]"
fi

exit "$FAIL"
