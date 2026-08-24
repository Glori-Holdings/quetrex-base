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
# depends on a real, authenticated `gh`), and the (b) direction has a
# fail-first proof against the pre-fix baseline pinned at the immutable sha
# ff16905 — the same convention every other new HOOKFIX test file uses (see
# its own FAIL-FIRST section for why this replaced a literal `HEAD`
# resolution, which this test's own commit made self-referential, and why
# it is not origin/main or main either, which become the post-fix code once
# #119 lands).

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
mkgh_mock2() {  # mkgh_mock2 <head-sha> <base-sha> -> distinct head/base, for
                # cases that need a REAL 2-commit history (unlike mkgh_mock,
                # which reports the same sha for both).
  local head="$1" base="$2"
  cat > "$MOCKBIN/gh" <<MOCKGH
#!/bin/sh
if [ "\${1:-}" = "pr" ] && [ "\${2:-}" = "view" ]; then
  printf '{"headRefOid":"%s","baseRefOid":"%s"}' "$head" "$base"
  exit 0
fi
exit 1
MOCKGH
  chmod +x "$MOCKBIN/gh"
}

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
# (d) SEC-12 (security review, 2026-08-21): a boundedQuick-only entry AT HEAD
# must DEFER to an artifact-only-range ANCESTOR green, never short-circuit
# past it. THE BUG THIS PINS: jq tostring applied to a JSON null .exit
# produces the non-empty STRING "null", so a bash check of the shape
# [ -n "$e_athead" ] (true for the STRING "null") took the why="exit"
# branch and the ancestor walk below was never reached -- reproduced in
# NORMAL operation: green at an ancestor commit, an artifact-only-range
# commit that only touches .quetrex/* (exactly the shape the security
# reviewer own artifact commit takes), then a Stop at that new HEAD whose
# bounded quick chain filtered the command -- the merge denied "exit null"
# instead of consulting the ancestor green.
# =============================================================================
FD="$TMP/case-d"
mkrepo "$FD"
cat > "$FD/.quetrex/verify.json" <<'EOF'
{"verify":["npm test"]}
EOF
git -C "$FD" add -A
git -C "$FD" commit -qm "X: real code, verify.json requires npm test"
HEAD_D_X="$(git -C "$FD" rev-parse HEAD)"
# Y: an ARTIFACT-ONLY commit -- touches NOTHING outside .quetrex/, exactly
# the shape artifact_only_range_ok requires to treat X..Y as still describing
# the same code.
: > "$FD/.quetrex/marker.txt"
git -C "$FD" add .quetrex/marker.txt
git -C "$FD" commit -qm "Y: artifact-only commit (touches only .quetrex/*)"
HEAD_D_Y="$(git -C "$FD" rev-parse HEAD)"
mkdir -p "$FD/.quetrex"
# Genuine green recorded AT X (the real code commit).
jq -cn --arg ts "t1" --arg cmd "npm test" --arg cwd "$FD" --arg sha "$HEAD_D_X" \
  '{ts:$ts,cmd:$cmd,cwd:$cwd,sha:$sha,exit:0,tail:"ok"}' >> "$FD/.quetrex/verify-ledger.jsonl"
# A LATER Stop at Y (the artifact-only commit) whose bounded quick chain
# filtered the command -- the ONLY entry AT $head (Y) is boundedQuick.
jq -cn --arg ts "t2" --arg cmd "npm test" --arg cwd "$FD" --arg sha "$HEAD_D_Y" \
  '{ts:$ts,cmd:$cmd,cwd:$cwd,sha:$sha,exit:null,skipped:true,skipReason:"boundedQuick",tail:"SKIPPED: excluded by the bounded quick chain"}' >> "$FD/.quetrex/verify-ledger.jsonl"
jq -cn --arg sha "$HEAD_D_Y" '{verdict:"AUTO_MERGE",sha:$sha,confirmed:[],inputs:{nativeSecurityReview:"clean"}}' > "$FD/.quetrex/review-verdict.json"
mkgh_mock2 "$HEAD_D_Y" "$HEAD_D_X"
OUT_D="$(attempt_merge "$FD")"
if is_deny "$OUT_D"; then
  notok "(d) SEC-12: expected ALLOW -- a boundedQuick-only entry at HEAD must defer to the artifact-only-range ancestor green, got DENY (out: [$OUT_D])"
else
  ok "(d) SEC-12: a boundedQuick-only entry at HEAD correctly DEFERS to the artifact-only-range ancestor green -- ALLOWED (the tostring(null) string trap does not short-circuit the ancestor walk)"
fi

# =============================================================================
# (e) SEC-14 (security review at 4bd824f, 2026-08-21): the :1725 autodetect
# fallback used to read ONLY package.json (despite claiming parity with
# verify-gate.sh own resolve_autodetect, and despite the deny text naming
# Makefile/pyproject.toml/go.mod/Cargo.toml as sources checked). A go.mod
# repo with no .quetrex/verify.json and no CLAUDE.md "## Verification"
# fence hit a PERMANENT ESCALATE_HUMAN deny naming four sources the code
# never actually read. This pins the fix: a genuine go.mod autodetect chain
# ("go build ./...", "go test ./...") both genuinely green at HEAD -> ALLOW.
# =============================================================================
FE="$TMP/case-e"
mkrepo "$FE"
cat > "$FE/go.mod" <<'EOF'
module example.com/x

go 1.21
EOF
git -C "$FE" add -A
git -C "$FE" commit -qm "go.mod repo, no verify.json, no CLAUDE.md fence"
HEAD_E="$(git -C "$FE" rev-parse HEAD)"
jq -cn --arg ts "t1" --arg cmd "go build ./..." --arg cwd "$FE" --arg sha "$HEAD_E" \
  '{ts:$ts,cmd:$cmd,cwd:$cwd,sha:$sha,exit:0,tail:"build-ok"}' >> "$FE/.quetrex/verify-ledger.jsonl"
jq -cn --arg ts "t2" --arg cmd "go test ./..." --arg cwd "$FE" --arg sha "$HEAD_E" \
  '{ts:$ts,cmd:$cmd,cwd:$cwd,sha:$sha,exit:0,tail:"test-ok"}' >> "$FE/.quetrex/verify-ledger.jsonl"
jq -cn --arg sha "$HEAD_E" '{verdict:"AUTO_MERGE",sha:$sha,confirmed:[],inputs:{nativeSecurityReview:"clean"}}' > "$FE/.quetrex/review-verdict.json"
mkgh_mock "$HEAD_E"
OUT_E="$(attempt_merge "$FE")"
if is_deny "$OUT_E"; then
  notok "(e) SEC-14: expected ALLOW -- a go.mod repo with a genuinely green go build/go test ledger should resolve via autodetect, got DENY (out: [$OUT_E])"
else
  ok "(e) SEC-14: a go.mod repo with no verify.json/CLAUDE.md fence resolves its chain via autodetect (go build ./..., go test ./...) and ALLOWS on genuine green"
fi

# (e, negative control) the SAME go.mod repo, but the ledger has NO entry at
# all for "go test ./..." -- autodetect must still REQUIRE it (proving the
# chain genuinely includes both commands, not just whichever happened to be
# in the ledger).
FE2="$TMP/case-e2"
mkrepo "$FE2"
cp "$FE/go.mod" "$FE2/go.mod"
git -C "$FE2" add -A
git -C "$FE2" commit -qm "go.mod repo, only go build ran"
HEAD_E2="$(git -C "$FE2" rev-parse HEAD)"
jq -cn --arg ts "t1" --arg cmd "go build ./..." --arg cwd "$FE2" --arg sha "$HEAD_E2" \
  '{ts:$ts,cmd:$cmd,cwd:$cwd,sha:$sha,exit:0,tail:"build-ok"}' >> "$FE2/.quetrex/verify-ledger.jsonl"
jq -cn --arg sha "$HEAD_E2" '{verdict:"AUTO_MERGE",sha:$sha,confirmed:[],inputs:{nativeSecurityReview:"clean"}}' > "$FE2/.quetrex/review-verdict.json"
mkgh_mock "$HEAD_E2"
OUT_E2="$(attempt_merge "$FE2")"
if is_deny "$OUT_E2"; then
  ok "(e, negative control) SEC-14: a missing 'go test ./...' entry correctly DENIES -- autodetect genuinely requires both go.mod commands, not just whichever ran"
else
  notok "(e, negative control) SEC-14: expected DENY (go test ./... never ran), got ALLOW (out: [$OUT_E2]) -- autodetect is not actually requiring the full go.mod chain"
fi

# --- SEC-14 FAIL-FIRST: the pre-fix baseline (4bd824f) never reads go.mod at
# all, so case (e) must ESCALATE_HUMAN-deny there even with a fully green
# ledger for both commands -- proving this is a genuine, deliberate fix.
SEC14_BASELINE_SHA="4bd824f"
if git -C "$ROOT" cat-file -e "${SEC14_BASELINE_SHA}:.claude/hooks/merge-gate.sh" 2>/dev/null; then
  SEC14_BASELINE="$TMP/sec14-baseline-merge-gate.sh"
  git -C "$ROOT" show "${SEC14_BASELINE_SHA}:.claude/hooks/merge-gate.sh" > "$SEC14_BASELINE"
  BASE_E_OUT="$(printf '%s' "$(jq -cn --arg c "$GH_MERGE_CMD" --arg cwd "$FE" '{tool_input:{command:$c},cwd:$cwd}')" \
    | CLAUDE_PROJECT_DIR="$FE" PATH="$MOCKBIN:$PATH" bash "$SEC14_BASELINE" 2>&1)"
  if is_deny "$BASE_E_OUT"; then
    ok "SEC-14 FAIL-FIRST: the pre-fix baseline ($SEC14_BASELINE_SHA) WRONGLY DENIES the go.mod repo with a fully green ledger -- proving the autodetect-parity fix is genuine"
  else
    notok "SEC-14 FAIL-FIRST: the pre-fix baseline did not deny case (e) either (out: [$BASE_E_OUT]) -- cannot demonstrate the fix is real"
  fi
else
  echo "SKIP: commit ${SEC14_BASELINE_SHA} not reachable -- SEC-14 fail-first proof could not run"
fi

# =============================================================================
# (c) QA-added (GREEN-PROOF review of HOOKFIX, 2026-08-21): reproduces a
# DISTINCT, PRE-EXISTING defect found while hunting for GATE-3 bypasses per
# the coordinator's explicit priority. NOT caused by this diff -- confirmed
# by running this exact reproduction against origin/main's merge-gate.sh
# (before ANY HOOKFIX work): it exhibits the identical bypass there too, via
# its OLD ledger-derived-chain fallback (deriving "required" from whatever
# commands happened to already be in the ledger has the same blind spot as
# the NEW CLAUDE.md/autodetect fallback this commit replaced it with). Per
# this repo's own review-scope doctrine (a finding must be CAUSED BY the
# diff to block it), this does NOT gate HOOKFIX's merge -- it is reported
# here as a standalone, informational, MECHANICALLY REPRODUCIBLE finding for
# separate triage, not folded into PASS/FAIL so it does not block every
# future task's `npm test` on an issue this task did not introduce and is
# not scoped to fix.
#
# THE DEFECT ITSELF, for whoever picks this up: a PR that DELETES
# .quetrex/verify.json entirely silently narrows the required chain to
# whatever the CLAUDE.md fence or (absent that) autodetect derives --
# autodetect's package.json script-key list is FIXED (typecheck/type-check/
# tsc/lint/build/test), so any base-required command outside that list (here,
# verify.json's "npm run e2e", a real, still-broken script) is dropped with
# NO widening against what base required, and GATE 3 allows. The SEC-1 "a PR
# may ADD requirements, never DELETE them" base-union widening at
# merge-gate.sh's :1603-1635 only fires when CHAIN_JSON is ALREADY non-empty
# from HEAD's OWN committed verify.json -- i.e. only a verify.json-vs-
# verify.json comparison is unioned with base; the CLAUDE.md/autodetect
# fallback path was never given an equivalent widening.
# =============================================================================
FC="$TMP/case-c"
mkrepo "$FC"
cat > "$FC/package.json" <<'EOF'
{"name":"x","scripts":{"test":"echo test-ok","lint":"echo lint-ok","e2e":"exit 1"}}
EOF
cat > "$FC/.quetrex/verify.json" <<'EOF'
{"verify":["npm run lint","npm test","npm run e2e"]}
EOF
git -C "$FC" add -A
git -C "$FC" commit -qm "base: verify.json requires lint+test+e2e (e2e is genuinely broken)"
HEAD_C_BASE="$(git -C "$FC" rev-parse HEAD)"
git -C "$FC" rm -q .quetrex/verify.json
git -C "$FC" commit -qm "PR: delete verify.json"
HEAD_C="$(git -C "$FC" rev-parse HEAD)"
mkdir -p "$FC/.quetrex"
# lint and test genuinely ran and passed at HEAD_C. e2e -- still required at
# BASE, still genuinely broken (exit 1) if it were ever invoked -- has NO
# ledger entry at all: it was never run, and (per the defect above) autodetect
# never even asked for it, since "e2e" is not in the fixed script-key list.
jq -cn --arg ts "t1" --arg cmd "npm run lint" --arg cwd "$FC" --arg sha "$HEAD_C" \
  '{ts:$ts,cmd:$cmd,cwd:$cwd,sha:$sha,exit:0,tail:"lint-ok"}' >> "$FC/.quetrex/verify-ledger.jsonl"
jq -cn --arg ts "t2" --arg cmd "npm run test" --arg cwd "$FC" --arg sha "$HEAD_C" \
  '{ts:$ts,cmd:$cmd,cwd:$cwd,sha:$sha,exit:0,tail:"test-ok"}' >> "$FC/.quetrex/verify-ledger.jsonl"
jq -cn --arg sha "$HEAD_C" '{verdict:"AUTO_MERGE",sha:$sha,confirmed:[],inputs:{nativeSecurityReview:"clean"}}' > "$FC/.quetrex/review-verdict.json"
mkgh_mock2 "$HEAD_C" "$HEAD_C_BASE"
OUT_C="$(attempt_merge "$FC")"
if is_deny "$OUT_C"; then
  echo "INFO (c): deleting verify.json did NOT silently drop the base-required \`npm run e2e\` — DENIED (this pre-existing defect, if it still exists, would have been reported here; it was not reproduced)."
else
  echo "SKIP: pre-existing GATE-3 finding reproduced, NOT attributed to this diff, NOT counted toward PASS/FAIL (see comment above) — deleting .quetrex/verify.json let this PR silently drop \`npm run e2e\` (a command BASE's verify.json required, genuinely broken, exit 1) and GATE 3 ALLOWED with 0 evidence for it (out: [$OUT_C]). Confirmed identically reproducible against origin/main's merge-gate.sh (pre-HOOKFIX). Reported to the coordinator for separate triage; not fixed here — QA has no license to edit merge-gate.sh production code, and this is out of THIS task's scope per the diff-attribution rule."
fi

# =============================================================================
# FAIL-FIRST: both directions genuinely fail against the pre-fix baseline.
#
# QA FIX (GREEN-PROOF review, 2026-08-21): this originally resolved literal
# `HEAD:.claude/hooks/merge-gate.sh`. This test file was added in the SAME
# commit as the SEC-1/SEC-3 fix, so at the time this test actually runs,
# `HEAD` IS that commit — `git show HEAD:path` returns the ALREADY-FIXED
# file, not a pre-fix baseline, making the fail-first proof self-referential
# (it compared the fixed hook against itself and always passed vacuously).
# Confirmed empirically: `git -C "$ROOT" diff HEAD -- .claude/hooks/merge-gate.sh`
# is empty at this commit. Switched to the SAME convention every other new
# HOOKFIX test file already uses (see stop-bounded-by-construction.test.sh,
# bound-version-guard.test.sh, protected-files-guard.test.sh's own AC11
# sections): resolve a STABLE, IMMUTABLE pre-branch reference — ff16905
# (main's tip immediately before #119 merged this branch's boundedQuick
# work), which genuinely predates it (0 occurrences of "boundedQuick" in
# that copy — checked). NOT origin/main or main: those are moving refs that
# become the post-fix code the moment #119 lands, at which point this proof
# would stop demonstrating anything (or worse, silently invert). A
# commit-relative offset has the same problem for the same reason.
BASELINE=""
if git -C "$ROOT" show ff16905:.claude/hooks/merge-gate.sh > "$TMP/baseline-merge-gate.sh" 2>/dev/null; then
  BASELINE="$TMP/baseline-merge-gate.sh"
fi

if [ -z "$BASELINE" ]; then
  echo "SKIP: could not resolve ff16905:.claude/hooks/merge-gate.sh (pre-#119 baseline) — fail-first proof could not run"
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

# FAIL-FIRST (d) SEC-12: origin/main predates boundedQuick entirely, so it
# denies case (d) for the WRONG reason (no boundedQuick concept — a null
# exit just reads as red by accident, same as case (a) above) and would not
# isolate the persha-exclusion bug this fix actually closes. The genuine
# pre-fix baseline for THIS specific change is the committed 4bd824f version:
# it already has the boundedQuick concept and the $athead null-vs-fallback
# fix, but not yet the $persha boundedQuick-exclusion.
#
# QA FIX (GREEN-PROOF review, 2026-08-21): this originally resolved the
# baseline via `git show HEAD:path`, gated on `! git diff --quiet HEAD --
# path` (i.e. only when merge-gate.sh had an UNCOMMITTED diff). That is only
# ever true transiently, during the same session the fix is written in —
# once this commit lands (as it now has), HEAD has no uncommitted diff
# against itself, the guard is permanently false, and this proof
# permanently prints "SKIP" forever, never proving anything again despite
# the PR description's "every fix has a fail-first test" claim. Confirmed
# 4bd824f is independently a durable, PERMANENT baseline for this exact
# claim — it already carries the $athead fix but genuinely lacks the
# $persha boundedQuick-exclusion (grepped directly: 0 occurrences of
# `select(.boundedQuick | not) ] ) as $persha`-shaped filtering after the
# reduce/dominance step) — so pin to that immutable sha instead, the same
# durable pattern SEC-14/SEC-15's fail-firsts already use.
SEC12_BASELINE_SHA="4bd824f"
if git -C "$ROOT" cat-file -e "${SEC12_BASELINE_SHA}:.claude/hooks/merge-gate.sh" 2>/dev/null; then
  D_BASELINE="$TMP/baseline-merge-gate-d.sh"
  git -C "$ROOT" show "${SEC12_BASELINE_SHA}:.claude/hooks/merge-gate.sh" > "$D_BASELINE"
  mkgh_mock2 "$HEAD_D_Y" "$HEAD_D_X"
  BASE_OUT_D="$(printf '%s' "$(jq -cn --arg c "$GH_MERGE_CMD" --arg cwd "$FD" '{tool_input:{command:$c},cwd:$cwd}')" \
    | CLAUDE_PROJECT_DIR="$FD" PATH="$MOCKBIN:$PATH" bash "$D_BASELINE" 2>&1)"
  if is_deny "$BASE_OUT_D"; then
    ok "FAIL-FIRST (d) SEC-12: the pre-persha-fix baseline ($SEC12_BASELINE_SHA) WRONGLY DENIES the artifact-only-range ancestor-defer case — proving the \$persha boundedQuick-exclusion is a genuine, deliberate behavior change"
  else
    notok "FAIL-FIRST (d) SEC-12: the pre-persha-fix baseline did not deny case (d) either (out: [$BASE_OUT_D]) — cannot demonstrate the fix is real"
  fi
else
  echo "SKIP: commit ${SEC12_BASELINE_SHA} not reachable — SEC-12 (d) fail-first proof could not run"
fi


# =============================================================================
# SEC-17 (security review, 2026-08-21): merge-gate.sh copies the SAME
# split_segments_quote_aware tokenizer. Its old `>|` glue inspected the
# last EMITTED character, which cannot tell an escaped '>' from a genuine
# one -- an escaped '>' immediately followed by a REAL pipe (e.g. a merge
# command built as `echo a\>|gh pr merge ...`) got the real pipe wrongly
# glued away, hiding the ENTIRE merge command inside one never-evaluated
# segment. Reproduced live: at 349ce29, `gh pr merge 999 --squash` alone
# correctly DENIES (no verdict/ledger for this bare fixture), but prefixing
# it with `echo a\>` and gluing via the bug made merge-gate never recognize
# ANY segment as a merge attempt at all -- 0 decisions, a SILENT ALLOW.
# =============================================================================
FSEC17="$TMP/case-sec17"
mkrepo "$FSEC17"
git -C "$FSEC17" commit --allow-empty -qm "sec17 fixture"
HEAD_SEC17="$(git -C "$FSEC17" rev-parse HEAD)"
mkgh_mock "$HEAD_SEC17"
SEC17_ESCAPED_CMD="$(printf 'echo a\\>|%s' "$GH_MERGE_CMD")"
SEC17_PAYLOAD="$(jq -cn --arg c "$SEC17_ESCAPED_CMD" --arg cwd "$FSEC17" '{tool_input:{command:$c},cwd:$cwd}')"
OUT_SEC17="$(printf '%s' "$SEC17_PAYLOAD" | CLAUDE_PROJECT_DIR="$FSEC17" PATH="$MOCKBIN:$PATH" bash "$HOOK" 2>&1)"
if is_deny "$OUT_SEC17"; then
  ok "SEC-17: an escaped '>' immediately before a REAL pipe into \`gh pr merge\` still splits into its own segment and DENIES (no verdict/ledger for this bare fixture)"
else
  notok "SEC-17: expected DENY -- the merge command must still be recognized as its own segment even preceded by \`echo a\\>|\`, got no-deny (out: [$OUT_SEC17])"
fi

SEC17_BASELINE_SHA="349ce29"
if git -C "$ROOT" cat-file -e "${SEC17_BASELINE_SHA}:.claude/hooks/merge-gate.sh" 2>/dev/null; then
  SEC17_BASELINE="$TMP/sec17-baseline-merge-gate.sh"
  git -C "$ROOT" show "${SEC17_BASELINE_SHA}:.claude/hooks/merge-gate.sh" > "$SEC17_BASELINE"
  BASE_OUT_SEC17="$(printf '%s' "$SEC17_PAYLOAD" | CLAUDE_PROJECT_DIR="$FSEC17" PATH="$MOCKBIN:$PATH" bash "$SEC17_BASELINE" 2>&1)"
  BASE_SEC17_BYTES=$(printf '%s' "$BASE_OUT_SEC17" | wc -c | tr -d ' ')
  if is_deny "$BASE_OUT_SEC17"; then
    notok "SEC-17 FAIL-FIRST: the pre-fix baseline ($SEC17_BASELINE_SHA) unexpectedly already denies the escaped-payload (out: [$BASE_OUT_SEC17]) — cannot demonstrate the fix is real"
  elif [ "$BASE_SEC17_BYTES" -eq 0 ]; then
    ok "SEC-17 FAIL-FIRST: the pre-fix baseline ($SEC17_BASELINE_SHA) produces 0 decision bytes (SILENT ALLOW) for the identical escaped-payload -- the merge command was never recognized as its own segment at all; proving this fix is real"
  else
    notok "SEC-17 FAIL-FIRST: the pre-fix baseline did not deny, but also was not a clean silent-allow either (out: [$BASE_OUT_SEC17]) — ambiguous, cannot cleanly demonstrate the fix"
  fi
else
  echo "SKIP: commit ${SEC17_BASELINE_SHA} not reachable — SEC-17 fail-first proof could not run"
fi

echo
echo "merge-gate-boundedquick.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
