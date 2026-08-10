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

echo
if [ "$FAIL" -eq 0 ]; then
  echo "merge-gate.test.sh: all checks passed"
else
  echo "merge-gate.test.sh: FAILURES above"
fi
exit "$FAIL"
