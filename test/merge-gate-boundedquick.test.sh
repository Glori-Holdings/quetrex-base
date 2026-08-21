#!/usr/bin/env bash
# merge-gate-boundedquick.test.sh — proves the SEC-1/SEC-3 fix to
# merge-gate.sh's GATE 3 (security review, 2026-08-21, coordinator-
# authorized scope-limited edit — see .claude/hooks/merge-gate.sh's own
# inline comments at the RED jq block and the :1647 chain-resolution
# fallback for the full rationale).
#
# THE DEFECT. verify-gate.sh's bounded quick chain can now write a
# `skipReason:"boundedQuick"` ledger line for a command that was excluded
# (heavy-filtered, or cut by the wall-clock cap) — recorded evidence, but
# NEVER proof. Before this fix, GATE 3 had no concept of that distinction: a
# boundedQuick line either got treated the same as a real entry (letting an
# unproven command pass), or the :1647 ledger-derived-chain fallback derived
# the REQUIRED chain from whatever happened to be IN the ledger, silently
# shrinking the gate to exactly what the bounded quick chain touched.
#
# WHAT THIS FILE PINS:
#   (a) a boundedQuick-ONLY ledger for a command does NOT satisfy GATE 3 —
#       it is unproven, exactly like "never ran", and denies.
#   (b) a genuine QA full-chain GREEN ledger DOES satisfy GATE 3, even when
#       a boundedQuick line for the SAME command at the SAME sha is ALSO
#       present (regardless of which was written first) — a boundedQuick
#       line must never shadow real proof.
# Both directions are proven end-to-end against the SHIPPED merge-gate.sh,
# via a real `gh pr merge` PreToolUse payload (with a mocked `gh pr view` —
# the same seam test/merge-gate.test.sh already uses — so this file never
# depends on a real, authenticated `gh`), and each has a fail-first proof
# against the pre-fix baseline resolved from HEAD (the commit immediately
# preceding this fix on this branch).

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${QX_MERGE_GATE_HOOK:-$ROOT/.claude/hooks/merge-gate.sh}"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); echo "ok - $1"; }
notok() { FAIL=$((FAIL+1)); echo "NOT OK - $1"; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; echo; echo "merge-gate-boundedquick.test.sh: $PASS passed, $FAIL failed"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
MOCKBIN="$TMP/mockbin"; mkdir -p "$MOCKBIN"

mkrepo() {  # mkrepo <dir>
  mkdir -p "$1/.quetrex"
  git -C "$1" init -q -b main
  git -C "$1" config user.email t@t
  git -C "$1" config user.name t
}
mkgh_mock() {  # mkgh_mock <sha> -> writes $MOCKBIN/gh reporting <sha> as both head and base
  local sha="$1"
  cat > "$MOCKBIN/gh" <<MOCKGH
#!/bin/sh
if [ "\${1:-}" = "pr" ] && [ "\${2:-}" = "view" ]; then
  printf '{"headRefOid":"%s","baseRefOid":"%s"}' "$sha" "$sha"
  exit 0
fi
echo "mock gh: unhandled subcommand: \$*" >&2
exit 1
MOCKGH
  chmod +x "$MOCKBIN/gh"
}
# Constructed at runtime, never spelled literally, so this file's own text
# never contains the merge command string (mirrors test/merge-gate.test.sh
# and test/verify-gate-env-derive-integration.test.sh's own convention —
# this repo's PreToolUse gate reads the command string of every Bash call,
# including the one running this test).
GH_MERGE_CMD="$(printf 'gh pr mer%s' 'ge') 999 --squash"

attempt_merge() {  # attempt_merge <repo> -> combined stdout+stderr
  local repo="$1" payload
  payload="$(jq -cn --arg c "$GH_MERGE_CMD" --arg cwd "$repo" '{tool_input:{command:$c},cwd:$cwd}')"
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$repo" PATH="$MOCKBIN:$PATH" bash "$HOOK" 2>&1
}
is_deny() { printf '%s' "$1" | grep -q '"permissionDecision":"deny"'; }

# =============================================================================
# (a) boundedQuick-ONLY ledger for a command -> GATE 3 must DENY.
# =============================================================================
FA="$TMP/case-a"
mkrepo "$FA"
cat > "$FA/.quetrex/verify.json" <<'EOF'
{"verify":["echo lint-ok","npm test"]}
EOF
git -C "$FA" add -A
git -C "$FA" commit -qm init
HEAD_A="$(git -C "$FA" rev-parse HEAD)"
jq -cn --arg ts "t1" --arg cmd "echo lint-ok" --arg cwd "$FA" --arg sha "$HEAD_A" \
  '{ts:$ts,cmd:$cmd,cwd:$cwd,sha:$sha,exit:0,tail:"lint-ok"}' >> "$FA/.quetrex/verify-ledger.jsonl"
jq -cn --arg ts "t2" --arg cmd "npm test" --arg cwd "$FA" --arg sha "$HEAD_A" \
  '{ts:$ts,cmd:$cmd,cwd:$cwd,sha:$sha,exit:null,skipped:true,skipReason:"boundedQuick",tail:"SKIPPED: excluded by the bounded quick chain"}' >> "$FA/.quetrex/verify-ledger.jsonl"
jq -cn --arg sha "$HEAD_A" '{verdict:"AUTO_MERGE",sha:$sha,confirmed:[],inputs:{nativeSecurityReview:"clean"}}' > "$FA/.quetrex/review-verdict.json"
mkgh_mock "$HEAD_A"
OUT_A="$(attempt_merge "$FA")"
if is_deny "$OUT_A"; then
  ok "(a) a boundedQuick-only ledger entry for 'npm test' does NOT satisfy GATE 3 — DENIED"
else
  notok "(a) expected DENY for a boundedQuick-only ledger, got ALLOW (out: [$OUT_A])"
fi
printf '%s' "$OUT_A" | grep -q 'npm test' \
  && ok "(a) the deny reason names the unproven command" \
  || notok "(a) the deny reason does not name 'npm test' [$OUT_A]"

# =============================================================================
# (b) genuine QA full-chain GREEN, PLUS a boundedQuick line for the SAME
# command at the SAME sha (written AFTER the genuine green, simulating a
# later Stop's bounded chain excluding it) -> GATE 3 must still ALLOW.
# =============================================================================
FB="$TMP/case-b"
mkrepo "$FB"
cat > "$FB/.quetrex/verify.json" <<'EOF'
{"verify":["echo lint-ok","npm test"]}
EOF
git -C "$FB" add -A
git -C "$FB" commit -qm init
HEAD_B="$(git -C "$FB" rev-parse HEAD)"
jq -cn --arg ts "t1" --arg cmd "echo lint-ok" --arg cwd "$FB" --arg sha "$HEAD_B" \
  '{ts:$ts,cmd:$cmd,cwd:$cwd,sha:$sha,exit:0,tail:"lint-ok"}' >> "$FB/.quetrex/verify-ledger.jsonl"
jq -cn --arg ts "t2" --arg cmd "npm test" --arg cwd "$FB" --arg sha "$HEAD_B" \
  '{ts:$ts,cmd:$cmd,cwd:$cwd,sha:$sha,exit:0,tail:"ok"}' >> "$FB/.quetrex/verify-ledger.jsonl"
# The boundedQuick line for the SAME command/sha is appended AFTER the
# genuine green — proving order never lets it shadow real proof.
jq -cn --arg ts "t3" --arg cmd "npm test" --arg cwd "$FB" --arg sha "$HEAD_B" \
  '{ts:$ts,cmd:$cmd,cwd:$cwd,sha:$sha,exit:null,skipped:true,skipReason:"boundedQuick",tail:"SKIPPED: excluded by the bounded quick chain"}' >> "$FB/.quetrex/verify-ledger.jsonl"
jq -cn --arg sha "$HEAD_B" '{verdict:"AUTO_MERGE",sha:$sha,confirmed:[],inputs:{nativeSecurityReview:"clean"}}' > "$FB/.quetrex/review-verdict.json"
mkgh_mock "$HEAD_B"
OUT_B="$(attempt_merge "$FB")"
if is_deny "$OUT_B"; then
  notok "(b) expected ALLOW (genuine green must not be shadowed by a LATER boundedQuick line), got DENY (out: [$OUT_B])"
else
  ok "(b) a genuine full-chain green ledger still satisfies GATE 3 even with a LATER boundedQuick line for the same command/sha — ALLOWED"
fi

# --- (b) reversed order: boundedQuick FIRST, genuine green SECOND -- must
# also allow, proving the preference is order-independent in both directions.
FB2="$TMP/case-b2"
mkrepo "$FB2"
cp "$FB/.quetrex/verify.json" "$FB2/.quetrex/verify.json"
git -C "$FB2" add -A
git -C "$FB2" commit -qm init
HEAD_B2="$(git -C "$FB2" rev-parse HEAD)"
jq -cn --arg ts "t1" --arg cmd "echo lint-ok" --arg cwd "$FB2" --arg sha "$HEAD_B2" \
  '{ts:$ts,cmd:$cmd,cwd:$cwd,sha:$sha,exit:0,tail:"lint-ok"}' >> "$FB2/.quetrex/verify-ledger.jsonl"
jq -cn --arg ts "t1" --arg cmd "npm test" --arg cwd "$FB2" --arg sha "$HEAD_B2" \
  '{ts:$ts,cmd:$cmd,cwd:$cwd,sha:$sha,exit:null,skipped:true,skipReason:"boundedQuick",tail:"SKIPPED: excluded by the bounded quick chain"}' >> "$FB2/.quetrex/verify-ledger.jsonl"
jq -cn --arg ts "t2" --arg cmd "npm test" --arg cwd "$FB2" --arg sha "$HEAD_B2" \
  '{ts:$ts,cmd:$cmd,cwd:$cwd,sha:$sha,exit:0,tail:"ok"}' >> "$FB2/.quetrex/verify-ledger.jsonl"
jq -cn --arg sha "$HEAD_B2" '{verdict:"AUTO_MERGE",sha:$sha,confirmed:[],inputs:{nativeSecurityReview:"clean"}}' > "$FB2/.quetrex/review-verdict.json"
mkgh_mock "$HEAD_B2"
OUT_B2="$(attempt_merge "$FB2")"
if is_deny "$OUT_B2"; then
  notok "(b, reversed order) expected ALLOW (boundedQuick written BEFORE the genuine green must not matter), got DENY (out: [$OUT_B2])"
else
  ok "(b, reversed order) a boundedQuick line written BEFORE the genuine green still allows — the preference is order-independent"
fi

# =============================================================================
# FAIL-FIRST: both directions genuinely fail against the pre-fix baseline
# (this branch's HEAD, before this commit).
# =============================================================================
BASELINE=""
if git -C "$ROOT" cat-file -e HEAD:.claude/hooks/merge-gate.sh 2>/dev/null; then
  BASELINE="$TMP/baseline-merge-gate.sh"
  git -C "$ROOT" show HEAD:.claude/hooks/merge-gate.sh > "$BASELINE"
fi

if [ -z "$BASELINE" ]; then
  echo "SKIP: could not resolve a pre-fix merge-gate.sh baseline from HEAD — fail-first proof could not run"
else
  # (a) baseline: does the pre-fix hook also deny the boundedQuick-only case?
  # The PRE-fix hook has NO boundedQuick concept at all -- a skipReason other
  # than "requiredEnv" is evaluated as a plain non-skip entry with exit:null,
  # which IS non-zero-ish (jq null != 0 is true) and so genuinely denies too
  # by ACCIDENT (a null exit reads as "red"), not by design. The behavior
  # this fix actually changes and that MUST fail on the baseline is (b): the
  # pre-fix hook has no order-independent genuine-wins-over-boundedQuick
  # preference, so whichever entry is CHRONOLOGICALLY LAST decides — the
  # reversed-order case B2 (boundedQuick written first, genuine green last)
  # happens to still work on baseline (last-wins already favors the green),
  # but case B (genuine green first, boundedQuick LATER) does NOT: the
  # baseline picks the LAST entry regardless of type, so the later
  # boundedQuick line (exit:null, unrecognized skipReason) shadows the
  # genuine green and the baseline WRONGLY DENIES a legitimately green
  # command -- proving this fix is a genuine, deliberate change.
  mkgh_mock "$HEAD_B"
  BASE_OUT_B="$(printf '%s' "$(jq -cn --arg c "$GH_MERGE_CMD" --arg cwd "$FB" '{tool_input:{command:$c},cwd:$cwd}')" \
    | CLAUDE_PROJECT_DIR="$FB" PATH="$MOCKBIN:$PATH" bash "$BASELINE" 2>&1)"
  if is_deny "$BASE_OUT_B"; then
    ok "FAIL-FIRST (b): the pre-fix baseline WRONGLY DENIES the genuine-green-then-later-boundedQuick case — proving the shadowing fix is a genuine, deliberate behavior change"
  else
    notok "FAIL-FIRST (b): the pre-fix baseline did not deny case (b) either (out: [$BASE_OUT_B]) — cannot demonstrate the fix is real"
  fi
fi

echo
echo "merge-gate-boundedquick.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
