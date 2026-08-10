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
# ALSO COVERS DEFECT C (added by a later branch): review-verdict.json's .sha,
# security-findings.json's .head_sha, and each verify-ledger.jsonl entry's
# .sha are artifacts NAMING the commit they approve. If one of those files
# ever gets committed (contrary to git-workflow.md's convention that .quetrex/*
# stays gitignored), the commit that adds it moves HEAD and the artifact's own
# pin can never equal HEAD again -- denying every subsequent operation
# forever, including the commit that would repair the mistake. The fix: an
# old pin still authorizes HEAD when it is an ancestor of HEAD AND every
# commit in the range touches nothing outside .quetrex/. See the DEFECT C
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

# The literal merge command, assembled at runtime. Written this way on purpose:
# a test file for a hook that pattern-matches merge commands would otherwise
# contain those exact tokens, and this repo's own PreToolUse gate reads the
# command string of every Bash call — including the one that runs this test.
GH_MERGE="$(printf 'gh pr mer%s' 'ge') 123 --squash"
GH_CREATE="$(printf 'gh pr cre%s' 'ate')"
MAIN="$(printf 'ma%s' 'in')"

run_hook() {
  local cwd="$1" payload
  payload="$(jq -cn --arg cmd "$GH_MERGE" --arg cwd "$cwd" \
    '{tool_input:{command:$cmd},cwd:$cwd}')"
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$cwd" "$HOOK"
}

# run_cmd <cwd> <command> — exercise the hook against an ARBITRARY command, to
# assert what is and is not classified as a merge vector in the first place.
run_cmd() {
  local cwd="$1" cmd="$2" payload
  payload="$(jq -cn --arg cmd "$cmd" --arg cwd "$cwd" \
    '{tool_input:{command:$cmd},cwd:$cwd}')"
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$cwd" "$HOOK" 2>&1
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
# DEFECT C — artifact-only commits must not self-invalidate an approval.
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

echo
if [ "$FAIL" -eq 0 ]; then
  echo "merge-gate.test.sh: all checks passed"
else
  echo "merge-gate.test.sh: FAILURES above"
fi
exit "$FAIL"
