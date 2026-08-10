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

# --- mock `gh` -- only implements what merge-gate.sh's PR-head resolution
# calls: `gh pr view [<id>] [--repo x] --json headRefOid --jq .headRefOid`.
# Prepended onto PATH for every hook invocation below so the suite never
# depends on a real `gh` being installed/authenticated, and so the "PR head"
# a test simulates is fully under the test's control. Set MOCK_GH_PR_VIEW_SHA
# to the sha the mock should report, or MOCK_GH_PR_VIEW_FAIL=1 to simulate an
# unresolvable PR (gh missing/unauthenticated/PR not found).
cat > "$MOCKBIN/gh" <<'MOCKGH'
#!/bin/sh
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  if [ -n "${MOCK_GH_PR_VIEW_FAIL:-}" ]; then
    echo "mock gh: pr view failed" >&2
    exit 1
  fi
  printf '%s' "${MOCK_GH_PR_VIEW_SHA:-}"
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

# run_hook <cwd> [pr_head_sha_override] [fail: 1 to simulate an unresolvable PR]
# Without an override, the mock reports the fixture's OWN current git HEAD as
# the "PR head" — reproducing exactly what the pre-fix hook computed directly
# (git rev-parse HEAD in $ROOT), so every existing assertion below keeps
# testing the same scenario it always did. Tests that need to reproduce the
# real bug (local checkout on main, PR head elsewhere) pass an explicit
# override.
run_hook() {
  local cwd="$1" pr_sha="${2:-}" failflag="${3:-}" payload
  [ -z "$pr_sha" ] && pr_sha="$(git -C "$cwd" rev-parse HEAD 2>/dev/null)"
  payload="$(jq -cn --arg cmd "$GH_MERGE" --arg cwd "$cwd" \
    '{tool_input:{command:$cmd},cwd:$cwd}')"
  printf '%s' "$payload" | env PATH="$MOCKBIN:$PATH" MOCK_GH_PR_VIEW_SHA="$pr_sha" MOCK_GH_PR_VIEW_FAIL="$failflag" CLAUDE_PROJECT_DIR="$cwd" "$HOOK"
}

# run_cmd <cwd> <command> [pr_head_sha_override] — exercise the hook against an
# ARBITRARY command, to assert what is and is not classified as a merge vector
# in the first place. Same mock-gh default as run_hook.
run_cmd() {
  local cwd="$1" cmd="$2" pr_sha="${3:-}" payload
  [ -z "$pr_sha" ] && pr_sha="$(git -C "$cwd" rev-parse HEAD 2>/dev/null)"
  payload="$(jq -cn --arg cmd "$cmd" --arg cwd "$cwd" \
    '{tool_input:{command:$cmd},cwd:$cwd}')"
  printf '%s' "$payload" | env PATH="$MOCKBIN:$PATH" MOCK_GH_PR_VIEW_SHA="$pr_sha" CLAUDE_PROJECT_DIR="$cwd" "$HOOK" 2>&1
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
OUT="$(run_hook "$FIXTURE" "" 1)"; CODE=$?
if [ "$CODE" -eq 0 ] && is_deny "$OUT"; then
  pass "DEFECT C3: PR head unresolvable (gh failure) -> DENIED (fail closed)"
else
  fail "DEFECT C3: expected a deny decision when the PR head cannot be resolved, got exit $CODE stdout: [$OUT]"
fi

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

write_sec() {  # write_sec <head_sha> <severity|none> [status]
  if [ "$2" = "none" ]; then
    jq -cn --arg sha "$1" '{task:"T-1",base:"main",head_sha:$sha,reviewed_files:3,verdict:"PASS",findings:[]}' \
      > "$FIXTURE/.quetrex/security-findings.json"
  else
    jq -cn --arg sha "$1" --arg sev "$2" --arg st "${3:-open}" \
      '{task:"T-1",base:"main",head_sha:$sha,reviewed_files:3,verdict:"BLOCK",findings:[{id:"SEC-1",severity:$sev,status:$st,category:"bola-idor",file:"src/x.ts",line:1,summary:"test"}]}' \
      > "$FIXTURE/.quetrex/security-findings.json"
  fi
}

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
