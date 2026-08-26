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
# (c2) Neither contract may still describe the NAIVE "most recent line" rule in
# prose — review iteration 2 found git-workflow.md §2a's paragraph contradicting
# the skip-aware code block ten lines below it (a boundedQuick skip after a green
# made the prose say "run it", the code say "proven").
for f in "$REVIEWER" "$GITWORKFLOW"; do
  if grep -qiE 'most recent line (for that command|is missing)' "$f"; then
    notok "$(basename "$f") still describes the naive most-recent-line rule in prose"
  else
    ok "$(basename "$f") has no naive most-recent-line prose"
  fi
done

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

# =============================================================================
# REWORK 1/2 (review-gate finding, 2026-08-26): the reviewer must be strictly
# read-only for the verify chain — it may never execute a chain command, not
# even to fill a gap (Finding 1), and the jq selector deciding "green at HEAD"
# must be skip-aware exactly like git-workflow.md's Gate 2, not the naive
# "most recent line" check (Finding 2) — a boundedQuick skip line written
# right after a genuine green at the same sha must never make the command
# look unproven.
# =============================================================================

# =============================================================================
# (f) reviewer.md must NEVER append to verify-ledger.jsonl and must NEVER
#     `eval` a chain command anywhere — it is strictly read-only on the ledger.
#     git-workflow.md's §2a is EXEMPT (it is allowed to fill in the ledger);
#     this check is scoped to reviewer.md only.
# =============================================================================
if grep -qF '>> "$LEDGER"' "$REVIEWER"; then
  notok "reviewer.md appends to \$LEDGER (>> \"\$LEDGER\") — it must never write ledger lines"
else
  ok "reviewer.md never appends to \$LEDGER"
fi

REVIEWER_EVAL_CMD="$(grep -nF 'eval "$cmd"' "$REVIEWER")"
if [ -n "$REVIEWER_EVAL_CMD" ]; then
  notok "reviewer.md still executes a chain command with eval \"\$cmd\": $REVIEWER_EVAL_CMD"
else
  ok "reviewer.md never executes a chain command via eval \"\$cmd\""
fi

# =============================================================================
# (g) FUNCTIONAL: the skip-aware jq selector. The exact program below is the
#     one both files must ship VERBATIM (never a paraphrase) — reviewer.md's
#     Step 3 verify_green check and git-workflow.md's §2a fill-in loop must
#     use the identical selector so the two readers of one ledger can never
#     disagree about what "green at HEAD" means.
# =============================================================================
JQ_SELECTOR='[ .[] | select(.cmd == $cmd and (.skipped != true or .skipReason == "requiredEnv")) ] as $meaningful | ($meaningful | map(select(.sha == $head)) | last) as $at_head | ($meaningful | map(select(.skipped != true)) | last) as $last_genuine | if ($at_head == null) then 0 elif ($at_head.skipped == true) then (if ($last_genuine == null or $last_genuine.exit == 0) then 1 else 0 end) elif ($at_head.exit == 0) then 1 else 0 end'

if grep -qF "$JQ_SELECTOR" "$REVIEWER"; then
  ok "reviewer.md ships the skip-aware jq selector verbatim"
else
  notok "reviewer.md does not ship the skip-aware jq selector verbatim — still using (or diverging from) the naive 'last' check"
fi

if grep -qF "$JQ_SELECTOR" "$GITWORKFLOW"; then
  ok "git-workflow.md §2a ships the skip-aware jq selector verbatim"
else
  notok "git-workflow.md §2a does not ship the skip-aware jq selector verbatim — still using (or diverging from) the naive 'last' check"
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq unavailable — skipping the functional selector scenarios (g1)-(g7)"
else
  HEAD_SHA="deadbeef00000000000000000000000000000head"
  OTHER_SHA="0000000000000000000000000000000000other"
  TMPDIR_LEDGER="$(mktemp -d)"
  trap 'rm -rf "$TMPDIR_LEDGER"' EXIT

  run_selector() {
    # $1 = ledger file, $2 = expected 0|1, $3 = case label
    local ledger="$1" expected="$2" label="$3" got
    got="$(jq -sc --arg cmd "npm test" --arg head "$HEAD_SHA" "$JQ_SELECTOR" "$ledger" 2>/dev/null)"
    [ "$got" = "1" ] || got=0   # mirror the shipped shell contract: anything but literal "1" is "not proven"
    if [ "$got" = "$expected" ]; then
      ok "selector case $label: expected $expected, got $got"
    else
      notok "selector case $label: expected $expected, got $got"
    fi
  }

  # (g1) green at HEAD -> 1
  L="$TMPDIR_LEDGER/g1.jsonl"
  jq -nc --arg sha "$HEAD_SHA" '{ts:"t1",cmd:"npm test",cwd:"/x",sha:$sha,exit:0,tail:""}' > "$L"
  run_selector "$L" 1 "g1 (green at HEAD)"

  # (g2) green at HEAD followed by a boundedQuick skip at HEAD -> 1 (THE FINDING)
  L="$TMPDIR_LEDGER/g2.jsonl"
  {
    jq -nc --arg sha "$HEAD_SHA" '{ts:"t1",cmd:"npm test",cwd:"/x",sha:$sha,exit:0,tail:""}'
    jq -nc --arg sha "$HEAD_SHA" '{ts:"t2",cmd:"npm test",cwd:"/x",sha:$sha,exit:null,skipped:true,skipReason:"boundedQuick",tail:""}'
  } > "$L"
  run_selector "$L" 1 "g2 (green at HEAD, then boundedQuick skip at HEAD)"

  # (g3) green at a DIFFERENT sha -> 0
  L="$TMPDIR_LEDGER/g3.jsonl"
  jq -nc --arg sha "$OTHER_SHA" '{ts:"t1",cmd:"npm test",cwd:"/x",sha:$sha,exit:0,tail:""}' > "$L"
  run_selector "$L" 0 "g3 (green at a different sha)"

  # (g4) red at HEAD -> 0
  L="$TMPDIR_LEDGER/g4.jsonl"
  jq -nc --arg sha "$HEAD_SHA" '{ts:"t1",cmd:"npm test",cwd:"/x",sha:$sha,exit:1,tail:"boom"}' > "$L"
  run_selector "$L" 0 "g4 (red at HEAD)"

  # (g5) requiredEnv skip at HEAD, no red anywhere -> 1
  L="$TMPDIR_LEDGER/g5.jsonl"
  jq -nc --arg sha "$HEAD_SHA" '{ts:"t1",cmd:"npm test",cwd:"/x",sha:$sha,exit:null,skipped:true,skipReason:"requiredEnv",tail:""}' > "$L"
  run_selector "$L" 1 "g5 (requiredEnv skip at HEAD, no red anywhere)"

  # (g6) requiredEnv skip at HEAD AFTER a genuine red at HEAD -> 0 (the skip
  #      must never rescue a real failure recorded for this same command)
  L="$TMPDIR_LEDGER/g6.jsonl"
  {
    jq -nc --arg sha "$HEAD_SHA" '{ts:"t1",cmd:"npm test",cwd:"/x",sha:$sha,exit:1,tail:"boom"}'
    jq -nc --arg sha "$HEAD_SHA" '{ts:"t2",cmd:"npm test",cwd:"/x",sha:$sha,exit:null,skipped:true,skipReason:"requiredEnv",tail:""}'
  } > "$L"
  run_selector "$L" 0 "g6 (requiredEnv skip at HEAD after a genuine red at HEAD)"

  # (g7) missing ledger file -> 0
  run_selector "$TMPDIR_LEDGER/does-not-exist.jsonl" 0 "g7a (missing ledger file)"

  # (g7) malformed line -> 0
  L="$TMPDIR_LEDGER/g7b.jsonl"
  printf '{ this is not valid json\n' > "$L"
  run_selector "$L" 0 "g7b (malformed ledger line)"

  rm -rf "$TMPDIR_LEDGER"
  trap - EXIT
fi

echo
echo "verify-chain-runs-once.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
