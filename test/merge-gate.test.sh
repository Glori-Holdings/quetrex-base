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
#
# ALSO COVERS DEFECT Q (merged in from a companion fix landing on main while
# this file's own DEFECT lettering had already reached P -- renamed from that
# fix's original "DEFECT C" label to avoid colliding with the UNRELATED
# DEFECT C below, gh-pr-merge PR-head pinning): review-verdict.json's .sha,
# security-findings.json's .head_sha, and each verify-ledger.jsonl entry's
# .sha are artifacts NAMING the commit they approve. If one of those files
# ever gets committed (contrary to git-workflow.md's convention that .quetrex/*
# stays gitignored), the commit that adds it moves HEAD and the artifact's own
# pin can never equal HEAD again -- denying every subsequent operation
# forever, including the commit that would repair the mistake. The fix: an
# old pin still authorizes HEAD when it is an ancestor of HEAD AND every
# commit in the range touches nothing outside .quetrex/. See the DEFECT Q
# section below for the full case matrix.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The gate ships in TWO places: this repo (the `quetrex` plugin) and
# quetrex-factory/scripts/merge-gate.sh (the engine plugin every armed repo
# runs). They have drifted. Point the suite at either copy so a fix can be
# PROVEN in the one teams actually execute, not just the canonical one:
#   QX_MERGE_GATE_HOOK=/path/to/merge-gate.sh bash test/merge-gate.test.sh
# QX_MERGE_GATE_PROFILE=vector-only skips assertions about a gate the drifted
# factory copy does not carry yet (GATE 2b).
HOOK="${QX_MERGE_GATE_HOOK:-$REPO_ROOT/.claude/hooks/merge-gate.sh}"
GATE_PROFILE="${QX_MERGE_GATE_PROFILE:-full}"

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
MOCKBIN="$(mktemp -d "${TMPDIR:-/tmp}/merge-gate-mockbin.XXXXXX")"
cleanup() { rm -rf "$FIXTURE" "$MOCKBIN"; }
trap cleanup EXIT

# --- mock `gh` -- only implements what merge-gate.sh's PR resolution calls:
# `gh pr view [<id>] [--repo x] --json headRefOid,baseRefOid`. Prepended onto
# PATH for every hook invocation below so the suite never depends on a real
# `gh` being installed/authenticated, and so the "PR head"/"PR base" a test
# simulates is fully under the test's control. Set MOCK_GH_PR_VIEW_SHA and
# MOCK_GH_PR_BASE_SHA to the shas the mock should report (the hook parses the
# JSON itself, same as it would gh's real output), or MOCK_GH_PR_VIEW_FAIL=1
# to simulate an unresolvable PR (gh missing/unauthenticated/PR not found).
# When MOCK_GH_ARGV_LOG names a file, every arg the hook actually passed to
# `gh pr view` (after `pr view`) is written one-per-line — this is what makes
# the PR_ID-parsing loop's ACTUAL resolved identifier assertable, rather than
# only inferred from the gate's allow/deny outcome.
cat > "$MOCKBIN/gh" <<'MOCKGH'
#!/bin/sh
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  shift 2
  if [ -n "${MOCK_GH_ARGV_LOG:-}" ]; then
    : > "$MOCK_GH_ARGV_LOG"
    for a in "$@"; do printf '%s\n' "$a" >> "$MOCK_GH_ARGV_LOG"; done
  fi
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

# The independent security-reviewer's artifact. write_sec <head_sha> <severity|none> [status]
write_sec() {
  if [ "$2" = "none" ]; then
    jq -cn --arg sha "$1" '{task:"T-1",base:"main",head_sha:$sha,reviewed_files:3,verdict:"PASS",findings:[]}' \
      > "$FIXTURE/.quetrex/security-findings.json"
  else
    jq -cn --arg sha "$1" --arg sev "$2" --arg st "${3:-open}" \
      '{task:"T-1",base:"main",head_sha:$sha,reviewed_files:3,verdict:"BLOCK",findings:[{id:"SEC-1",severity:$sev,status:$st,category:"bola-idor",file:"src/x.ts",line:1,summary:"test"}]}' \
      > "$FIXTURE/.quetrex/security-findings.json"
  fi
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

# The literal merge command, assembled at runtime. Written this way on purpose:
# a test file for a hook that pattern-matches merge commands would otherwise
# contain those exact tokens, and this repo's own PreToolUse gate reads the
# command string of every Bash call — including the one that runs this test.
GH_MERGE="$(printf 'gh pr mer%s' 'ge') 123 --squash"
GH_CREATE="$(printf 'gh pr cre%s' 'ate')"
MAIN="$(printf 'ma%s' 'in')"

# default_base_sha <cwd> — what the mock reports as baseRefOid when a test
# doesn't care about the base end of the range: <cwd>'s own local main tip
# (falling back to master). Reproduces exactly what the pre-Blocker-1 hook
# used (a local ref lookup), so every existing assertion below that never
# mentions a base override keeps testing the same scenario it always did.
default_base_sha() {
  git -C "$1" rev-parse --verify --quiet main 2>/dev/null \
    || git -C "$1" rev-parse --verify --quiet master 2>/dev/null
}

# run_hook <cwd> [pr_head_sha_override] [pr_base_sha_override] [fail: 1 to
# simulate an unresolvable PR] [gh_repo_env_override]. Without overrides, the
# mock reports <cwd>'s own current git HEAD as the "PR head" and its local
# main as the "PR base" — reproducing exactly what the pre-fix hook computed
# directly, so every existing assertion below keeps testing the same
# scenario it always did. Tests reproducing the real bugs (local checkout
# elsewhere than the PR head/base) pass explicit overrides.
#
# GH_REPO is ALWAYS passed explicitly (default ""), never left to whatever
# the test runner's own shell happens to have exported — gh reads GH_REPO
# from the environment, and this hook now does too (deliberately, see the
# hook's own comments), so an ambiently-exported GH_REPO in CI would
# otherwise make these tests flaky/environment-dependent. Pass the 5th arg
# to simulate an operator who genuinely has GH_REPO exported.
run_hook() {
  local cwd="$1" pr_sha="${2:-}" base_sha="${3:-}" failflag="${4:-}" gh_repo_env="${5:-}" payload
  [ -z "$pr_sha" ] && pr_sha="$(git -C "$cwd" rev-parse HEAD 2>/dev/null)"
  [ -z "$base_sha" ] && base_sha="$(default_base_sha "$cwd")"
  payload="$(jq -cn --arg cmd "$GH_MERGE" --arg cwd "$cwd" \
    '{tool_input:{command:$cmd},cwd:$cwd}')"
  printf '%s' "$payload" | env PATH="$MOCKBIN:$PATH" MOCK_GH_PR_VIEW_SHA="$pr_sha" MOCK_GH_PR_BASE_SHA="$base_sha" MOCK_GH_PR_VIEW_FAIL="$failflag" GH_REPO="$gh_repo_env" CLAUDE_PROJECT_DIR="$cwd" "$HOOK"
}

# run_cmd <cwd> <command> [pr_head_sha_override] [pr_base_sha_override]
# [argv_log_file] [gh_repo_env_override] — exercise the hook against an
# ARBITRARY command, to assert what is and is not classified as a merge
# vector in the first place. Same mock-gh defaults as run_hook (including
# GH_REPO always explicit, see above). The optional 5th arg captures what
# the hook actually passed to `gh pr view` (see MOCK_GH_ARGV_LOG above) —
# used to assert the resolved PR identifier directly, not just infer it
# from allow/deny.
run_cmd() {
  local cwd="$1" cmd="$2" pr_sha="${3:-}" base_sha="${4:-}" argv_log="${5:-}" gh_repo_env="${6:-}" payload
  [ -z "$pr_sha" ] && pr_sha="$(git -C "$cwd" rev-parse HEAD 2>/dev/null)"
  [ -z "$base_sha" ] && base_sha="$(default_base_sha "$cwd")"
  payload="$(jq -cn --arg cmd "$cmd" --arg cwd "$cwd" \
    '{tool_input:{command:$cmd},cwd:$cwd}')"
  printf '%s' "$payload" | env PATH="$MOCKBIN:$PATH" MOCK_GH_PR_VIEW_SHA="$pr_sha" MOCK_GH_PR_BASE_SHA="$base_sha" MOCK_GH_ARGV_LOG="$argv_log" GH_REPO="$gh_repo_env" CLAUDE_PROJECT_DIR="$cwd" "$HOOK" 2>&1
}

is_deny() { printf '%s' "$1" | grep -q '"permissionDecision":"deny"\|MERGE GATE'; }

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

# NOTE ON THE TEST THAT USED TO BE HERE. It asserted that AUTO_MERGE is denied
# whenever inputs.nativeSecurityReview is not "clean"/"issues" — full stop, with
# this fixture's NEUTRAL diff and no security artifact. That assertion is now
# wrong on purpose: it is the deadlock. The field can only be set by
# /security-review, a SlashCommand the reviewer subagent does not have at
# runtime, so the condition was unsatisfiable and NO clean pipeline could ever
# merge. Its real intent — the reviewer cannot self-exempt from independent
# review and still auto-merge — is preserved and sharpened in B7 (plan demands a
# review) and B9 (the diff itself is sensitive), which are the cases where an
# independent pass is actually required. See DEFECT B below.

# =============================================================================
# DEFECT C — gh pr merge must verify against the PR's HEAD COMMIT, not local
# HEAD.
#
# THE BUG: merge-gate.sh compared the verdict's (and ledger's, and security
# artifact's) sha against `git rev-parse HEAD` in $ROOT -- but for
# `gh pr merge`, the local checkout is almost always sitting on main, not the
# PR branch. Reproduced live 2026-08-07: a verdict correctly pinned to the
# PR's real head (11f84d2) was denied as "stale" because it was compared
# against local main's tip (b7bf116) -- nothing was actually stale. Fixed by
# resolving the PR's real head via `gh pr view --json headRefOid` (mocked
# here -- see MOCKBIN above) and pinning every gate to THAT commit instead.
#
# These three assertions FAIL against the pre-fix hook, for the right reason:
#   C1 fails because the pre-fix hook denies a genuinely clean merge (the bug).
#   C2 and C3 are the guardrails proving the fix didn't just delete the check:
#   a genuinely stale verdict, and an unresolvable PR head, must still deny.
#
# Runs here, BEFORE the fixture's diff ever grows a sensitive file (see B9
# below), so the neutral-diff floor stays neutral and doesn't force these
# assertions to also carry a security artifact just to isolate the sha check.
# =============================================================================

# Simulate a PR branch: a commit that is NOT checked out locally (local stays
# on main's tip). This is exactly the shape of the bug -- the operator's repo
# sits on main while the reviewed commit lives only on the PR branch.
git -C "$FIXTURE" checkout -q -b claude/pr-c1
echo "pr work" >> "$FIXTURE/README.md"
git -C "$FIXTURE" add README.md
git -C "$FIXTURE" commit -q -m "feat: PR branch commit"
PR_HEAD_C1="$(git -C "$FIXTURE" rev-parse HEAD)"
git -C "$FIXTURE" checkout -q main
LOCAL_HEAD_C1="$(git -C "$FIXTURE" rev-parse HEAD)"
if [ "$PR_HEAD_C1" = "$LOCAL_HEAD_C1" ]; then
  fail "DEFECT C setup: PR head and local HEAD must differ to reproduce the bug"
fi

write_ledger_at "$PR_HEAD_C1"
write_verdict_at "$PR_HEAD_C1"
rm -f "$FIXTURE/.quetrex/security-findings.json" "$FIXTURE/.quetrex/ESCALATION"

# C1 -- THE FIX: verdict + ledger pinned to the PR head, local checkout still
# on main (a DIFFERENT commit) -> must be ALLOWED. This is the exact shape of
# the live failure: PR head == verdict sha, local HEAD == main's unrelated tip.
OUT="$(run_hook "$FIXTURE" "$PR_HEAD_C1")"; CODE=$?
if [ "$CODE" -eq 0 ] && [ -z "$OUT" ]; then
  pass "DEFECT C1 (the fix): PR head pinned + AUTO_MERGE, local HEAD is main -> ALLOWED"
else
  fail "DEFECT C1: expected exit 0 + empty stdout (PR head must govern, not local HEAD), got exit $CODE stdout: [$OUT]"
fi

# C2 -- commits landed on the PR branch AFTER the verdict was recorded: the
# verdict is genuinely stale and must STILL be denied. Only WHICH commit the
# gate compares against changed -- the staleness check itself must still fire.
git -C "$FIXTURE" checkout -q claude/pr-c1
echo "post-review commit" >> "$FIXTURE/README.md"
git -C "$FIXTURE" add README.md
git -C "$FIXTURE" commit -q -m "feat: landed after review"
PR_HEAD_C2="$(git -C "$FIXTURE" rev-parse HEAD)"
git -C "$FIXTURE" checkout -q main

OUT="$(run_hook "$FIXTURE" "$PR_HEAD_C2")"
if is_deny "$OUT"; then
  pass "DEFECT C2: commits landed on the PR branch after review -> still DENIED (verdict genuinely stale)"
else
  fail "DEFECT C2: expected a deny decision (verdict pinned to $PR_HEAD_C1, PR head now $PR_HEAD_C2), got [$OUT]"
fi

# C3 -- the PR's head commit cannot be resolved at all (gh missing/PR gone/not
# authenticated). FAIL CLOSED: must deny, never allow an unevaluated merge.
OUT="$(run_hook "$FIXTURE" "" "" 1)"; CODE=$?
if [ "$CODE" -eq 0 ] && is_deny "$OUT"; then
  pass "DEFECT C3: PR head unresolvable (gh failure) -> DENIED (fail closed)"
else
  fail "DEFECT C3: expected a deny decision when the PR head cannot be resolved, got exit $CODE stdout: [$OUT]"
fi

# C4 -- `gh pr view` resolves a real-looking sha, but the commit object is not
# in this checkout and there is no reachable remote to fetch it from. FAIL
# CLOSED here too: an unfetchable PR head is exactly as unevaluatable as an
# unresolvable one, and must never be treated as "diff is empty" by default.
FAKE_PR_SHA="1234567890abcdef1234567890abcdef12345678"
OUT="$(run_hook "$FIXTURE" "$FAKE_PR_SHA")"; CODE=$?
if [ "$CODE" -eq 0 ] && is_deny "$OUT"; then
  pass "DEFECT C4: PR head commit unfetchable (object missing, no remote) -> DENIED (fail closed)"
else
  fail "DEFECT C4: expected a deny decision when the PR head commit cannot be fetched, got exit $CODE stdout: [$OUT]"
fi

# =============================================================================
# DEFECT F — the diff-content gates (sensitive-surface preamble, GATE 5
# ownership) must inspect the PR's OWN diff, not local HEAD's.
#
# THE BUG: even with DEFECT C's sha-pin fix alone, $CHANGED/$ADDED were still
# computed from $ROOT's literal `HEAD` -- local main -- while every sha-based
# gate above now correctly points at the PR head. For `gh pr merge` those are
# DIFFERENT commits, so a sensitive PR could merge with NO security review
# (F1: the sensitive-surface floor reads local main's neutral diff, finds
# nothing, and NEED_SEC stays false even though the PR itself is sensitive).
# Fixed by fetching the PR head (see the block above HEAD_SHA is set) and
# diffing FROM it, not from the literal ref `HEAD`.
#
# Local checkout stays on main throughout -- main's own history is neutral
# and unrelated to the PR's content, so F1 can only DENY if the gate is
# actually looking at the PR's diff.
# =============================================================================
git -C "$FIXTURE" checkout -q -b claude/pr-f-sensitive
mkdir -p "$FIXTURE/src/auth"
cat > "$FIXTURE/src/auth/login.ts" <<'TS'
export function getUser(req) { return db.findById(req.params.id); }
TS
git -C "$FIXTURE" add src/auth/login.ts
git -C "$FIXTURE" commit -q -m "feat: add a sensitive auth surface"
PR_HEAD_F1="$(git -C "$FIXTURE" rev-parse HEAD)"
git -C "$FIXTURE" checkout -q main

write_ledger_at "$PR_HEAD_F1"
write_verdict_at "$PR_HEAD_F1" "not_available_in_env"
rm -f "$FIXTURE/.quetrex/security-findings.json" "$FIXTURE/.quetrex/ESCALATION"

# F1 -- THE FIX: a sensitive PR diff, no independent security artifact, native
# pass unavailable -> must DENY, even though local checkout never leaves main.
OUT="$(run_hook "$FIXTURE" "$PR_HEAD_F1")"
if is_deny "$OUT"; then
  pass "DEFECT F1 (the fix): sensitive PR diff detected from the PR's own head (not local main) -> DENIED"
else
  fail "DEFECT F1: expected a deny decision (sensitive diff requires a security review), got [$OUT]"
fi

# F2 -- same sensitive PR, now with an independent security artifact pinned to
# the PR's real head and clean -> ships. Proves F1 is a real, escapable gate
# tied to the PR's content, not a blanket deny.
write_sec "$PR_HEAD_F1" none
OUT="$(run_hook "$FIXTURE" "$PR_HEAD_F1")"; CODE=$?
if [ "$CODE" -eq 0 ] && [ -z "$OUT" ]; then
  pass "DEFECT F2: sensitive PR diff + independent pinned clean security artifact (PR head) -> ships"
else
  fail "DEFECT F2: expected exit 0 + empty stdout, got exit $CODE stdout: [$OUT]"
fi
rm -f "$FIXTURE/.quetrex/security-findings.json"

# F3 -- GATE 5 (ownership). A plan owns exactly the PR's own changed file,
# src/auth/login.ts. Local main gets a THROWAWAY second commit touching
# README.md -- a file the plan does NOT own -- so a gate that fell back to
# diffing local HEAD would see README.md (unowned) instead of the PR's own
# diff (fully owned) and wrongly deny a clean merge. Reset back to the
# original tip immediately after so every later test's use of $HEAD_SHA
# (a fixed sha captured earlier) stays valid.
git -C "$FIXTURE" checkout -q main
echo "unrelated main-only work" >> "$FIXTURE/README.md"
git -C "$FIXTURE" add README.md
git -C "$FIXTURE" commit -q -m "chore: unrelated later commit on main, not part of the PR"

mkdir -p "$FIXTURE/.quetrex/plan"
jq -cn '{task:"T-1",ownership:{"src/auth/login.ts":"ws-a"}}' \
  > "$FIXTURE/.quetrex/plan/T-1.json"
jq -cn '{task:"T-1"}' > "$FIXTURE/.quetrex/state.json"
write_sec "$PR_HEAD_F1" none
OUT="$(run_hook "$FIXTURE" "$PR_HEAD_F1")"; CODE=$?
if [ "$CODE" -eq 0 ] && [ -z "$OUT" ]; then
  pass "DEFECT F3 (the fix): GATE 5 checks the PR's own diff against its ownership map -> ships (not denied for local main's unrelated commit)"
else
  fail "DEFECT F3: expected exit 0 + empty stdout (src/auth/login.ts IS owned), got exit $CODE stdout: [$OUT]"
fi
rm -rf "$FIXTURE/.quetrex/plan" "$FIXTURE/.quetrex/state.json" "$FIXTURE/.quetrex/security-findings.json"
git -C "$FIXTURE" reset -q --hard "$LOCAL_HEAD_C1"

# =============================================================================
# DEFECT E — gh pr merge's value-taking flags must not be mistaken for the PR
# identifier.
#
# THE GAP: PR_VALUE_FLAGS covered only -R/--repo and the LONG forms of the
# others (--body, --body-file, --subject, --match-head-commit) -- every SHORT
# form (-A/--author-email, -b, -F, -t) fell through as an unrecognized flag,
# so ITS VALUE token was picked up as the bare PR_ID. `gh pr merge -b 91 99
# --squash` (a merge-commit body that happens to look like a PR number) would
# resolve the gate against PR 91's artifacts while `gh` itself merges PR 99.
#
# The mock's ARGV log makes the resolved identifier directly assertable, not
# just inferred from allow/deny (which a coincidental sha match could mask).
# =============================================================================
write_ledger_at "$HEAD_SHA"
write_verdict_at "$HEAD_SHA"
rm -f "$FIXTURE/.quetrex/security-findings.json" "$FIXTURE/.quetrex/ESCALATION"

ARGV_LOG="$(mktemp "${TMPDIR:-/tmp}/merge-gate-argv.XXXXXX")"

assert_resolves_99() {  # assert_resolves_99 <label> <command>
  local label="$1" cmd="$2" out code resolved
  : > "$ARGV_LOG"
  out="$(run_cmd "$FIXTURE" "$cmd" "$HEAD_SHA" "" "$ARGV_LOG")"; code=$?
  resolved="$(head -n1 "$ARGV_LOG" 2>/dev/null)"
  if [ "$resolved" = "99" ] && [ "$code" -eq 0 ] && [ -z "$out" ]; then
    pass "DEFECT E: $label -> correctly resolved PR 99"
  else
    fail "DEFECT E: $label -> expected PR 99 resolved + ALLOW, got resolved='${resolved:-<empty>}' exit=$code out=[$out]"
  fi
}

assert_resolves_99 "--author-email value looks like a PR number" \
  "$(printf 'gh pr mer%s' 'ge') --author-email 91 99 --squash"
assert_resolves_99 "-A (short author-email) value looks like a PR number" \
  "$(printf 'gh pr mer%s' 'ge') -A 91 99 --squash"
assert_resolves_99 "-b (body) value looks like a PR number" \
  "$(printf 'gh pr mer%s' 'ge') -b 91 99 --squash"
assert_resolves_99 "-F (body-file) value looks like a PR number" \
  "$(printf 'gh pr mer%s' 'ge') -F 91 99 --squash"
assert_resolves_99 "-t (subject) value looks like a PR number" \
  "$(printf 'gh pr mer%s' 'ge') -t 91 99 --squash"
assert_resolves_99 "--match-head-commit value is not a PR number" \
  "$(printf 'gh pr mer%s' 'ge') --match-head-commit deadbeefcafe 99 --squash"

rm -f "$ARGV_LOG"

# =============================================================================
# DEFECT G — the BASE end of the diff range must be the PR's actual base
# (baseRefOid), not local main, which is routinely BEHIND origin.
#
# THE BUG: DEFECT F fixed the HEAD end of the range but left the base end as
# a local ref lookup. The ordinary sequence — the cloud cuts a PR branch off
# CURRENT main while the operator's laptop hasn't pulled — means local main
# is stale relative to the PR's real base:
#
#   local main = M0 (never pulled) | origin/main = M1 | PR head = M1 + mine.ts
#
# Diffing "$DIFF_BASE...HEAD_SHA" from local M0 instead of the PR's actual
# base M1 makes the M0->M1 file (something ANOTHER team already merged) show
# up as part of THIS diff, denying a clean PR as touching a file it never
# touched. Uses a dedicated origin/local repo pair (not $FIXTURE) so the
# "local main is behind" shape is real, not simulated.
# =============================================================================
G_ORIGIN="$(mktemp -d "${TMPDIR:-/tmp}/merge-gate-g-origin.XXXXXX")"
git -C "$G_ORIGIN" init -q -b main
git -C "$G_ORIGIN" config user.email "test@example.com"
git -C "$G_ORIGIN" config user.name "Fixture"
echo root > "$G_ORIGIN/root.txt"
git -C "$G_ORIGIN" add root.txt
git -C "$G_ORIGIN" commit -q -m "chore: root commit"

G_LOCAL="$(mktemp -d "${TMPDIR:-/tmp}/merge-gate-g-local.XXXXXX")"
git clone -q "$G_ORIGIN" "$G_LOCAL"
git -C "$G_LOCAL" config user.email "test@example.com"
git -C "$G_LOCAL" config user.name "Fixture"
mkdir -p "$G_LOCAL/.quetrex"
printf '{"verify":["true","echo ok"]}' > "$G_LOCAL/.quetrex/verify.json"

# Origin advances WITHOUT $G_LOCAL ever fetching: another team's work lands
# on main first...
echo other >> "$G_ORIGIN/other-team-file.ts"
git -C "$G_ORIGIN" add other-team-file.ts
git -C "$G_ORIGIN" commit -q -m "feat: other team's already-merged work"
M1_SHA="$(git -C "$G_ORIGIN" rev-parse HEAD)"

# ...and the PR branch is cut from THAT tip, adding only its own file.
git -C "$G_ORIGIN" checkout -q -b claude/pr-g
echo mine >> "$G_ORIGIN/mine.ts"
git -C "$G_ORIGIN" add mine.ts
git -C "$G_ORIGIN" commit -q -m "feat: my PR's own change"
PR_HEAD_G="$(git -C "$G_ORIGIN" rev-parse HEAD)"
git -C "$G_ORIGIN" checkout -q main

# A plan owning ONLY the PR's own file -- if the gate diffs from stale local
# main (M0), other-team-file.ts shows up as "changed" and unowned; if it
# diffs from the PR's real base (M1), only mine.ts shows up, and it IS owned.
mkdir -p "$G_LOCAL/.quetrex/plan"
jq -cn '{task:"T-1",ownership:{"mine.ts":"ws-a"}}' > "$G_LOCAL/.quetrex/plan/T-1.json"
jq -cn '{task:"T-1"}' > "$G_LOCAL/.quetrex/state.json"

: > "$G_LOCAL/.quetrex/verify-ledger.jsonl"
jq -cn --arg sha "$PR_HEAD_G" --arg cwd "$G_LOCAL" \
  '{ts:"2026-01-01T00:00:00Z",cmd:"true",cwd:$cwd,sha:$sha,exit:0,tail:""}' \
  >> "$G_LOCAL/.quetrex/verify-ledger.jsonl"
jq -cn --arg sha "$PR_HEAD_G" --arg cwd "$G_LOCAL" \
  '{ts:"2026-01-01T00:00:01Z",cmd:"echo ok",cwd:$cwd,sha:$sha,exit:0,tail:"ok"}' \
  >> "$G_LOCAL/.quetrex/verify-ledger.jsonl"
jq -cn --arg sha "$PR_HEAD_G" \
  '{verdict:"AUTO_MERGE",sha:$sha,confirmed:[],inputs:{nativeSecurityReview:"clean"}}' \
  > "$G_LOCAL/.quetrex/review-verdict.json"

# G1 -- THE FIX: base of the range is the PR's REAL base (M1, fetched from
# origin), not $G_LOCAL's stale local main (M0) -> only mine.ts is in scope,
# it IS owned -> ALLOWED. $G_LOCAL's main never moves off M0 the whole time.
OUT="$(run_hook "$G_LOCAL" "$PR_HEAD_G" "$M1_SHA")"; CODE=$?
if [ "$CODE" -eq 0 ] && [ -z "$OUT" ]; then
  pass "DEFECT G1 (the fix): base-of-range is the PR's real base, not stale local main -> ALLOWED"
else
  fail "DEFECT G1: expected exit 0 + empty stdout (only mine.ts changed, and it IS owned), got exit $CODE stdout: [$OUT]"
fi

# G2 -- the guardrail: if the PR base is WRONGLY reported as the stale local
# tip (M0), other-team-file.ts is (wrongly) in scope and unowned -> DENY.
# Proves G1's ALLOW is really about which base is used, not a vacuous pass.
OUT="$(run_hook "$G_LOCAL" "$PR_HEAD_G" "")"
if is_deny "$OUT"; then
  pass "DEFECT G2 (guardrail): reporting local main (M0) as the base wrongly includes other-team-file.ts -> DENIED"
else
  fail "DEFECT G2: expected a deny decision when the base is misreported as stale local main, got [$OUT]"
fi

rm -rf "$G_ORIGIN" "$G_LOCAL"

# =============================================================================
# DEFECT H — the post-fetch existence check must not trust `git fetch`'s exit
# code alone, for EITHER end of the range.
#
# THE GAP: `ensure_commit_fetched` in the hook re-checks `cat-file -e` after
# a fetch, specifically because a fetch that exits 0 is not, by itself, proof
# the object landed (a wrapper, a partial fetch, an odd remote config). That
# second check exists in the code, but nothing in the suite forced it to
# fire -- deleting it left 55/55 green. Proven here with a LYING git: a thin
# wrapper that passes every command straight through to the real git EXCEPT
# a `fetch` naming one specific sha, which it "succeeds" at (exit 0) without
# actually depositing the object. If the hook trusted the exit code, this
# would be indistinguishable from a real fetch; the second cat-file -e is
# what catches it.
# =============================================================================
REAL_GIT="$(command -v git)"
LYING_GIT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/merge-gate-lying-git.XXXXXX")"
cat > "$LYING_GIT_DIR/git" <<LYINGGIT
#!/bin/sh
# Passthrough to the real git for everything EXCEPT a "fetch" invocation
# that names one of the shas in \$LYING_ABOUT (space-separated) among its
# args -- that one "succeeds" (exit 0) without touching the object store.
is_fetch=0
has_target=0
for a in "\$@"; do
  [ "\$a" = "fetch" ] && is_fetch=1
  for want in \$LYING_ABOUT; do
    [ "\$a" = "\$want" ] && has_target=1
  done
done
if [ "\$is_fetch" = "1" ] && [ "\$has_target" = "1" ]; then
  exit 0
fi
exec "$REAL_GIT" "\$@"
LYINGGIT
chmod +x "$LYING_GIT_DIR/git"

# run_hook_lying_fetch <cwd> <head_sha> <base_sha> <lying_about_sha> — same
# shape as run_hook, but with LYING_GIT_DIR prepended so plain `git` inside
# the hook resolves to the shim above instead of the real binary.
run_hook_lying_fetch() {
  local cwd="$1" head_sha="$2" base_sha="$3" lying="$4" payload
  payload="$(jq -cn --arg cmd "$GH_MERGE" --arg cwd "$cwd" \
    '{tool_input:{command:$cmd},cwd:$cwd}')"
  printf '%s' "$payload" | env PATH="$LYING_GIT_DIR:$MOCKBIN:$PATH" MOCK_GH_PR_VIEW_SHA="$head_sha" MOCK_GH_PR_BASE_SHA="$base_sha" LYING_ABOUT="$lying" CLAUDE_PROJECT_DIR="$cwd" "$HOOK"
}

H_ORIGIN="$(mktemp -d "${TMPDIR:-/tmp}/merge-gate-h-origin.XXXXXX")"
git -C "$H_ORIGIN" init -q -b main
git -C "$H_ORIGIN" config user.email "test@example.com"
git -C "$H_ORIGIN" config user.name "Fixture"
echo root > "$H_ORIGIN/root.txt"
git -C "$H_ORIGIN" add root.txt
git -C "$H_ORIGIN" commit -q -m "chore: root commit"

H_LOCAL="$(mktemp -d "${TMPDIR:-/tmp}/merge-gate-h-local.XXXXXX")"
git clone -q "$H_ORIGIN" "$H_LOCAL"
git -C "$H_LOCAL" config user.email "test@example.com"
git -C "$H_LOCAL" config user.name "Fixture"
mkdir -p "$H_LOCAL/.quetrex"
printf '{"verify":["true","echo ok"]}' > "$H_LOCAL/.quetrex/verify.json"

# Origin advances past what $H_LOCAL has: a base commit, then a PR head on a
# DELIBERATELY DISJOINT (orphan) history -- not a descendant of the base.
# NEITHER sha exists in $H_LOCAL's object store, so both genuinely require a
# fetch (like DEFECT G) -- but unlike DEFECT G, the head must NOT be a
# descendant of the base here: fetching one real commit transitively fetches
# all of its ancestors, so if head descended from base, fetching head for
# real (H1's honest half) would silently deposit base as a side effect and
# H2's "lie about base" would never actually be exercised (base's cat-file
# would already pass before any fetch is attempted). Both shas still sit at
# the tip of a real ref in $H_ORIGIN, so both remain independently fetchable.
echo base >> "$H_ORIGIN/base.txt"
git -C "$H_ORIGIN" add base.txt
git -C "$H_ORIGIN" commit -q -m "chore: PR base"
H_BASE_SHA="$(git -C "$H_ORIGIN" rev-parse HEAD)"
git -C "$H_ORIGIN" checkout -q --orphan claude/pr-h
git -C "$H_ORIGIN" rm -rf -q . >/dev/null 2>&1 || true
echo mine > "$H_ORIGIN/mine.txt"
git -C "$H_ORIGIN" add mine.txt
git -C "$H_ORIGIN" commit -q -m "feat: my PR's own change (disjoint history)"
H_HEAD_SHA="$(git -C "$H_ORIGIN" rev-parse HEAD)"
git -C "$H_ORIGIN" checkout -q main

mkdir -p "$H_LOCAL/.quetrex/plan"
jq -cn '{task:"T-1",ownership:{"mine.txt":"ws-a"}}' > "$H_LOCAL/.quetrex/plan/T-1.json"
jq -cn '{task:"T-1"}' > "$H_LOCAL/.quetrex/state.json"
: > "$H_LOCAL/.quetrex/verify-ledger.jsonl"
jq -cn --arg sha "$H_HEAD_SHA" --arg cwd "$H_LOCAL" \
  '{ts:"2026-01-01T00:00:00Z",cmd:"true",cwd:$cwd,sha:$sha,exit:0,tail:""}' \
  >> "$H_LOCAL/.quetrex/verify-ledger.jsonl"
jq -cn --arg sha "$H_HEAD_SHA" --arg cwd "$H_LOCAL" \
  '{ts:"2026-01-01T00:00:01Z",cmd:"echo ok",cwd:$cwd,sha:$sha,exit:0,tail:"ok"}' \
  >> "$H_LOCAL/.quetrex/verify-ledger.jsonl"
jq -cn --arg sha "$H_HEAD_SHA" \
  '{verdict:"AUTO_MERGE",sha:$sha,confirmed:[],inputs:{nativeSecurityReview:"clean"}}' \
  > "$H_LOCAL/.quetrex/review-verdict.json"

# H1 -- the fetch of the HEAD sha lies (exits 0, deposits nothing). The
# first cat-file -e (pre-fetch) correctly fails -- the object really is
# absent -- so the hook fetches; only the SECOND cat-file -e (post-fetch)
# can catch that the lie left it still absent.
#
# THE VACUITY THIS FIXES: both guards emit a deny containing "still is not
# present" -- H1/H2 originally asserted only that substring, which BOTH the
# head-side and base-side guard satisfy regardless of which one actually
# fired. A mutation that guts ONE guard while leaving the other intact would
# still pass, because the OTHER guard's identical wording masks it. Assert
# on "the head commit" / "the base commit" (the $label the deny message
# names) instead, so each test can only pass if ITS OWN guard fired.
OUT="$(run_hook_lying_fetch "$H_LOCAL" "$H_HEAD_SHA" "$H_BASE_SHA" "$H_HEAD_SHA")"; CODE=$?
if [ "$CODE" -eq 0 ] && is_deny "$OUT" && printf '%s' "$OUT" | grep -qi 'the head commit'; then
  pass "DEFECT H1: a fetch that exits 0 without depositing the HEAD commit is still caught -> DENIED"
else
  fail "DEFECT H1: expected a deny decision naming the HEAD commit as still absent, got exit $CODE stdout: [$OUT]"
fi

# H2 -- same lie, but about the BASE sha instead. The head fetches for real
# (it isn't in LYING_ABOUT), so this isolates the base-side guard.
OUT="$(run_hook_lying_fetch "$H_LOCAL" "$H_HEAD_SHA" "$H_BASE_SHA" "$H_BASE_SHA")"; CODE=$?
if [ "$CODE" -eq 0 ] && is_deny "$OUT" && printf '%s' "$OUT" | grep -qi 'the base commit'; then
  pass "DEFECT H2: a fetch that exits 0 without depositing the BASE commit is still caught -> DENIED"
else
  fail "DEFECT H2: expected a deny decision naming the BASE commit as still absent, got exit $CODE stdout: [$OUT]"
fi

# H3 -- control: with LYING_ABOUT empty (fetch is honest for both), the same
# fixture ships. Proves H1/H2 are really about the lie, not something else
# wrong with this fixture.
OUT="$(run_hook_lying_fetch "$H_LOCAL" "$H_HEAD_SHA" "$H_BASE_SHA" "")"; CODE=$?
if [ "$CODE" -eq 0 ] && [ -z "$OUT" ]; then
  pass "DEFECT H3 (control): an honest fetch of the same fixture ships normally"
else
  fail "DEFECT H3: expected exit 0 + empty stdout with an honest fetch, got exit $CODE stdout: [$OUT]"
fi

rm -rf "$H_ORIGIN" "$H_LOCAL" "$LYING_GIT_DIR"

# =============================================================================
# DEFECT A — the gate must fire on MERGES ONLY.
#
# It used to test the WHOLE command string for a `push` and, separately, for the
# token `main`. So pushing a feature branch and opening its PR in one line —
#   git -C /wt push -u origin claude/x && gh pr create --base main --head claude/x
# — was denied as a "push to main" because `--base main` belonged to the other
# sub-command. That denial happened twice in real use and trained the operator
# to route around the gate with `gh api`, which is strictly worse than no gate.
#
# The fixture is left in a DENYING state (stale ledger) for every case below, so
# an "allowed" result can only mean the command was never classified as a merge
# vector — not that the gates happened to pass.
# =============================================================================
write_ledger_at "0000000000000000000000000000000000000000"
write_verdict_at "$HEAD_SHA"

assert_allowed() {  # assert_allowed <label> <command>
  local out; out="$(run_cmd "$FIXTURE" "$2")"
  if is_deny "$out"; then
    fail "NOT A MERGE: $1 — must not be gated (got: ${out:0:160})"
  else
    pass "NOT A MERGE: $1 — correctly ungated"
  fi
}
assert_denied() {   # assert_denied <label> <command>
  local out; out="$(run_cmd "$FIXTURE" "$2")"
  if is_deny "$out"; then
    pass "IS A MERGE: $1 — correctly gated"
  else
    fail "IS A MERGE: $1 — must be gated but was allowed"
  fi
}

# --- the regression itself, and its neighbours: these must all be ALLOWED ----
assert_allowed "push a feature branch, then open its PR (--base $MAIN in the same line)" \
  "git -C $FIXTURE push -u origin claude/x && $GH_CREATE --base $MAIN --head claude/x"
assert_allowed "open a PR whose title mentions $MAIN" \
  "$GH_CREATE --base $MAIN --title 'merge the $MAIN docs'"
assert_allowed "plain feature-branch push" \
  "git -C $FIXTURE push -u origin claude/x"
assert_allowed "commit whose MESSAGE contains 'push origin $MAIN'" \
  "git -C $FIXTURE commit -m 'do not push origin $MAIN by hand'"
assert_allowed "a push with an = in a flag value (normalizer must not eat the git)" \
  "git -C $FIXTURE push --force-with-lease=refs/heads/claude/x origin claude/x"
assert_allowed "fetch/pull that merely name the base branch" \
  "git -C $FIXTURE fetch origin $MAIN"
assert_allowed "worktree teardown mentioning $MAIN" \
  "git -C $FIXTURE worktree remove /tmp/wt --force; git -C $FIXTURE branch -D claude/x"

# --- and these must all still be DENIED -------------------------------------
assert_denied "gh pr merge" "$GH_MERGE"
assert_denied "direct push to $MAIN" "git -C $FIXTURE push origin $MAIN"
assert_denied "refspec push to $MAIN" "git -C $FIXTURE push origin HEAD:refs/heads/$MAIN"
assert_denied "push to $MAIN hidden behind a leading assignment" \
  "GIT_TERMINAL_PROMPT=0 git -C $FIXTURE push origin $MAIN"
assert_denied "push to $MAIN wrapped in bash -c" \
  "bash -c 'git -C $FIXTURE push origin $MAIN'"
assert_denied "push to $MAIN after an exempt tag push in the same command" \
  "git -C $FIXTURE push origin v1.2.3 && git -C $FIXTURE push origin $MAIN"

# --- a tag push alone is still exempt ---------------------------------------
assert_allowed "tag push (deploy/version tag, not a merge)" \
  "git -C $FIXTURE push origin v2.0.5"

# =============================================================================
# DEFECT A2 — one repo's verdict must never gate another repo's merge.
#
# Observed in the wild: branch cleanup in quetrex-plugins denied by quetrex-base's
# stale review-verdict.json, because the repo was resolved from the SESSION's
# project dir instead of the directory the command names.
# =============================================================================
OTHER="$(mktemp -d "${TMPDIR:-/tmp}/merge-gate-other.XXXXXX")"
git -C "$OTHER" init -q -b main
git -C "$OTHER" config user.email "test@example.com"
git -C "$OTHER" config user.name "Fixture"
echo other > "$OTHER/README.md"
git -C "$OTHER" add README.md
git -C "$OTHER" commit -q -m "chore: other repo"
# NOTE: $OTHER has no .quetrex/ at all -> it is not a quetrex-managed repo.

OUT="$(run_cmd "$FIXTURE" "git -C $OTHER push origin $MAIN")"
if is_deny "$OUT"; then
  fail "CROSS-REPO: a push in an unmanaged repo must not be judged by THIS repo's verdict (got: ${OUT:0:160})"
else
  pass "CROSS-REPO: a push in another (unmanaged) repo is not gated by this repo's artifacts"
fi
rm -rf "$OTHER"

# A gh pr merge naming a DIFFERENT repository is refused outright rather than
# judged by these artifacts — it is a merge, so it fails closed, but with an
# accurate reason instead of a foreign repo's REWORK.
git -C "$FIXTURE" remote add origin "https://github.com/acme/fixture-repo.git" 2>/dev/null || true
OUT="$(run_cmd "$FIXTURE" "$(printf 'gh pr mer%s' 'ge') 7 --squash --repo other-org/other-repo")"
if is_deny "$OUT" && printf '%s' "$OUT" | grep -q 'other-org/other-repo'; then
  pass "CROSS-REPO: gh pr merge --repo <other repo> is refused, naming the mismatch"
else
  fail "CROSS-REPO: gh pr merge --repo <other repo> should be refused with the mismatch named (got: ${OUT:0:200})"
fi
OUT="$(run_cmd "$FIXTURE" "$(printf 'gh pr mer%s' 'ge') 7 --squash --repo acme/fixture-repo")"
if printf '%s' "$OUT" | grep -q 'other-org\|cannot evaluate this merge'; then
  fail "CROSS-REPO: --repo matching this repo's own origin must be gated normally, not refused as foreign"
else
  pass "CROSS-REPO: --repo matching this repo's origin is gated normally"
fi

# THE GAP: the refusal above matched only the LONG form `--repo`. `-R` is the
# exact same flag (gh's own --help lists it as an INHERITED flag alongside
# --repo), so `gh pr merge -R other-org/other-repo 7 --squash` bypassed the
# refusal entirely and would have been evaluated against THIS repo's
# artifacts -- a live cross-repo authorization leak, not just a missed
# detection.
OUT="$(run_cmd "$FIXTURE" "$(printf 'gh pr mer%s' 'ge') 7 --squash -R other-org/other-repo")"
if is_deny "$OUT" && printf '%s' "$OUT" | grep -q 'other-org/other-repo'; then
  pass "CROSS-REPO: gh pr merge -R <other repo> (spaced short form) is refused, naming the mismatch"
else
  fail "CROSS-REPO: gh pr merge -R <other repo> (spaced) should be refused with the mismatch named, got: ${OUT:0:200}"
fi

# THE REMAINING GAP (verified against real gh 2.97.0): `-R` also accepts an
# ATTACHED value (`-Rowner/repo`, no separator) and an `=`-joined value
# (`-R=owner/repo`) -- a regex requiring whitespace after `-R` catches only
# the spaced form and lets these two straight through.
OUT="$(run_cmd "$FIXTURE" "$(printf 'gh pr mer%s' 'ge') 7 --squash -Rother-org/other-repo")"
if is_deny "$OUT" && printf '%s' "$OUT" | grep -q 'other-org/other-repo'; then
  pass "CROSS-REPO: gh pr merge -Rother-org/other-repo (attached short form) is refused, naming the mismatch"
else
  fail "CROSS-REPO: gh pr merge -Rother-org/other-repo (attached) should be refused with the mismatch named, got: ${OUT:0:200}"
fi
OUT="$(run_cmd "$FIXTURE" "$(printf 'gh pr mer%s' 'ge') 7 --squash -R=other-org/other-repo")"
if is_deny "$OUT" && printf '%s' "$OUT" | grep -q 'other-org/other-repo'; then
  pass "CROSS-REPO: gh pr merge -R=other-org/other-repo (= short form) is refused, naming the mismatch"
else
  fail "CROSS-REPO: gh pr merge -R=other-org/other-repo (=) should be refused with the mismatch named, got: ${OUT:0:200}"
fi

# =============================================================================
# DEFECT I — REGEXING gh's argv loses to pflag; TOKENIZE and WALK it instead.
#
# Five review rounds found five new spellings of the same hole because every
# prior version matched a pattern against the whole command STRING. gh's
# real flag parser (pflag) understands separated/attached/=-joined forms,
# CLUSTERED short flags, and "last flag wins" for a repeated flag — none of
# which a regex over the raw string can represent. Fixed by tokenizing the
# segment (quote-aware, no eval) and walking the tokens like pflag does.
# Every case below was verified end-to-end against the real hook with a
# fixture whose origin is acme/fixture-repo — same shape as the CROSS-REPO
# cases just above, reusing the same fixture/origin state.
# =============================================================================

# --- I1-I3: short-flag CLUSTERING. `-dR<repo>` is --delete-branch + --repo;
# a regex requiring a literal "-" immediately before "R" never matches
# because the preceding character is "d", not "-".
OUT="$(run_cmd "$FIXTURE" "$(printf 'gh pr mer%s' 'ge') 7 --squash -dRother-org/other-repo")"
if is_deny "$OUT" && printf '%s' "$OUT" | grep -q 'other-org/other-repo'; then
  pass "DEFECT I1: -dRother-org/other-repo (clustered, attached) is refused, naming the mismatch"
else
  fail "DEFECT I1: expected refusal naming other-org/other-repo, got: ${OUT:0:200}"
fi
OUT="$(run_cmd "$FIXTURE" "$(printf 'gh pr mer%s' 'ge') 7 --squash -dR other-org/other-repo")"
if is_deny "$OUT" && printf '%s' "$OUT" | grep -q 'other-org/other-repo'; then
  pass "DEFECT I2: -dR other-org/other-repo (clustered, spaced) is refused, naming the mismatch"
else
  fail "DEFECT I2: expected refusal naming other-org/other-repo, got: ${OUT:0:200}"
fi
OUT="$(run_cmd "$FIXTURE" "$(printf 'gh pr mer%s' 'ge') 7 --squash -sdRother-org/other-repo")"
if is_deny "$OUT" && printf '%s' "$OUT" | grep -q 'other-org/other-repo'; then
  pass "DEFECT I3: -sdRother-org/other-repo (triple cluster) is refused, naming the mismatch"
else
  fail "DEFECT I3: expected refusal naming other-org/other-repo, got: ${OUT:0:200}"
fi

# --- I4: REPEATED -R. bash's [[ =~ ]] is leftmost-match, so a naive regex
# captures the FIRST occurrence; real gh (and this fix) honors the LAST.
OUT="$(run_cmd "$FIXTURE" "$(printf 'gh pr mer%s' 'ge') -R acme/fixture-repo 7 --squash -R other-org/other-repo")"
if is_deny "$OUT" && printf '%s' "$OUT" | grep -q 'other-org/other-repo'; then
  pass "DEFECT I4: repeated -R (acme/fixture-repo then other-org/other-repo) honors the LAST, refused"
else
  fail "DEFECT I4: expected refusal naming other-org/other-repo (the LAST -R), got: ${OUT:0:200}"
fi

# --- I5-I8: THE ROUND-4 REGRESSION. `-R[[:space:]=]?` matched ANY "-R"
# substring anywhere in the segment, including inside another flag's quoted
# VALUE. Fail-closed (a false refusal, not a leak) but still cries wolf with
# a nonexistent repo name the operator can't act on. Tokenizing fixes this
# structurally: a flag's value is a single opaque token, never re-scanned
# for "-R"-shaped substrings.
OUT="$(run_cmd "$FIXTURE" "$(printf 'gh pr mer%s' 'ge') 7 --squash -t 'chore: post-Review cleanup'")"
if is_deny "$OUT" && printf '%s' "$OUT" | grep -qi 'this command merges a PR in'; then
  fail "DEFECT I5: -t with 'post-Review' in the value must NOT be read as -R, got: ${OUT:0:220}"
else
  pass "DEFECT I5: -t 'chore: post-Review cleanup' -- 'Review' in a quoted value is not mistaken for -R"
fi
OUT="$(run_cmd "$FIXTURE" "$(printf 'gh pr mer%s' 'ge') 7 --squash -b 'ship pre-Release build'")"
if is_deny "$OUT" && printf '%s' "$OUT" | grep -qi 'this command merges a PR in'; then
  fail "DEFECT I6: -b with 'pre-Release' in the value must NOT be read as -R, got: ${OUT:0:220}"
else
  pass "DEFECT I6: -b 'ship pre-Release build' -- 'Release' in a quoted value is not mistaken for -R"
fi
OUT="$(run_cmd "$FIXTURE" "$(printf 'gh pr mer%s' 'ge') 7 --squash -A 'a-Robot@example.com'")"
if is_deny "$OUT" && printf '%s' "$OUT" | grep -qi 'this command merges a PR in'; then
  fail "DEFECT I7: -A with 'a-Robot' in the value must NOT be read as -R, got: ${OUT:0:220}"
else
  pass "DEFECT I7: -A 'a-Robot@example.com' -- 'Robot' in a quoted value is not mistaken for -R"
fi
OUT="$(run_cmd "$FIXTURE" "$(printf 'gh pr mer%s' 'ge') 7 --squash -F 'notes-Regarding-the-change.txt'")"
if is_deny "$OUT" && printf '%s' "$OUT" | grep -qi 'this command merges a PR in'; then
  fail "DEFECT I8: -F with 'notes-Regarding' in the value must NOT be read as -R, got: ${OUT:0:220}"
else
  pass "DEFECT I8: -F 'notes-Regarding-the-change.txt' -- 'Regarding' in a quoted value is not mistaken for -R"
fi

# --- I9-I10: the PR IDENTIFIER as a URL names a repo too.
OUT="$(run_cmd "$FIXTURE" "$(printf 'gh pr mer%s' 'ge') https://github.com/other-org/other-repo/pull/7 --squash")"
if is_deny "$OUT" && printf '%s' "$OUT" | grep -q 'other-org/other-repo'; then
  pass "DEFECT I9: a PR URL naming other-org/other-repo is refused, naming the mismatch"
else
  fail "DEFECT I9: expected refusal naming other-org/other-repo, got: ${OUT:0:200}"
fi
OUT="$(run_cmd "$FIXTURE" "$(printf 'gh pr mer%s' 'ge') https://github.com/acme/fixture-repo/pull/7 --squash")"
if printf '%s' "$OUT" | grep -qi 'other-org\|cannot evaluate this merge\|could not confidently parse'; then
  fail "DEFECT I10: a PR URL matching this repo's own origin must be gated normally, not refused as foreign, got: ${OUT:0:200}"
else
  pass "DEFECT I10: a PR URL matching this repo's own origin is gated normally"
fi

# --- I11-I12: an INHERITED (exported) GH_REPO -- gh reads this env var
# itself when no --repo/-R flag is on the command line at all.
OUT="$(run_cmd "$FIXTURE" "$(printf 'gh pr mer%s' 'ge') 7 --squash" "" "" "" "other-org/other-repo")"
if is_deny "$OUT" && printf '%s' "$OUT" | grep -q 'other-org/other-repo'; then
  pass "DEFECT I11: inherited GH_REPO=other-org/other-repo (no flag on the command) is refused"
else
  fail "DEFECT I11: expected refusal naming other-org/other-repo from inherited GH_REPO, got: ${OUT:0:200}"
fi
OUT="$(run_cmd "$FIXTURE" "$(printf 'gh pr mer%s' 'ge') 7 --squash" "" "" "" "acme/fixture-repo")"
if printf '%s' "$OUT" | grep -qi 'other-org\|cannot evaluate this merge\|could not confidently parse'; then
  fail "DEFECT I12: inherited GH_REPO matching this repo's own origin must be gated normally, got: ${OUT:0:200}"
else
  pass "DEFECT I12: inherited GH_REPO matching this repo's own origin is gated normally"
fi

# --- I13: CONFLICTING signals -- a --repo flag and a PR URL naming
# DIFFERENT repos. Refuse as ambiguous rather than silently picking one;
# either guess could be the one gh actually honors.
OUT="$(run_cmd "$FIXTURE" "$(printf 'gh pr mer%s' 'ge') https://github.com/other-org/other-repo/pull/7 --repo acme/fixture-repo --squash")"
if is_deny "$OUT" && printf '%s' "$OUT" | grep -qi 'disagree\|ambiguous'; then
  pass "DEFECT I13: conflicting repo selectors (flag vs PR URL) refused as ambiguous, not guessed"
else
  fail "DEFECT I13: expected an ambiguous-selectors refusal, got: ${OUT:0:200}"
fi

# --- I14: FAIL CLOSED on anything unparseable -- an unrecognized flag shape
# denies the WHOLE merge rather than silently ignoring the unknown token.
OUT="$(run_cmd "$FIXTURE" "$(printf 'gh pr mer%s' 'ge') 7 --squash --this-flag-does-not-exist")"
if is_deny "$OUT" && printf '%s' "$OUT" | grep -qi 'could not confidently parse'; then
  pass "DEFECT I14: an unrecognized flag denies the merge outright (fail closed), not guessed at"
else
  fail "DEFECT I14: expected a 'could not confidently parse' refusal, got: ${OUT:0:200}"
fi

# --- I15: positive control -- clustering that resolves to THIS repo's own
# origin must NOT be refused. Proves I1-I3 deny because of the FOREIGN repo,
# not merely because clustering was used at all.
OUT="$(run_cmd "$FIXTURE" "$(printf 'gh pr mer%s' 'ge') 7 --squash -dRacme/fixture-repo")"
if printf '%s' "$OUT" | grep -qi 'other-org\|cannot evaluate this merge\|could not confidently parse'; then
  fail "DEFECT I15: -dRacme/fixture-repo (clustered, matches origin) must be gated normally, got: ${OUT:0:200}"
else
  pass "DEFECT I15: -dRacme/fixture-repo (clustered, matches origin) is gated normally"
fi

# =============================================================================
# DEFECT J — the leak class moved UP a layer: the SEGMENT SPLITTER feeding
# the (now-correct) tokenizer a truncated or corrupted string. Four
# confirmed defects, all verified against the real hook with green
# artifacts and a fixture whose origin is acme/fixture-repo (same as the
# CROSS-REPO/DEFECT I state above, reused here before it's torn down).
# =============================================================================
GHM_TOK="$(printf 'gh pr mer%s' 'ge')"

# --- J1: backslash-newline CONTINUATION. A real shell removes `\<newline>`
# entirely before doing anything else; the old splitter read line-by-line
# and never saw line 2 at all, losing the --repo flag (and, if the PR id
# were on line 2, the identifier too).
J1_CMD="${GHM_TOK}"$' 7 \\\n  --repo other-org/other-repo --squash'
OUT="$(run_cmd "$FIXTURE" "$J1_CMD")"
if is_deny "$OUT" && printf '%s' "$OUT" | grep -q 'other-org/other-repo'; then
  pass "DEFECT J1: --repo on a backslash-continued line 2 is refused, naming the mismatch"
else
  fail "DEFECT J1: expected refusal naming other-org/other-repo, got: ${OUT:0:200}"
fi

# --- J2-J3: INLINE / env(1)-wrapped GH_REPO=, in the SAME command text.
# normalize_segment strips a leading VAR=value prefix by design (so a real
# vector still anchors on the actual invocation); the round-4 fix only
# checked the hook's OWN inherited environment, never an assignment sitting
# right there in the command it was already looking at.
OUT="$(run_cmd "$FIXTURE" "GH_REPO=other-org/other-repo ${GHM_TOK} 7 --squash")"
if is_deny "$OUT" && printf '%s' "$OUT" | grep -q 'other-org/other-repo'; then
  pass "DEFECT J2: inline GH_REPO=other-org/other-repo is refused, naming the mismatch"
else
  fail "DEFECT J2: expected refusal naming other-org/other-repo, got: ${OUT:0:200}"
fi
OUT="$(run_cmd "$FIXTURE" "env GH_REPO=other-org/other-repo ${GHM_TOK} 7 --squash")"
if is_deny "$OUT" && printf '%s' "$OUT" | grep -q 'other-org/other-repo'; then
  pass "DEFECT J3: env GH_REPO=other-org/other-repo is refused, naming the mismatch"
else
  fail "DEFECT J3: expected refusal naming other-org/other-repo, got: ${OUT:0:200}"
fi

# --- J4: THE DOCUMENTED BOUNDARY. `export GH_REPO=x;` on an EARLIER segment
# of the SAME line needs cross-segment variable tracking this hook does not
# do (see the boundary comment near the top of the file) -- explicitly OUT
# OF BOUNDS, not silently missed. This assertion guards the DOCUMENTATION as
# much as the code: if this ever starts passing, the boundary comment
# describing it as uncovered needs updating too.
OUT="$(run_cmd "$FIXTURE" "export GH_REPO=other-org/other-repo; ${GHM_TOK} 7 --squash")"
if printf '%s' "$OUT" | grep -q 'other-org/other-repo'; then
  fail "DEFECT J4: export-prefixed GH_REPO is documented as OUT OF BOUNDS but was caught -- update the boundary comment to match, got: ${OUT:0:200}"
else
  pass "DEFECT J4 (documents the boundary): export GH_REPO=x; on an earlier segment is NOT caught by this mechanism, as documented"
fi

# --- J5: the QUOTE-BLIND SPLITTER regression. The awk gsub ran before any
# quote tracking existed, splitting `-t 'build && test'` mid-quote and
# corrupting a legitimate command into an unparseable one -- a false
# refusal, not a leak, but the segment splitter must not corrupt a
# well-formed command in the first place.
OUT="$(run_cmd "$FIXTURE" "${GHM_TOK} 7 --squash -t 'build && test'")"
if printf '%s' "$OUT" | grep -qi 'could not confidently parse'; then
  fail "DEFECT J5: -t 'build && test' must not be corrupted into an unparseable command, got: ${OUT:0:200}"
else
  pass "DEFECT J5: -t 'build && test' -- '&&' inside a quoted value does not split the segment"
fi

# --- J6: UNEXPANDED \$VAR in the --repo VALUE position -- the shape THIS
# ENGINE'S OWN /quetrex:merge command emits (.claude/commands/merge.md:138:
# a `gh pr merge "$PR_NUM" --repo "$SLUG" --squash --delete-branch` line).
# Decided FAIL OPEN for this narrow case (see looks_like_shell_expr's call
# site for the full reasoning) -- treated as NO signal from this flag, not
# a literal repo name, so the engine's own merge command can actually pass
# its own gate. Proven as a FULL end-to-end ALLOW, not just "not refused as
# cross-repo" -- the whole point is that this command must be mergeable.
J6_HEAD="$(git -C "$FIXTURE" rev-parse HEAD)"
write_ledger_at "$J6_HEAD"
write_verdict_at "$J6_HEAD"
rm -f "$FIXTURE/.quetrex/security-findings.json" "$FIXTURE/.quetrex/ESCALATION"
J6_CMD='PR_NUM=7; SLUG=acme/fixture-repo; '"${GHM_TOK}"' "$PR_NUM" --repo "$SLUG" --squash --delete-branch'
OUT="$(run_cmd "$FIXTURE" "$J6_CMD" "$J6_HEAD")"
if [ -z "$OUT" ]; then
  pass "DEFECT J6 (the engine's own merge command): unexpanded \$SLUG in --repo is treated as unknown, not a foreign repo -- ships"
else
  fail "DEFECT J6: expected this engine's own merge.md pattern to ship (empty stdout), got: ${OUT:0:220}"
fi

# --- J7: a trailing shell COMMENT containing flag-shaped text must not be
# read as a real flag -- the same over-match class as J5/finding-4, just a
# `#` instead of a quote.
OUT="$(run_cmd "$FIXTURE" "${GHM_TOK} 7 --squash # note: see --repo change" "$J6_HEAD")"
if [ -z "$OUT" ]; then
  pass "DEFECT J7: a trailing '# ... --repo ...' comment is not read as a real --repo flag -- ships"
else
  fail "DEFECT J7: expected the trailing comment to be inert (empty stdout), got: ${OUT:0:220}"
fi

# --- J8-J9: PIN the short-flag fail-closed branch (gh_merge_short_kind's
# "unknown" case, walked inside parse_gh_pr_merge's cluster loop). Provably
# non-vacuous: mutating that branch to a no-op must break these, not just
# leave it unexercised the way the long-flag branch alone would.
OUT="$(run_cmd "$FIXTURE" "${GHM_TOK} 7 --squash -Z")"
if is_deny "$OUT" && printf '%s' "$OUT" | grep -qi 'could not confidently parse'; then
  pass "DEFECT J8: an unrecognized SHORT flag (-Z) fails closed"
else
  fail "DEFECT J8: expected a 'could not confidently parse' refusal, got: ${OUT:0:200}"
fi
OUT="$(run_cmd "$FIXTURE" "${GHM_TOK} 7 --squash -dZ")"
if is_deny "$OUT" && printf '%s' "$OUT" | grep -qi 'could not confidently parse'; then
  pass "DEFECT J9: an unrecognized SHORT flag inside a cluster (-dZ) fails closed"
else
  fail "DEFECT J9: expected a 'could not confidently parse' refusal, got: ${OUT:0:200}"
fi

git -C "$FIXTURE" remote remove origin 2>/dev/null || true

# =============================================================================
# DEFECT B — AUTO_MERGE must be REACHABLE.
#
# GATE 2b required inputs.nativeSecurityReview == clean|issues. That field can
# only be filled by running /security-review, a SlashCommand the reviewer
# subagent does not have at runtime ("my tool set is Read and Bash only"). So
# the field was structurally unfillable, every clean pipeline was denied, and
# every merge was performed by hand -- which is also why tasks stranded in
# in_progress with none of the post-merge bookkeeping run.
#
# Independence may now be proven by the INDEPENDENT security-reviewer artifact
# instead. Everything below keeps the ledger green and pinned to HEAD, so the
# only variable is how independence is (or is not) established.
# =============================================================================
write_ledger_at "$HEAD_SHA"

# B1 — THE FIX: native pass unavailable, but the independent security-reviewer
#      artifact is pinned to HEAD and clean -> AUTO_MERGE is honored.
write_verdict_at "$HEAD_SHA" "not_available_in_env"
write_sec "$HEAD_SHA" none
OUT="$(run_hook "$FIXTURE")"; CODE=$?
if [ "$CODE" -eq 0 ] && [ -z "$OUT" ]; then
  pass "ALLOW (the deadlock fix): independent HEAD-pinned clean security artifact satisfies GATE 2b"
else
  fail "ALLOW(independent artifact): expected exit 0 + empty stdout, got exit $CODE stdout: [$OUT]"
fi

# B2 — the artifact is clean but pinned to a DIFFERENT commit -> still denied.
write_sec "1111111111111111111111111111111111111111" none
OUT="$(run_hook "$FIXTURE")"
if is_deny "$OUT"; then
  pass "DENY: a STALE security artifact cannot stand in for the native pass"
else
  fail "DENY(stale artifact): expected a deny decision, got [$OUT]"
fi

# B3 — the artifact records no head_sha at all -> proves nothing, denied.
#      GATE 2b only; the drifted factory copy treats head_sha as optional.
if [ "$GATE_PROFILE" = "full" ]; then
jq -cn '{task:"T-1",base:"main",reviewed_files:3,verdict:"PASS",findings:[]}' \
  > "$FIXTURE/.quetrex/security-findings.json"
OUT="$(run_hook "$FIXTURE")"
if is_deny "$OUT"; then
  pass "DENY: an UNPINNED security artifact cannot stand in for the native pass"
else
  fail "DENY(unpinned artifact): expected a deny decision, got [$OUT]"
fi
fi

# B4 — an open Critical still blocks, whichever way independence was proven.
write_sec "$HEAD_SHA" critical open
OUT="$(run_hook "$FIXTURE")"
if is_deny "$OUT"; then
  pass "DENY: an open Critical still blocks (unbypassable, as before)"
else
  fail "DENY(open critical): expected a deny decision, got [$OUT]"
fi

# B5 — a RESOLVED critical is not an open one; the merge proceeds.
write_sec "$HEAD_SHA" critical resolved
OUT="$(run_hook "$FIXTURE")"; CODE=$?
if [ "$CODE" -eq 0 ] && [ -z "$OUT" ]; then
  pass "ALLOW: a RESOLVED critical does not block"
else
  fail "ALLOW(resolved critical): expected exit 0 + empty stdout, got exit $CODE stdout: [$OUT]"
fi

# B6 — neutral diff, no plan flag, no artifact: there is no security review to
#      be independent about, so AUTO_MERGE stands.
rm -f "$FIXTURE/.quetrex/security-findings.json"
OUT="$(run_hook "$FIXTURE")"; CODE=$?
if [ "$CODE" -eq 0 ] && [ -z "$OUT" ]; then
  pass "ALLOW: neutral diff with no security review required -> AUTO_MERGE stands"
else
  fail "ALLOW(neutral diff): expected exit 0 + empty stdout, got exit $CODE stdout: [$OUT]"
fi

# B7 — but when the PLAN demands a security review, a missing artifact still
#      denies. Omission must never be the cheap way past this gate.
mkdir -p "$FIXTURE/.quetrex/plan"
jq -cn '{task:"T-1",security_review_required:true,ownership:{"README.md":"ws-a"}}' \
  > "$FIXTURE/.quetrex/plan/T-1.json"
jq -cn '{task:"T-1"}' > "$FIXTURE/.quetrex/state.json"
OUT="$(run_hook "$FIXTURE")"
if is_deny "$OUT"; then
  pass "DENY: plan requires a security review, artifact missing -> denied"
else
  fail "DENY(required but missing): expected a deny decision, got [$OUT]"
fi

# B8 — and the native pass, when it genuinely ran, still works on its own.
rm -rf "$FIXTURE/.quetrex/plan" "$FIXTURE/.quetrex/state.json"
write_verdict_at "$HEAD_SHA" "issues"
OUT="$(run_hook "$FIXTURE")"; CODE=$?
if [ "$CODE" -eq 0 ] && [ -z "$OUT" ]; then
  pass "ALLOW: a genuinely executed native /security-review still authorizes on its own"
else
  fail "ALLOW(native ran): expected exit 0 + empty stdout, got exit $CODE stdout: [$OUT]"
fi

# B9 — the sharpened form of the old test 5, and the one that matters: when the
#      DIFF ITSELF is sensitive, the diff-derived floor requires an independent
#      pass, so AUTO_MERGE + native-not-run + no artifact is still denied. The
#      reviewer cannot self-exempt on code that touches a sensitive surface.
#      Runs last because it moves HEAD.
mkdir -p "$FIXTURE/src/session"
cat > "$FIXTURE/src/session/auth.ts" <<'TS'
export function authenticate(token: string) { return token.length > 0; }
TS
git -C "$FIXTURE" add src/session/auth.ts
git -C "$FIXTURE" commit -q -m "feat: add an auth surface"
HEAD_SHA2="$(git -C "$FIXTURE" rev-parse HEAD)"
write_ledger_at "$HEAD_SHA2"
write_verdict_at "$HEAD_SHA2" "not_available_in_env"
rm -f "$FIXTURE/.quetrex/security-findings.json"

OUT="$(run_hook "$FIXTURE")"
if is_deny "$OUT"; then
  pass "DENY: a SENSITIVE diff with no independent security pass is still denied"
else
  fail "DENY(sensitive diff, no security pass): expected a deny decision, got [$OUT]"
fi

# B10 — same sensitive diff, but the independent security-reviewer artifact is
#       present, pinned and clean -> it ships. This is the end-to-end shape of a
#       real clean pipeline, which before this fix could not merge at all.
write_sec "$HEAD_SHA2" none
OUT="$(run_hook "$FIXTURE")"; CODE=$?
if [ "$CODE" -eq 0 ] && [ -z "$OUT" ]; then
  pass "ALLOW: sensitive diff + independent pinned clean security artifact -> ships"
else
  fail "ALLOW(sensitive diff w/ artifact): expected exit 0 + empty stdout, got exit $CODE stdout: [$OUT]"
fi

# =============================================================================
# DEFECT Q — artifact-only commits must not self-invalidate an approval.
#
# (Renamed from this section's original "DEFECT C" label on merge with main
# -- a companion fix landed there independently while this branch's own
# lettering had already reached P; kept as Q rather than renumbering
# anything else, since every letter below already appears in commit
# messages and prior review rounds.)
#
# Every sha-pin this gate trusts (review-verdict.json's .sha,
# security-findings.json's .head_sha, each verify-ledger.jsonl entry's .sha)
# is an artifact NAMING the commit it approves. Per git-workflow.md these are
# runtime control-plane files that must never be committed (.gitignore should
# ignore .quetrex/* and un-ignore only project.json/verify.json). When a
# repo's gitignore drifts from that and one of these DOES get committed, the
# commit that adds it moves HEAD -- and the artifact's own pin, recorded
# before that commit existed, can never equal HEAD again. A strict
# sha-equality check then denies every subsequent operation forever,
# including the commit that would remove the artifact and repair the
# mistake: the gate blocks its own repair.
#
# THE FIX: an old pin still authorizes HEAD when (a) it is an ANCESTOR of HEAD
# and (b) every commit in old..HEAD touches NOTHING outside .quetrex/. A
# single commit touching anything else anywhere in the range disqualifies the
# whole range -- code changed, so the deny must still fire exactly as before.
#
# Builds a small commit graph on top of $HEAD_SHA (call it C0):
#   C0 -- C1 (touches only .quetrex/notes.txt)
#            \-- C2 (touches .quetrex/notes.txt AND src/code.ts)
#   C0 -- C3 (touches only src/code.ts)                          [sibling]
#   C0 -- C4 (touches .quetrexfoo/evil.txt — a LOOKALIKE prefix)  [sibling]
#   C0 -- C4B (touches src/.quetrex/nested.txt — a NESTED lookalike) [sibling]
#   C0 -- D  (a divergent commit, NOT an ancestor of C1/C2/C3/C4)
#
# Every case pins RV/ledger/sec to C0 (older than current HEAD) and asks:
# does the range from C0 to the new HEAD still count as artifact-only?
# =============================================================================
reset_clean_baseline() {  # reset_clean_baseline <sha> — pin RV/ledger/sec, drop ESCALATION
  write_ledger_at "$1"
  write_verdict_at "$1"
  write_sec "$1" none
  rm -f "$FIXTURE/.quetrex/ESCALATION"
}

C0="$HEAD_SHA"

git -C "$FIXTURE" checkout -q -b branch-c1 "$C0"
mkdir -p "$FIXTURE/.quetrex" "$FIXTURE/src"
echo "note 1" > "$FIXTURE/.quetrex/notes.txt"
git -C "$FIXTURE" add .quetrex/notes.txt
git -C "$FIXTURE" commit -q -m "chore: pipeline artifact commit"
C1="$(git -C "$FIXTURE" rev-parse HEAD)"

echo "note 2" > "$FIXTURE/.quetrex/notes.txt"
echo "console.log('hi')" > "$FIXTURE/src/code.ts"
git -C "$FIXTURE" add .quetrex/notes.txt src/code.ts
git -C "$FIXTURE" commit -q -m "feat: real code change alongside an artifact update"
C2="$(git -C "$FIXTURE" rev-parse HEAD)"

git -C "$FIXTURE" checkout -q -b branch-c3 "$C0"
mkdir -p "$FIXTURE/src"
echo "console.log('code only')" > "$FIXTURE/src/code.ts"
git -C "$FIXTURE" add src/code.ts
git -C "$FIXTURE" commit -q -m "feat: code-only change"
C3="$(git -C "$FIXTURE" rev-parse HEAD)"

# Two SEPARATE lookalike commits, each in isolation, so a mutation that only
# breaks one form of the anchor check (e.g. a naive prefix test that still
# rejects a nested path but accepts an unslashed sibling-name prefix) cannot
# hide behind the other lookalike disqualifying the range on its own.
git -C "$FIXTURE" checkout -q -b branch-c4 "$C0"
mkdir -p "$FIXTURE/.quetrexfoo"
echo "evil" > "$FIXTURE/.quetrexfoo/evil.txt"
git -C "$FIXTURE" add .quetrexfoo/evil.txt
git -C "$FIXTURE" commit -q -m "chore: a sibling directory name that LOOKS like a .quetrex/ prefix"
C4="$(git -C "$FIXTURE" rev-parse HEAD)"

git -C "$FIXTURE" checkout -q -b branch-c4b "$C0"
mkdir -p "$FIXTURE/src/.quetrex"
echo "evil" > "$FIXTURE/src/.quetrex/nested.txt"
git -C "$FIXTURE" add src/.quetrex/nested.txt
git -C "$FIXTURE" commit -q -m "chore: a NESTED .quetrex/ that is not the repo-root one"
C4B="$(git -C "$FIXTURE" rev-parse HEAD)"

git -C "$FIXTURE" checkout -q -b branch-d "$C0"
echo "divergent" > "$FIXTURE/DIVERGENT.md"
git -C "$FIXTURE" add DIVERGENT.md
git -C "$FIXTURE" commit -q -m "chore: an unrelated sibling commit"
D="$(git -C "$FIXTURE" rev-parse HEAD)"

# --- C1: artifact-only commit -> ACCEPTED (RV, ledger, and sec all forgive) -
git -C "$FIXTURE" checkout -q branch-c1  # HEAD = C1
git -C "$FIXTURE" reset -q --hard "$C1"
reset_clean_baseline "$C0"
OUT="$(run_hook "$FIXTURE")"; CODE=$?
if [ "$CODE" -eq 0 ] && [ -z "$OUT" ]; then
  pass "ALLOW: artifact-only commit since the pinned sha -> approval still stands"
else
  fail "ALLOW(artifact-only): expected exit 0 + empty stdout, got exit $CODE stdout: [$OUT]"
fi

# --- C2: mixed artifact+code commit in the range -> DENIED ------------------
git -C "$FIXTURE" reset -q --hard "$C2"
reset_clean_baseline "$C0"
OUT="$(run_hook "$FIXTURE")"
if is_deny "$OUT"; then
  pass "DENY: a commit touching .quetrex/ AND code in the range disqualifies it"
else
  fail "DENY(mixed commit): expected a deny decision, got [$OUT]"
fi

# --- C3: code-only commit in the range -> DENIED -----------------------------
git -C "$FIXTURE" checkout -q branch-c3
reset_clean_baseline "$C0"
OUT="$(run_hook "$FIXTURE")"
if is_deny "$OUT"; then
  pass "DENY: a code-only commit since the pinned sha is a genuine stale approval"
else
  fail "DENY(code-only): expected a deny decision, got [$OUT]"
fi

# --- C4: lookalike-path commit (.quetrexfoo/) -> DENIED --------------------
# Isolates the ANCHOR: ".quetrexfoo" shares the literal prefix ".quetrex" but
# is not followed by "/", so a naive (unanchored) prefix test would wrongly
# accept it.
git -C "$FIXTURE" checkout -q branch-c4
reset_clean_baseline "$C0"
OUT="$(run_hook "$FIXTURE")"
if is_deny "$OUT"; then
  pass "DENY: .quetrexfoo/ is NOT the .quetrex/ directory (anchor, not naive prefix)"
else
  fail "DENY(lookalike sibling path): expected a deny decision, got [$OUT]"
fi

# --- C4B: lookalike-path commit (src/.quetrex/) -> DENIED -------------------
# Isolates NESTING: a .quetrex/ directory that is not at the repo root must
# not count as the control-plane directory this gate exempts.
git -C "$FIXTURE" checkout -q branch-c4b
reset_clean_baseline "$C0"
OUT="$(run_hook "$FIXTURE")"
if is_deny "$OUT"; then
  pass "DENY: src/.quetrex/ (nested) is NOT the repo-root .quetrex/ directory"
else
  fail "DENY(nested lookalike path): expected a deny decision, got [$OUT]"
fi

# --- D: non-ancestor sha pinned -> DENIED ------------------------------------
# Deliberately isolated from the path-scope check: D and C1 are SIBLINGS (both
# children of C0), and the naive rev-list range "D..C1" (ignoring ancestry
# altogether) contains only C1, which IS artifact-only on its own. So this
# case can ONLY be caught by actually verifying D is an ancestor of C1 — a
# range that merely LOOKS artifact-only when walked without that check must
# still be denied.
git -C "$FIXTURE" checkout -q branch-c1
git -C "$FIXTURE" reset -q --hard "$C1"   # HEAD = C1 (artifact-only on its own)
reset_clean_baseline "$D"                 # D is a SIBLING, not an ancestor of C1
OUT="$(run_hook "$FIXTURE")"
if is_deny "$OUT"; then
  pass "DENY: a pinned sha that is not an ancestor of HEAD is never forgiven (even when the naive range looks artifact-only)"
else
  fail "DENY(non-ancestor): expected a deny decision, got [$OUT]"
fi

git -C "$FIXTURE" reset -q --hard "$C2"   # leave HEAD at C2 for the tests below

# --- unresolvable sha (missing object / shallow-clone stand-in) -> DENIED ---
# A well-formed 40-hex sha that was never committed to this fixture repo at
# all. This is the fail-closed path: the ancestry check cannot even resolve
# the object, so it must never be treated as "safe".
GARBAGE_SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
reset_clean_baseline "$GARBAGE_SHA"
OUT="$(run_hook "$FIXTURE")"
if is_deny "$OUT"; then
  pass "DENY: an unresolvable sha (missing object) fails closed"
else
  fail "DENY(unresolvable sha): expected a deny decision, got [$OUT]"
fi

# --- same forgiveness must apply to a MERGE COMMIT in the range -------------
# A merge commit's diff can hide changes depending on how it's listed (plain
# `git show`/`diff-tree` without `-m` prints NOTHING for a merge by default).
# Build one that legitimately only merges two artifact-only branches, and
# confirm it is still recognized as in-scope (not silently treated as
# "nothing changed", which would be a false ALLOW for the wrong reason, and
# not mis-flagged as touching code either).
git -C "$FIXTURE" checkout -q -b branch-merge-artifact "$C0"
echo "note m1" > "$FIXTURE/.quetrex/notes.txt"
git -C "$FIXTURE" add .quetrex/notes.txt
git -C "$FIXTURE" commit -q -m "chore: artifact side A"
git -C "$FIXTURE" checkout -q -b branch-merge-other "$C0"
echo "note m2" > "$FIXTURE/.quetrex/other-notes.txt"
git -C "$FIXTURE" add .quetrex/other-notes.txt
git -C "$FIXTURE" commit -q -m "chore: artifact side B"
git -C "$FIXTURE" checkout -q branch-merge-artifact
git -C "$FIXTURE" merge -q --no-ff -m "chore: merge two artifact-only branches" branch-merge-other
reset_clean_baseline "$C0"
OUT="$(run_hook "$FIXTURE")"; CODE=$?
if [ "$CODE" -eq 0 ] && [ -z "$OUT" ]; then
  pass "ALLOW: a merge commit whose sides are both artifact-only stays in scope"
else
  fail "ALLOW(artifact-only merge commit): expected exit 0 + empty stdout, got exit $CODE stdout: [$OUT]"
fi

# ...and a merge commit that injects an out-of-scope file ONLY as part of its
# own conflict resolution — NOT present in full in either single-parent
# commit — must still be caught. This is the case that specifically requires
# `-m`: every OTHER commit in the range (both conflict sides) is, on its own,
# .quetrex/-only, so if the merge commit's own diff were silently skipped (no
# `-m`, git's default for a merge is to print nothing), the whole range would
# wrongly look artifact-only. Two sides deliberately conflict on the SAME
# path so the merge cannot fast-forward and requires a real resolution commit.
git -C "$FIXTURE" checkout -q -b branch-conflict-a "$C0"
echo "content A" > "$FIXTURE/.quetrex/conflict.txt"
git -C "$FIXTURE" add .quetrex/conflict.txt
git -C "$FIXTURE" commit -q -m "chore: conflict side A (artifact-only)"
git -C "$FIXTURE" checkout -q -b branch-conflict-b "$C0"
echo "content B" > "$FIXTURE/.quetrex/conflict.txt"
git -C "$FIXTURE" add .quetrex/conflict.txt
git -C "$FIXTURE" commit -q -m "chore: conflict side B (artifact-only)"
git -C "$FIXTURE" checkout -q branch-conflict-a
git -C "$FIXTURE" merge --no-ff branch-conflict-b -m "temp" >/dev/null 2>&1 || true
mkdir -p "$FIXTURE/src"
echo "resolved" > "$FIXTURE/.quetrex/conflict.txt"
echo "console.log('injected only during merge resolution')" > "$FIXTURE/src/injected.ts"
git -C "$FIXTURE" add .quetrex/conflict.txt src/injected.ts
git -C "$FIXTURE" commit -q -m "chore: resolve conflict, sneaking in an out-of-scope file"
reset_clean_baseline "$C0"
OUT="$(run_hook "$FIXTURE")"
if is_deny "$OUT"; then
  pass "DENY: an out-of-scope file added only in a merge commit's own resolution is caught (-m is load-bearing)"
else
  fail "DENY(merge-resolution-only code): expected a deny decision, got [$OUT]"
fi

# Leave the fixture back on its actual "main" branch: the SYNCING section
# below re-derives the CURRENT checked-out branch of $FIXTURE from disk (via
# `git -C $FIXTURE branch --show-current` inside the hook itself) to decide
# whether "git merge" is even a main-directed vector. Leaving checkout on one
# of the branches created above would silently ungate every case below.
git -C "$FIXTURE" checkout -q main

# =============================================================================
# SYNCING main FROM ITS OWN UPSTREAM IS NOT A SHIP.
#
# `git merge --ff-only origin/main` while on main brings down commits that
# already went through a PR and through this gate. Denying it blocked the
# routine post-merge return to main -- a large part of why post-merge cleanup
# never became automatic, and why the gate was reported as blocking `git pull`.
# A merge of anything ELSE into main is still a ship and still gated.
#
# The fixture is left in a DENYING state, so an 'allowed' result can only mean
# the command was never classified as a merge vector.
# =============================================================================
write_ledger_at "0000000000000000000000000000000000000000"
write_verdict_at "$HEAD_SHA"

assert_allowed "ff-only sync of main from origin/main"       "git -C $FIXTURE merge --ff-only origin/$MAIN"
assert_allowed "plain merge of origin/main into main"        "git -C $FIXTURE merge origin/$MAIN"
assert_allowed "merge from the tracked upstream (@{u})"      "git -C $FIXTURE merge @{u}"
assert_allowed "sync with extra flags"                       "git -C $FIXTURE merge --ff-only --no-edit upstream/$MAIN"

assert_denied  "merging a FEATURE branch into main"          "git -C $FIXTURE merge claude/some-feature"
assert_denied  "merging a remote feature ref into main"      "git -C $FIXTURE merge origin/claude/some-feature"
assert_denied  "merging a bare sha into main"                "git -C $FIXTURE merge 1234abcd"
assert_denied  "merge --no-ff of a feature branch into main" "git -C $FIXTURE merge --no-ff claude/some-feature"

# =============================================================================
# DEFECT L — EVERY vector a compound command names must be independently
# evaluated, not just the first. The previous detection loop `break`s the
# instant it finds ONE vector; a compound command naming a SECOND rode
# through on the strength of the first's clean artifacts, regardless of
# vector kind or order. Uses two SEPARATE local git repos (real local HEAD,
# no PR-head fetch/mocking needed) so "clean" and "dirty" are unambiguous
# and don't depend on gh being mocked correctly.
# =============================================================================
build_l_fixture() {  # build_l_fixture <dir> <label> <clean:0|1>
  local dir="$1" label="$2" clean="$3" head
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "Fixture"
  echo "$label" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" commit -q -m "chore: $label fixture"
  mkdir -p "$dir/.quetrex"
  if [ "$clean" -eq 1 ]; then
    printf '{"verify":["true","echo ok"]}' > "$dir/.quetrex/verify.json"
    head="$(git -C "$dir" rev-parse HEAD)"
    : > "$dir/.quetrex/verify-ledger.jsonl"
    jq -cn --arg sha "$head" --arg cwd "$dir" '{ts:"t",cmd:"true",cwd:$cwd,sha:$sha,exit:0,tail:""}' >> "$dir/.quetrex/verify-ledger.jsonl"
    jq -cn --arg sha "$head" --arg cwd "$dir" '{ts:"t",cmd:"echo ok",cwd:$cwd,sha:$sha,exit:0,tail:"ok"}' >> "$dir/.quetrex/verify-ledger.jsonl"
    jq -cn --arg sha "$head" '{verdict:"AUTO_MERGE",sha:$sha,confirmed:[],inputs:{nativeSecurityReview:"clean"}}' > "$dir/.quetrex/review-verdict.json"
  else
    printf '{"verify":["true"]}' > "$dir/.quetrex/verify.json"
    # Deliberately NO review-verdict.json at all -- genuinely dirty; GATE 2
    # must deny this repo's own vector on its own merits.
  fi
}

FIXTURE_L_CLEAN="$(mktemp -d "${TMPDIR:-/tmp}/merge-gate-l-clean.XXXXXX")"
FIXTURE_L_CLEAN2="$(mktemp -d "${TMPDIR:-/tmp}/merge-gate-l-clean2.XXXXXX")"
FIXTURE_L_DIRTY="$(mktemp -d "${TMPDIR:-/tmp}/merge-gate-l-dirty.XXXXXX")"
build_l_fixture "$FIXTURE_L_CLEAN" "clean" 1
build_l_fixture "$FIXTURE_L_CLEAN2" "clean2" 1
build_l_fixture "$FIXTURE_L_DIRTY" "dirty" 0

OUT="$(run_cmd "$FIXTURE_L_CLEAN" "git -C $FIXTURE_L_CLEAN push origin $MAIN && git -C $FIXTURE_L_DIRTY push origin $MAIN")"
if is_deny "$OUT"; then
  pass "DEFECT L1: clean-repo push && dirty-repo push -- the SECOND vector is still evaluated and denies"
else
  fail "DEFECT L1: expected the dirty second vector to deny, got: ${OUT:0:220}"
fi

OUT="$(run_cmd "$FIXTURE_L_CLEAN" "git -C $FIXTURE_L_DIRTY push origin $MAIN && git -C $FIXTURE_L_CLEAN push origin $MAIN")"
if is_deny "$OUT"; then
  pass "DEFECT L2: dirty-repo push && clean-repo push -- the FIRST vector is still evaluated and denies"
else
  fail "DEFECT L2: expected the dirty first vector to deny, got: ${OUT:0:220}"
fi

# L3 -- positive control: BOTH clean -> the WHOLE command ships. Proves L1/L2
# aren't just "any two-vector command denies" -- only a genuinely dirty one does.
OUT="$(run_cmd "$FIXTURE_L_CLEAN" "git -C $FIXTURE_L_CLEAN push origin $MAIN && git -C $FIXTURE_L_CLEAN2 push origin $MAIN")"; CODE=$?
if [ "$CODE" -eq 0 ] && [ -z "$OUT" ]; then
  pass "DEFECT L3 (positive control): two genuinely clean vectors -- the WHOLE command ships"
else
  fail "DEFECT L3: expected exit 0 + empty stdout (both clean), got exit $CODE stdout: [$OUT]"
fi

# L4-L5 -- cross-KIND: a `gh pr merge` vector combined with a direct push to
# main, in both orders. Reuses the same mocked gh-pr-merge machinery as
# DEFECT G/H (a real origin/local clone pair) for the merge half, and the
# same dirty local repo above for the push half.
FIXTURE_L_ORIGIN="$(mktemp -d "${TMPDIR:-/tmp}/merge-gate-l-origin.XXXXXX")"
git -C "$FIXTURE_L_ORIGIN" init -q -b main
git -C "$FIXTURE_L_ORIGIN" config user.email "test@example.com"
git -C "$FIXTURE_L_ORIGIN" config user.name "Fixture"
echo root > "$FIXTURE_L_ORIGIN/root.txt"
git -C "$FIXTURE_L_ORIGIN" add root.txt
git -C "$FIXTURE_L_ORIGIN" commit -q -m "chore: root"

FIXTURE_L_LOCAL="$(mktemp -d "${TMPDIR:-/tmp}/merge-gate-l-local.XXXXXX")"
git clone -q "$FIXTURE_L_ORIGIN" "$FIXTURE_L_LOCAL"
git -C "$FIXTURE_L_LOCAL" config user.email "test@example.com"
git -C "$FIXTURE_L_LOCAL" config user.name "Fixture"
mkdir -p "$FIXTURE_L_LOCAL/.quetrex"
printf '{"verify":["true"]}' > "$FIXTURE_L_LOCAL/.quetrex/verify.json"

echo mine > "$FIXTURE_L_ORIGIN/mine.txt"
git -C "$FIXTURE_L_ORIGIN" add mine.txt
git -C "$FIXTURE_L_ORIGIN" commit -q -m "feat: PR head"
L_PR_HEAD="$(git -C "$FIXTURE_L_ORIGIN" rev-parse HEAD)"

: > "$FIXTURE_L_LOCAL/.quetrex/verify-ledger.jsonl"
jq -cn --arg sha "$L_PR_HEAD" --arg cwd "$FIXTURE_L_LOCAL" '{ts:"t",cmd:"true",cwd:$cwd,sha:$sha,exit:0,tail:""}' >> "$FIXTURE_L_LOCAL/.quetrex/verify-ledger.jsonl"
jq -cn --arg sha "$L_PR_HEAD" '{verdict:"AUTO_MERGE",sha:$sha,confirmed:[],inputs:{nativeSecurityReview:"clean"}}' > "$FIXTURE_L_LOCAL/.quetrex/review-verdict.json"

# THE VACUITY THIS FIXES: an earlier version of this command carried
# `--repo acme/l-fixture`, which does NOT match $FIXTURE_L_LOCAL's actual
# origin (a local temp path) -- so vector 1 was ALREADY denied on its own
# cross-repo mismatch, and vector 2 (the push) was never reached either
# way. That made L4/L5 pass against round 6 too (round 6 evaluates only
# the FIRST vector, and the first vector already denied for an unrelated
# reason) -- a vacuous pass, not proof of anything. No --repo flag here:
# `gh pr view` resolves against $ROOT's own origin, which DOES match, so
# vector 1 genuinely ships on its own merits and the push vector is what
# has to be reached and denied.
MERGE_CMD_L="$(printf 'gh pr mer%s' 'ge') 91 --squash"

# Sanity/positive control: vector 1 ALONE, with no push attached, must
# genuinely ALLOW -- proves the fixed command is clean on its own, so a
# DENY in the combined cases below can only be attributed to the push half.
OUT="$(run_cmd "$FIXTURE_L_LOCAL" "$MERGE_CMD_L" "$L_PR_HEAD")"; CODE=$?
if [ "$CODE" -eq 0 ] && [ -z "$OUT" ]; then
  pass "DEFECT L4/L5 setup: the gh-pr-merge vector ALONE (no --repo confound) genuinely ships"
else
  fail "DEFECT L4/L5 setup: expected the gh-pr-merge vector alone to ship (empty stdout), got exit $CODE stdout: [$OUT]"
fi

OUT="$(run_cmd "$FIXTURE_L_LOCAL" "$MERGE_CMD_L && git -C $FIXTURE_L_DIRTY push origin $MAIN" "$L_PR_HEAD")"
if is_deny "$OUT"; then
  pass "DEFECT L4: clean gh-pr-merge && dirty-repo push -- the SECOND (push) vector is still evaluated and denies"
else
  fail "DEFECT L4: expected the dirty push vector to deny, got: ${OUT:0:220}"
fi

OUT="$(run_cmd "$FIXTURE_L_LOCAL" "git -C $FIXTURE_L_DIRTY push origin $MAIN && $MERGE_CMD_L" "$L_PR_HEAD")"
if is_deny "$OUT"; then
  pass "DEFECT L5: dirty-repo push && clean gh-pr-merge -- the FIRST (push) vector is still evaluated and denies"
else
  fail "DEFECT L5: expected the dirty push vector to deny, got: ${OUT:0:220}"
fi

rm -rf "$FIXTURE_L_CLEAN" "$FIXTURE_L_CLEAN2" "$FIXTURE_L_DIRTY" "$FIXTURE_L_ORIGIN" "$FIXTURE_L_LOCAL"

# =============================================================================
# DEFECT P — DIFF_BASE (unlike every other variable evaluate_vector
# touches -- see the fix's commit message for the full per-variable audit)
# was assigned ONLY inside the `gh pr merge` branch, then read via an
# unset-fallback check (`if [ -z "${DIFF_BASE:-}" ]`) -- so a NON-gh-pr-
# merge vector (push to main) never assigned it fresh THIS call, and it
# leaked from whatever a PRIOR vector in the SAME compound command left
# behind. Two repos, evaluated back to back: repo P (default `main`,
# genuinely clean) resolves its OWN diff base to the literal ref "main"
# via the fallback; repo Q (default `master`, a sensitive file introduced
# on its own feature branch SEVERAL commits back, about to be pushed)
# never resolves its OWN base -- it inherits P's "main", which does not
# exist in Q at all, the three-dot diff errors, the HEAD~1..HEAD fallback
# kicks in and sees only Q's LAST (benign) commit, and the sensitive file
# several commits back is never inspected.
#
# Deliberately built so the sensitive file is NOT in Q's last commit: if
# it were, the HEAD~1..HEAD fallback alone would still catch it whether or
# not DIFF_BASE leaked, and the test would prove nothing about the leak
# specifically -- it would just be re-testing the fallback.
# =============================================================================
FIXTURE_P="$(mktemp -d "${TMPDIR:-/tmp}/merge-gate-p.XXXXXX")"
git -C "$FIXTURE_P" init -q -b main
git -C "$FIXTURE_P" config user.email "test@example.com"
git -C "$FIXTURE_P" config user.name "Fixture"
echo root > "$FIXTURE_P/README.md"
git -C "$FIXTURE_P" add README.md
git -C "$FIXTURE_P" commit -q -m "chore: P root"
mkdir -p "$FIXTURE_P/.quetrex"
printf '{"verify":["true"]}' > "$FIXTURE_P/.quetrex/verify.json"
P_HEAD="$(git -C "$FIXTURE_P" rev-parse HEAD)"
: > "$FIXTURE_P/.quetrex/verify-ledger.jsonl"
jq -cn --arg sha "$P_HEAD" --arg cwd "$FIXTURE_P" '{ts:"t",cmd:"true",cwd:$cwd,sha:$sha,exit:0,tail:""}' >> "$FIXTURE_P/.quetrex/verify-ledger.jsonl"
jq -cn --arg sha "$P_HEAD" '{verdict:"AUTO_MERGE",sha:$sha,confirmed:[],inputs:{nativeSecurityReview:"clean"}}' > "$FIXTURE_P/.quetrex/review-verdict.json"

FIXTURE_Q="$(mktemp -d "${TMPDIR:-/tmp}/merge-gate-q.XXXXXX")"
git -C "$FIXTURE_Q" init -q -b master
git -C "$FIXTURE_Q" config user.email "test@example.com"
git -C "$FIXTURE_Q" config user.name "Fixture"
echo root > "$FIXTURE_Q/README.md"
git -C "$FIXTURE_Q" add README.md
git -C "$FIXTURE_Q" commit -q -m "chore: Q root"
git -C "$FIXTURE_Q" checkout -q -b claude/q-feature
mkdir -p "$FIXTURE_Q/src/auth"
cat > "$FIXTURE_Q/src/auth/login.ts" <<'TS'
export function getUser(req) { return db.findById(req.params.id); }
TS
git -C "$FIXTURE_Q" add src/auth/login.ts
git -C "$FIXTURE_Q" commit -q -m "feat: add a sensitive auth surface"
echo "benign tweak" >> "$FIXTURE_Q/README.md"
git -C "$FIXTURE_Q" add README.md
git -C "$FIXTURE_Q" commit -q -m "chore: benign follow-up (the LAST commit)"
mkdir -p "$FIXTURE_Q/.quetrex"
printf '{"verify":["true"]}' > "$FIXTURE_Q/.quetrex/verify.json"
Q_HEAD="$(git -C "$FIXTURE_Q" rev-parse HEAD)"
: > "$FIXTURE_Q/.quetrex/verify-ledger.jsonl"
jq -cn --arg sha "$Q_HEAD" --arg cwd "$FIXTURE_Q" '{ts:"t",cmd:"true",cwd:$cwd,sha:$sha,exit:0,tail:""}' >> "$FIXTURE_Q/.quetrex/verify-ledger.jsonl"
jq -cn --arg sha "$Q_HEAD" '{verdict:"AUTO_MERGE",sha:$sha,confirmed:[],inputs:{nativeSecurityReview:"not_available_in_env"}}' > "$FIXTURE_Q/.quetrex/review-verdict.json"
# Deliberately NO security-findings.json -- if the sensitive file (added
# several commits back on this feature branch) is correctly detected, GATE
# 2b/GATE 4 must require an independent security review that doesn't
# exist, and deny.
rm -f "$FIXTURE_Q/.quetrex/security-findings.json"

# P-setup -- sanity/positive control: repo P's clean push ALONE must
# genuinely ALLOW -- proves P is not itself the confound (the exact
# fragility DEFECT L4/L5 fixed: a fixture that denies on its own for an
# unrelated reason makes any later "still denies" assertion vacuous no
# matter what DIFF_BASE does).
OUT="$(run_cmd "$FIXTURE_P" "git -C $FIXTURE_P push origin $MAIN")"; CODE=$?
if [ "$CODE" -eq 0 ] && [ -z "$OUT" ]; then
  pass "DEFECT P setup: repo P's push ALONE genuinely ships (not a confound)"
else
  fail "DEFECT P setup: expected repo P alone to ship (empty stdout), got exit $CODE stdout: [$OUT]"
fi

# P-setup -- sanity: repo Q's push ALONE (sensitive file correctly diffed
# against Q's real "master" base) must DENY on its own -- proves the
# fixture itself is right before combining it with P.
OUT="$(run_cmd "$FIXTURE_Q" "git -C $FIXTURE_Q push origin $MAIN")"
if is_deny "$OUT" && printf '%s' "$OUT" | grep -qi 'security review'; then
  pass "DEFECT P setup: repo Q's push ALONE correctly detects the sensitive file and denies"
else
  fail "DEFECT P setup: expected repo Q alone to deny citing a security review, got: ${OUT:0:220}"
fi

# THE LEAK: repo P's clean push (which resolves its OWN DIFF_BASE to the
# literal "main"), THEN repo Q's push, in THAT order. If DIFF_BASE leaked
# from P into Q's evaluation, Q's sensitive file goes uninspected and this
# ALLOWS; if DIFF_BASE were correctly reset per vector, Q resolves its own
# real "master" base and denies exactly as the setup case does alone.
OUT="$(run_cmd "$FIXTURE_P" "git -C $FIXTURE_P push origin $MAIN && git -C $FIXTURE_Q push origin $MAIN")"
if is_deny "$OUT"; then
  pass "DEFECT P (the fix): clean-repo-P push && sensitive-repo-Q push -- Q's own base is still correctly resolved, denies"
else
  fail "DEFECT P: expected repo Q's diff-content gate to still deny despite P running first, got: ${OUT:0:220}"
fi

# WHICH repo denied, not just that something did -- deny()'s [$VECTOR_LABEL]
# prefix (no origin remote configured on either fixture, so VECTOR_LABEL
# falls back to the absolute checkout path) must name Q, never P. A false
# pass here (denying, but for/about the wrong repo) is exactly as useless
# as DEFECT L4/L5's original vacuous confound.
#
# Matched by basename, not the full $FIXTURE_Q/$FIXTURE_P path: the hook
# resolves ROOT via `git -C ... rev-parse --show-toplevel`, which on macOS
# expands the /tmp -> /private/tmp (and /var -> /private/var) symlink, so
# the raw $FIXTURE_Q string this test built never appears verbatim in the
# hook's own output even when it correctly names Q. The mktemp-suffixed
# basename is unaffected by that resolution and still uniquely identifies
# the fixture.
Q_BASE="$(basename "$FIXTURE_Q")"
P_BASE="$(basename "$FIXTURE_P")"
if printf '%s' "$OUT" | grep -qF "$Q_BASE" && ! printf '%s' "$OUT" | grep -qF "$P_BASE"; then
  pass "DEFECT P (the fix): the denial names repo Q, not repo P"
else
  fail "DEFECT P: expected the denial to name repo Q ($Q_BASE) and not repo P ($P_BASE), got: ${OUT:0:300}"
fi

rm -rf "$FIXTURE_P" "$FIXTURE_Q"

# =============================================================================
# DEFECT K — split_segments_quote_aware and tokenize_argv must AGREE on
# where a `#` shell comment starts. They are deliberately two SEPARATE
# state machines (see the comment at split_segments_quote_aware's
# definition for why one isn't literally shared code) — nothing stops them
# drifting the moment either is touched, proven once already:
# `${out: -1}`-based comment detection could not distinguish an ESCAPED
# separator from a real one, while tokenize_argv's `have` flag could, and
# disagreed on `a\ #x` / `a\<TAB>#x`. This differential test feeds a corpus
# of fragments to BOTH functions — extracted from the hook file UNDER TEST,
# not re-implemented here, so it exercises the real thing — and fails on
# ANY disagreement about whether a `#` starts a comment, not just the two
# cases already found.
# =============================================================================
EXTRACTED_FUNCS="$(mktemp "${TMPDIR:-/tmp}/merge-gate-funcs.XXXXXX")"
extract_func() {  # extract_func <name> -> appends the function's source
  awk -v fn="$1" '
    $0 ~ "^[[:space:]]*"fn"\\(\\)[[:space:]]*\\{" { grab=1 }
    grab { print }
    grab && /^[[:space:]]*\}[[:space:]]*$/ { grab=0; exit }
  ' "$HOOK" >> "$EXTRACTED_FUNCS"
  printf '\n' >> "$EXTRACTED_FUNCS"
}
: > "$EXTRACTED_FUNCS"
extract_func split_segments_quote_aware
extract_func tokenize_argv
# shellcheck disable=SC1090
source "$EXTRACTED_FUNCS"

# comment_starts_in_split <fragment> -- true (0) iff split_segments_quote_
# aware treated the candidate `#` as starting a comment, OBSERVED via
# whether the "&&" placed after it still produced a segment split: if the
# comment were recognized, that operator is inert and the output stays one
# line.
comment_starts_in_split() {
  local out lines
  out="$(split_segments_quote_aware "$1")"
  lines=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  [ "$lines" -eq 1 ]
}
# comment_starts_in_tokenize <fragment> -- true (0) iff tokenize_argv
# treated the candidate `#` as starting a comment, OBSERVED via whether the
# unique marker text placed after it shows up in ANY produced token: if
# comment-mode correctly triggered, tokenize_argv `break`s before ever
# reaching it.
comment_starts_in_tokenize() {
  tokenize_argv "$1"
  local t
  for t in "${TOKENS[@]:-}"; do
    case "$t" in *ZZZMARKERZZZ*) return 1 ;; esac
  done
  return 0
}

DIFF_CORPUS=(
  'a\ #ZZZMARKERZZZ && b'
  "$(printf 'a\\\t#ZZZMARKERZZZ && b')"
  'a #ZZZMARKERZZZ && b'
  'a#ZZZMARKERZZZ && b'
  '#ZZZMARKERZZZ && b'
  "a'x'#ZZZMARKERZZZ && b"
  'a\\ #ZZZMARKERZZZ && b'
  'a\;#ZZZMARKERZZZ && b'
  '  #ZZZMARKERZZZ && b'
  'a b\ c #ZZZMARKERZZZ && b'
)
DIFF_LABELS=(
  "escaped space before #"
  "escaped tab before #"
  "real (unescaped) space before #"
  "attached # (no separator)"
  "# at absolute start"
  "# immediately after a closing quote"
  "escaped-backslash-then-real-space before #"
  "escaped semicolon before #"
  "leading real spaces before #"
  "escaped space mid-fragment, then a real space before #"
)

kk=0
while [ "$kk" -lt "${#DIFF_CORPUS[@]}" ]; do
  frag="${DIFF_CORPUS[$kk]}"
  label="${DIFF_LABELS[$kk]}"
  if comment_starts_in_split "$frag"; then split_says="comment"; else split_says="not-comment"; fi
  if comment_starts_in_tokenize "$frag"; then tok_says="comment"; else tok_says="not-comment"; fi
  if [ "$split_says" = "$tok_says" ]; then
    pass "DEFECT K: $label -- split_segments_quote_aware and tokenize_argv agree ($split_says)"
  else
    fail "DEFECT K: $label -- DISAGREE: splitter says '$split_says', tokenizer says '$tok_says' (fragment: [$frag])"
  fi
  kk=$((kk + 1))
done

rm -f "$EXTRACTED_FUNCS"

# DEFECT N/O below need $FIXTURE's origin configured again (removed at the
# end of the CROSS-REPO/DEFECT I section above) to compare against.
git -C "$FIXTURE" remote add origin "https://github.com/acme/fixture-repo.git" 2>/dev/null || true

# =============================================================================
# DEFECT N — two residuals declared OUT OF BOUNDS in this round's boundary
# text, pinned the same way DEFECT J4 pins the export-prefix residual: an
# assertion that they are NOT caught, so the test suite itself flags any
# future drift between the boundary comment and the code.
# =============================================================================
OUT="$(run_cmd "$FIXTURE" "/opt/homebrew/bin/gh pr merge 7 --squash --repo other-org/other-repo")"
if printf '%s' "$OUT" | grep -q 'other-org/other-repo'; then
  fail "DEFECT N1: a path-qualified gh binary is documented as OUT OF BOUNDS but was caught -- update the boundary comment to match, got: ${OUT:0:200}"
else
  pass "DEFECT N1 (documents the boundary): a path-qualified gh binary (/opt/homebrew/bin/gh) is NOT anchored on, as documented"
fi

OUT="$(run_cmd "$FIXTURE" "RESULT=\$($(printf 'gh pr mer%s' 'ge') 7 --squash --repo other-org/other-repo)")"
if printf '%s' "$OUT" | grep -q 'other-org/other-repo'; then
  fail "DEFECT N2: a command-substitution-wrapped merge is documented as OUT OF BOUNDS but was caught -- update the boundary comment to match, got: ${OUT:0:200}"
else
  pass "DEFECT N2 (documents the boundary): RESULT=\$(gh pr merge ...) is NOT anchored on, as documented"
fi

# =============================================================================
# DEFECT O — an unexpanded shell expression's KNOWN LITERAL PREFIX is still
# checked. Fail-open (DEFECT J6/the boundary text) means "cannot verify",
# not "assume it happens to resolve to this repo" -- when the FIXED, un-
# expandable portion of a --repo value already contradicts this checkout's
# origin, that is proof, not an unknown, and must still deny.
# =============================================================================
OUT="$(run_cmd "$FIXTURE" "$(printf 'gh pr mer%s' 'ge') 7 --squash --repo 'other-org/\$VAR'")"
if is_deny "$OUT" && printf '%s' "$OUT" | grep -qi 'literal prefix'; then
  pass "DEFECT O1: --repo 'other-org/\$VAR' -- the literal prefix 'other-org/' already contradicts origin, denied"
else
  fail "DEFECT O1: expected a literal-prefix-contradiction denial, got: ${OUT:0:220}"
fi
OUT="$(run_cmd "$FIXTURE" "$(printf 'gh pr mer%s' 'ge') 7 --squash --repo 'other-org/other-repo\${EMPTY}'")"
if is_deny "$OUT" && printf '%s' "$OUT" | grep -qi 'literal prefix'; then
  pass "DEFECT O2: --repo 'other-org/other-repo\${EMPTY}' -- literal prefix contradicts origin, denied"
else
  fail "DEFECT O2: expected a literal-prefix-contradiction denial, got: ${OUT:0:220}"
fi
# O3 -- positive control: a value with NO literal prefix at all (pure "$SLUG",
# the engine's own merge.md shape, per DEFECT J6) must NOT be caught by this
# refinement -- there is no fixed text to contradict origin with.
OUT="$(run_cmd "$FIXTURE" "$(printf 'gh pr mer%s' 'ge') 7 --squash --repo \"\$SLUG\"")"
if printf '%s' "$OUT" | grep -qi 'literal prefix'; then
  fail "DEFECT O3: a bare \$SLUG (no literal prefix) must not trigger the literal-prefix check, got: ${OUT:0:220}"
else
  pass "DEFECT O3 (positive control): a bare \$SLUG (no literal prefix) is not affected by the literal-prefix refinement"
fi
git -C "$FIXTURE" remote remove origin 2>/dev/null || true

echo
if [ "$FAIL" -eq 0 ]; then
  echo "merge-gate.test.sh: all checks passed"
else
  echo "merge-gate.test.sh: FAILURES above"
fi
exit "$FAIL"
