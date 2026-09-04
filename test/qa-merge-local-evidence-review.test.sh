#!/usr/bin/env bash
# test/qa-merge-local-evidence-review.test.sh — QA's independent adversarial
# review of the "local gate evidence" transport added to /quetrex:merge
# (.claude/commands/merge.md, qx_find_local_evidence + the §2 transport
# fence). Not the developer's own test/merge-local-evidence.test.sh: this
# file builds its own fixtures and attacks the four questions that actually
# decide whether local evidence is safe to trust as a merge authorization:
#
#   1. Can the pin be forged? — a partially-matching evidence set (3 of 4
#      fields agree, one lies) must be refused; a fully-agreeing set must be
#      accepted.
#   2. Does finding local evidence still require merge-gate.sh's real
#      authorization (AUTO_MERGE + a green ledger), or does transport alone
#      let a merge through? Runs the REAL merge-gate.sh hook end to end.
#   3. Can worktree discovery reach outside the repo? — a directory that is
#      not the repo root and not in `git worktree list` must never be
#      consulted, even when it holds perfectly-pinned evidence sitting next
#      door; a worktree path containing a space, and a stale/pruned worktree
#      entry, must not crash discovery.
#   4. The empty-GATES_BRANCH guard: `git fetch origin ""` is a silent,
#      successful DEFAULT fetch (proven below), so the pre-change §2 fence
#      (base 87dc34a) both fetched garbage and deleted real local artifacts
#      when no gates branch existed. HEAD's §2 fence must refuse to run that
#      fetch at all when GATES_BRANCH is empty.
#
# Run: bash test/qa-merge-local-evidence-review.test.sh
#      zsh  test/qa-merge-local-evidence-review.test.sh
#
# Everything under test is EXTRACTED out of the shipped merge.md and run for
# real, under both bash and zsh, against throwaway git fixtures — never a
# hand-written stand-in for the shipped exec block.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
MERGE_MD="$ROOT/.claude/commands/merge.md"
GATE_HOOK="$ROOT/plugins/quetrex-factory/scripts/merge-gate.sh"
BASE_SHA="87dc34a"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }
finish() {
  printf '\n%s\n' "qa-merge-local-evidence-review.test.sh: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
}

command -v node >/dev/null 2>&1 || { echo "SKIP: node unavailable"; exit 0; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
command -v jq   >/dev/null 2>&1 || { echo "SKIP: jq unavailable — merge-gate.sh is jq-mandatory"; exit 0; }
[ -f "$MERGE_MD" ]  || { echo "NOT OK - merge.md not found at $MERGE_MD"; exit 1; }
[ -f "$GATE_HOOK" ] || { echo "NOT OK - merge-gate.sh not found at $GATE_HOOK"; exit 1; }
# NEVER `for SH in $SHELLS` — zsh does not word-split an unquoted $VAR, so a
# two-word SHELLS collapses into a single loop iteration with SH="bash zsh"
# (a nonexistent command), and every discover call then fails silently
# (2>/dev/null) into an EMPTY result — which false-positive-PASSES every
# assertion that expects refusal and only catches the acceptance assertions.
# Loop over literal words instead; the availability check happens inside.
zsh_available=0
command -v zsh >/dev/null 2>&1 && zsh_available=1

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qx-qa-merge-local.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Extraction — pulled out of the shipped markdown, never hand-copied.
# ---------------------------------------------------------------------------
exec_block() {  # exec_block <file> <name>
  awk -v name="$2" '
    $0 ~ ("quetrex:exec-block " name "([^A-Za-z0-9_]|$)") && $0 !~ ("end quetrex:exec-block") { inb=1 }
    inb { print }
    $0 ~ ("end quetrex:exec-block " name "([^A-Za-z0-9_]|$)") { inb=0 }
  ' "$1"
}
fence_after() {  # fence_after <file> <heading-substring> <n>
  awk -v h="$2" -v want="$3" '
    !seen && index($0, h) { seen = 1; next }
    !seen { next }
    /^```/ { if (inb) { inb = 0; n++; if (n == want) exit } else { inb = 1; if (n + 1 == want) next } ; next }
    inb && n + 1 == want { print }
  ' "$1"
}

DISCOVER="$WORK/discover.sh"
exec_block "$MERGE_MD" qx_find_local_evidence > "$DISCOVER"
if [ -s "$DISCOVER" ] && grep -q 'qx_find_local_evidence()' "$DISCOVER" && bash -n "$DISCOVER" 2>/dev/null; then
  ok "AC0: extracted qx_find_local_evidence from HEAD's merge.md ($(wc -l < "$DISCOVER" | tr -d ' ') lines)"
else
  notok "AC0: could not extract a parseable qx_find_local_evidence — every check below would be vacuous"
  finish
fi

run_discover() {  # run_discover <shell> <root> <want-sha> -> prints result dir (or empty)
  local sh="$1" root="$2" want="$3"
  "$sh" -c '. "$1"; qx_find_local_evidence "$2" "$3"' _ "$DISCOVER" "$root" "$want" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Fixture helpers.
# ---------------------------------------------------------------------------
mkrepo() {  # mkrepo <dir> -> prints HEAD sha
  local dir="$1"
  git init -q -b work "$dir" >/dev/null 2>&1
  git -C "$dir" config user.email "qa@example.com"
  git -C "$dir" config user.name "QA"
  echo x > "$dir/f"
  git -C "$dir" add f
  git -C "$dir" commit -q -m c1 >/dev/null
  git -C "$dir" rev-parse HEAD
}

# write_evidence <dir> <gates-head|__ABSENT__> <verdict-sha> <ledger-sha> <secfindings-headsha|__ABSENT__> [verdict] [ledger-exit]
write_evidence() {
  local d="$1" gh="$2" vsha="$3" lsha="$4" ssha="$5" verdict="${6:-AUTO_MERGE}" lexit="${7:-0}"
  mkdir -p "$d/.quetrex"
  if [ "$gh" != "__ABSENT__" ]; then printf '%s\n' "$gh" > "$d/.quetrex/gates-head"; else rm -f "$d/.quetrex/gates-head"; fi
  jq -cn --arg sha "$vsha" --arg v "$verdict" '{verdict:$v, sha:$sha, confirmed:[], inputs:{nativeSecurityReview:"clean"}}' \
    > "$d/.quetrex/review-verdict.json"
  jq -cn --arg sha "$lsha" --argjson exit "$lexit" \
    '{ts:"2026-01-01T00:00:00Z",cmd:"true",cwd:"x",sha:$sha,exit:$exit,tail:""}' \
    > "$d/.quetrex/verify-ledger.jsonl"
  if [ "$ssha" != "__ABSENT__" ]; then
    jq -cn --arg sha "$ssha" '{task:"T-1",base:"main",head_sha:$sha,reviewed_files:1,verdict:"PASS",findings:[]}' \
      > "$d/.quetrex/security-findings.json"
  else
    rm -f "$d/.quetrex/security-findings.json"
  fi
}

# =============================================================================
# CHECK 1 — the pin cannot be forged: 3-of-4 agreement must still refuse.
# =============================================================================
echo "== check 1: forged/partial pins =="
for SH in bash zsh; do
  [ "$SH" = zsh ] && [ "$zsh_available" -ne 1 ] && continue
  D="$WORK/c1-$SH"; mkdir -p "$D"
  PR_SHA="$(mkrepo "$D/repo")"
  OTHER="0000000000000000000000000000000000dead"

  write_evidence "$D/repo" "$PR_SHA" "$PR_SHA" "$OTHER" "$PR_SHA"
  R="$(run_discover "$SH" "$D/repo" "$PR_SHA")"
  [ -z "$R" ] && ok "[$SH] 1a: ledger pinned to a different sha (3/4 agree) refused" \
              || notok "[$SH] 1a: ledger-sha mismatch was ACCEPTED ($R)"

  write_evidence "$D/repo" "$OTHER" "$PR_SHA" "$PR_SHA" "$PR_SHA"
  R="$(run_discover "$SH" "$D/repo" "$PR_SHA")"
  [ -z "$R" ] && ok "[$SH] 1b: gates-head disagrees with everything else (3/4 agree) refused" \
              || notok "[$SH] 1b: gates-head mismatch was ACCEPTED ($R)"

  write_evidence "$D/repo" "$PR_SHA" "$OTHER" "$PR_SHA" "$PR_SHA"
  R="$(run_discover "$SH" "$D/repo" "$PR_SHA")"
  [ -z "$R" ] && ok "[$SH] 1c: review-verdict.sha alone lies (3/4 agree) refused" \
              || notok "[$SH] 1c: review-verdict.sha mismatch was ACCEPTED ($R)"

  write_evidence "$D/repo" "$PR_SHA" "$PR_SHA" "$PR_SHA" "$OTHER"
  R="$(run_discover "$SH" "$D/repo" "$PR_SHA")"
  [ -z "$R" ] && ok "[$SH] 1d: security-findings.head_sha alone lies (3/4 agree) refused" \
              || notok "[$SH] 1d: security-findings mismatch was ACCEPTED ($R)"

  # security-findings absent is legal (merge.md says so explicitly) — must
  # still be accepted when the other three genuinely agree.
  write_evidence "$D/repo" "$PR_SHA" "$PR_SHA" "$PR_SHA" "__ABSENT__"
  R="$(run_discover "$SH" "$D/repo" "$PR_SHA")"
  [ -n "$R" ] && ok "[$SH] 1e: absent security-findings.json + 3 agreeing fields accepted" \
              || notok "[$SH] 1e: legal absent-security-findings set was REFUSED"

  # positive control: all four genuinely agree.
  write_evidence "$D/repo" "$PR_SHA" "$PR_SHA" "$PR_SHA" "$PR_SHA"
  R="$(run_discover "$SH" "$D/repo" "$PR_SHA")"
  [ -n "$R" ] && ok "[$SH] 1f: fully-agreeing evidence accepted (positive control)" \
              || notok "[$SH] 1f: fully-agreeing evidence was REFUSED"
done

# =============================================================================
# CHECK 2 — transport is not authorization: run the REAL merge-gate.sh.
# =============================================================================
echo "== check 2: found-but-not-green / found-but-not-AUTO_MERGE still denies =="

MOCKBIN="$WORK/mockbin"; mkdir -p "$MOCKBIN"
cat > "$MOCKBIN/gh" <<'MOCKGH'
#!/bin/sh
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  printf '{"headRefOid":"%s","baseRefOid":"%s"}' "${MOCK_GH_PR_VIEW_SHA:-}" "${MOCK_GH_PR_BASE_SHA:-}"
  exit 0
fi
echo "mock gh: unhandled: $*" >&2; exit 1
MOCKGH
chmod +x "$MOCKBIN/gh"

D2="$WORK/c2"; mkdir -p "$D2"
PR_SHA2="$(mkrepo "$D2/repo")"
mkdir -p "$D2/repo/.quetrex"
printf '{"branchPrefix":"claude/"}' > "$D2/repo/.quetrex/project.json"
printf '{"verify":["true"]}' > "$D2/repo/.quetrex/verify.json"
GH_MERGE_CMD="$(printf 'gh pr mer%s' 'ge') 123 --squash"

run_gate() {  # run_gate <cwd> <pr_sha>
  local cwd="$1" sha="$2" payload
  payload="$(jq -cn --arg cmd "$GH_MERGE_CMD" --arg cwd "$cwd" '{tool_input:{command:$cmd},cwd:$cwd}')"
  printf '%s' "$payload" | env PATH="$MOCKBIN:$PATH" MOCK_GH_PR_VIEW_SHA="$sha" MOCK_GH_PR_BASE_SHA="$sha" GH_REPO="" CLAUDE_PROJECT_DIR="$cwd" "$GATE_HOOK"
}
is_deny() { printf '%s' "$1" | grep -q '"permissionDecision":"deny"\|MERGE GATE'; }

# 2a. Evidence is discoverable AND fully pinned, but the verdict is REWORK.
write_evidence "$D2/repo" "$PR_SHA2" "$PR_SHA2" "$PR_SHA2" "__ABSENT__" "REWORK" 0
R="$(run_discover bash "$D2/repo" "$PR_SHA2")"
[ -n "$R" ] && ok "2a: pinned REWORK evidence is still DISCOVERABLE (transport works)" \
            || notok "2a: pinned REWORK evidence was not discovered — test setup broken"
OUT="$(run_gate "$D2/repo" "$PR_SHA2")"; CODE=$?
if [ "$CODE" -ne 0 ] || is_deny "$OUT"; then
  ok "2a: merge-gate.sh DENIES a discoverable-but-REWORK verdict"
else
  notok "2a: merge-gate.sh ALLOWED a REWORK-verdict merge — $OUT"
fi

# 2b. Fully pinned, AUTO_MERGE verdict, but the ledger's only entry is RED.
write_evidence "$D2/repo" "$PR_SHA2" "$PR_SHA2" "$PR_SHA2" "__ABSENT__" "AUTO_MERGE" 1
R="$(run_discover bash "$D2/repo" "$PR_SHA2")"
[ -n "$R" ] && ok "2b: pinned red-ledger evidence is still DISCOVERABLE (transport works)" \
            || notok "2b: pinned red-ledger evidence was not discovered — test setup broken"
OUT="$(run_gate "$D2/repo" "$PR_SHA2")"; CODE=$?
if [ "$CODE" -ne 0 ] || is_deny "$OUT"; then
  ok "2b: merge-gate.sh DENIES a discoverable-but-red-ledger AUTO_MERGE"
else
  notok "2b: merge-gate.sh ALLOWED a red-ledger merge — $OUT"
fi

# 2c. Positive control: fully pinned, AUTO_MERGE, green ledger -> ALLOW.
write_evidence "$D2/repo" "$PR_SHA2" "$PR_SHA2" "$PR_SHA2" "__ABSENT__" "AUTO_MERGE" 0
OUT="$(run_gate "$D2/repo" "$PR_SHA2")"; CODE=$?
if [ "$CODE" -eq 0 ] && ! is_deny "$OUT"; then
  ok "2c: merge-gate.sh ALLOWS genuinely clean pinned local evidence (positive control)"
else
  notok "2c: positive control was DENIED — $OUT (harness/fixture is broken, checks above are unproven)"
fi

# =============================================================================
# CHECK 3 — worktree discovery cannot reach outside the repo.
# =============================================================================
echo "== check 3: discovery boundary =="
for SH in bash zsh; do
  [ "$SH" = zsh ] && [ "$zsh_available" -ne 1 ] && continue
  D3="$WORK/c3-$SH"; mkdir -p "$D3"
  PR_SHA3="$(mkrepo "$D3/repo")"

  # 3a. A directory that is NOT the repo root and NOT a registered worktree,
  # sitting right next to the repo, holding PERFECTLY pinned evidence. It
  # must never be consulted — discovery only follows `git worktree list`.
  write_evidence "$D3/foreign" "$PR_SHA3" "$PR_SHA3" "$PR_SHA3" "$PR_SHA3"
  R="$(run_discover "$SH" "$D3/repo" "$PR_SHA3")"
  [ -z "$R" ] && ok "[$SH] 3a: perfectly-pinned evidence in a non-worktree sibling dir was NOT imported" \
              || notok "[$SH] 3a: discovery reached OUTSIDE the repo/worktree set ($R)"

  # 3b. A worktree at a path containing a space — must be discovered
  # correctly (the read loop must not word-split it).
  git -C "$D3/repo" worktree add -q -b "loc-space-$SH" "$D3/has space" >/dev/null 2>&1
  WT_SPACE="$(git -C "$D3/repo" worktree list --porcelain | sed -n 's/^worktree //p' | sed -n '2p')"
  if [ -n "$WT_SPACE" ] && [ -d "$WT_SPACE" ]; then
    write_evidence "$WT_SPACE" "$PR_SHA3" "$PR_SHA3" "$PR_SHA3" "$PR_SHA3"
    R="$(run_discover "$SH" "$D3/repo" "$PR_SHA3")"
    [ "$R" = "$WT_SPACE" ] && ok "[$SH] 3b: worktree path containing a space discovered correctly" \
                            || notok "[$SH] 3b: space-path worktree not discovered correctly (got '$R', want '$WT_SPACE')"
    git -C "$D3/repo" worktree remove --force "$D3/has space" >/dev/null 2>&1
  else
    notok "[$SH] 3b: could not create a space-path worktree fixture"
  fi

  # 3c. A stale/pruned worktree entry — the directory is gone from disk but
  # git worktree list still (administratively) knows about it. Discovery
  # must not crash and must not error out.
  git -C "$D3/repo" worktree add -q -b "loc-stale-$SH" "$D3/stale-wt" >/dev/null 2>&1
  rm -rf "$D3/stale-wt"
  OUT="$(run_discover "$SH" "$D3/repo" "$PR_SHA3" 2>&1)"; RC=$?
  if [ "$RC" -le 1 ]; then
    ok "[$SH] 3c: a stale/pruned worktree entry does not crash discovery (exit $RC)"
  else
    notok "[$SH] 3c: discovery crashed on a stale worktree entry (exit $RC): $OUT"
  fi
  git -C "$D3/repo" worktree prune >/dev/null 2>&1

  # 3d. Root itself still qualifies (sanity: the boundary isn't so tight it
  # excludes the legitimate case of evidence sitting in the repo root).
  write_evidence "$D3/repo" "$PR_SHA3" "$PR_SHA3" "$PR_SHA3" "$PR_SHA3"
  R="$(run_discover "$SH" "$D3/repo" "$PR_SHA3")"
  [ -n "$R" ] && ok "[$SH] 3d: repo root itself is still a valid evidence location" \
              || notok "[$SH] 3d: repo root was wrongly excluded"
done

# =============================================================================
# CHECK 4 — the empty-GATES_BRANCH guard (`git fetch origin ""` is a silent
# successful default fetch, proven directly below, not asserted from memory).
# =============================================================================
echo "== check 4: empty GATES_BRANCH guard =="

D4="$WORK/c4"; mkdir -p "$D4"
git init -q --bare -b trunk "$D4/origin.git" >/dev/null
git clone -q "$D4/origin.git" "$D4/repo" >/dev/null 2>&1
git -C "$D4/repo" config user.email "qa@example.com"
git -C "$D4/repo" config user.name "QA"
echo seed > "$D4/repo/seed"
git -C "$D4/repo" add seed
git -C "$D4/repo" commit -q -m seed
git -C "$D4/repo" push -q origin trunk

FETCH_RC=1
if git -C "$D4/repo" fetch -q origin "" >/dev/null 2>&1; then FETCH_RC=0; fi
if [ "$FETCH_RC" -eq 0 ] && git -C "$D4/repo" rev-parse -q --verify FETCH_HEAD >/dev/null 2>&1; then
  ok "4-premise: 'git fetch origin \"\"' is a silent SUCCESSFUL default fetch (the bug's premise, proven live)"
else
  notok "4-premise: 'git fetch origin \"\"' did not behave as the fix assumes — check 4 below would be untrustworthy"
fi

# Pre-existing LOCAL evidence already sitting at $REPO_ROOT/.quetrex, pinned
# to a real (different) commit — the exact shape that would exist after a
# local build already ran once. GATES_BRANCH is empty (no gates ref for this
# PR head exists on origin) and LOCAL_EVIDENCE_DIR is empty too (this test
# isolates just the fetch-guard, per §2's own structure: the guarded block
# runs before the local-evidence branch is even reached).
PRIOR_SHA="$(git -C "$D4/repo" rev-parse HEAD)"
write_evidence "$D4/repo" "$PRIOR_SHA" "$PRIOR_SHA" "$PRIOR_SHA" "__ABSENT__"
[ -s "$D4/repo/.quetrex/verify-ledger.jsonl" ] || { notok "4-setup: fixture evidence not written"; finish; }

extract_and_run_s2() {  # extract_and_run_s2 <merge_md_file> <repo_root> -> exit code; stdout captured by caller
  local mdfile="$1" root="$2" s2="$WORK/s2-$$.sh"
  fence_after "$mdfile" '## 2. Bring the gate evidence home' 1 > "$s2"
  {
    printf 'REPO_ROOT=%q\n' "$root"
    printf 'GATES_BRANCH=""\n'
    printf 'LOCAL_EVIDENCE_DIR=""\n'
    printf 'PR_SHA=%q\n' "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
    printf 'TASK=%q\n' "T-1"
  } > "$WORK/facts.env"
  bash -c '. "$1"; . "$2"' _ "$WORK/facts.env" "$s2" >"$WORK/s2.out" 2>&1
  echo $?
}

# 4a. Reproduce the OLD (pre-change, base 87dc34a) behavior directly against
# the literal pre-change file — the actual regression, not a description of it.
OLD_MD="$WORK/merge-base.md"
git show "$BASE_SHA:.claude/commands/merge.md" > "$OLD_MD" 2>/dev/null
if [ -s "$OLD_MD" ]; then
  cp -f "$D4/repo/.quetrex/verify-ledger.jsonl" "$WORK/pre.jsonl"
  RC="$(extract_and_run_s2 "$OLD_MD" "$D4/repo")"
  if [ ! -s "$D4/repo/.quetrex/verify-ledger.jsonl" ] && [ -s "$WORK/pre.jsonl" ]; then
    ok "4a: base $BASE_SHA's §2, run with an empty GATES_BRANCH, DELETES the pre-existing local artifacts (reproduced regression)"
  else
    notok "4a: could not reproduce the base-$BASE_SHA empty-branch artifact-deletion bug — see $WORK/s2.out"
  fi
else
  notok "4a: could not extract §2 from base $BASE_SHA's merge.md"
fi

# 4b. HEAD's §2 fence, same fixture, same empty GATES_BRANCH: must NOT wipe
# the pre-existing artifacts, and must NOT report a bogus fetch as evidence.
write_evidence "$D4/repo" "$PRIOR_SHA" "$PRIOR_SHA" "$PRIOR_SHA" "__ABSENT__"
RC="$(extract_and_run_s2 "$MERGE_MD" "$D4/repo")"
if [ -s "$D4/repo/.quetrex/verify-ledger.jsonl" ]; then
  ok "4b: HEAD's §2, run with an empty GATES_BRANCH, LEAVES pre-existing local artifacts intact"
else
  notok "4b: HEAD's §2 still wiped the pre-existing artifacts on an empty GATES_BRANCH — see $WORK/s2.out"
fi
if grep -qE '^Fetched gate evidence from  ' "$WORK/s2.out" 2>/dev/null; then
  notok "4b: HEAD's §2 still printed a bogus 'Fetched gate evidence from <blank>' line"
else
  ok "4b: HEAD's §2 never claims to have fetched gate evidence from an empty branch name"
fi

finish
