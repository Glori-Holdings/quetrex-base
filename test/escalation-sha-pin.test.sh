#!/usr/bin/env bash
# test/escalation-sha-pin.test.sh — ESCALATION-SHA-PIN (ONE-COPY, AC6/AC7),
# then re-pinned to BRANCH by the C4 review fix.
#
# Run: bash test/escalation-sha-pin.test.sh
#
# THE ORIGINAL DEFECT (ONE-COPY). .quetrex/ESCALATION used to be an
# unstructured marker (`touch`/`printf` — no sha). merge-gate.sh's GATE 1
# denied on its mere PRESENCE, forever — including a marker recorded on a
# commit this branch has since left behind. The ONE-COPY fix made both
# producers write `{"sha":"<head-sha-at-cap>","reason":"..."}` and had
# GATE 1 deny UNLESS the recorded sha was PROVEN not an ancestor of HEAD.
#
# THE C4 REGRESSION THAT FIX INTRODUCED (review finding, high). "Not an
# ancestor of HEAD" is satisfied by ANY history rewrite — including a
# plain `git commit --amend`, which preserves the branch and every bit of
# the work and is a routine self-heal move. MEASURED: write a marker in
# the exact shape verify-gate.sh produces, `git commit --amend --no-edit`
# with no other change, and GATE 1 stopped denying a live escalation —
# with no tampering of .quetrex/ required.
#
# THE C4 FIX. Both producers now write `{"sha":..., "branch":..., "reason":
# ...}` (branch omitted only when HEAD was detached at write time). GATE 1
# drops the ancestor test entirely: it ignores (treats as stale) a marker
# ONLY when `.branch` is present AND differs from the branch being
# evaluated right now. Same branch — including after an amend or a rebase
# that keeps the branch name — or a legacy/no-branch/malformed marker, all
# deny exactly as before.
#
# PART A (AC6) proves the PRODUCER: verify-gate.sh's self-heal cap writes
#   both `sha` and `branch`.
# PART B (AC7) proves the CONSUMER: merge-gate.sh's GATE 1, the branch-
#   pinned decision across same-branch (amend, rebase — the C4 repro) and
#   different-branch (genuinely stale) shapes, plus the legacy/malformed
#   fail-closed shapes.

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
VERIFY_GATE="${QX_VERIFY_GATE_HOOK:-$REPO_ROOT/plugins/quetrex-factory/scripts/verify-gate.sh}"
MERGE_GATE="${QX_MERGE_GATE_HOOK:-$REPO_ROOT/plugins/quetrex-factory/scripts/merge-gate.sh}"

for h in "$VERIFY_GATE" "$MERGE_GATE"; do
  [ -f "$h" ] || { echo "FAIL: hook not found at $h"; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq is not installed — both gates are jq-preferred and this contract is most reliably proven with it available"; exit 0; }

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

# =============================================================================
# PART A (AC6) — verify-gate.sh's self-heal cap writes a sha-pinned marker
# =============================================================================
FA="$(mktemp -d "${TMPDIR:-/tmp}/qx-escsha-a.XXXXXX")"
mkdir -p "$FA/.quetrex"
git -C "$FA" init -q -b main >/dev/null 2>&1 || git init -q "$FA" >/dev/null 2>&1
git -C "$FA" config user.email t@e.com; git -C "$FA" config user.name t
git -C "$FA" commit -q --allow-empty -m init
printf '{"branchPrefix":"claude/"}' > "$FA/.quetrex/project.json"
jq -cn '{verify:["false"]}' > "$FA/.quetrex/verify.json"   # always red
FA_HEAD="$(git -C "$FA" rev-parse HEAD)"

run_vg() {
  local root="$1" payload
  payload="$(jq -cn --arg cwd "$root" '{cwd:$cwd,hook_event_name:"Stop"}')"
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$root" QUETREX_VERIFY_MAX=3 "$VERIFY_GATE" >/dev/null 2>&1
}

run_vg "$FA" >/dev/null; run_vg "$FA" >/dev/null; run_vg "$FA" >/dev/null  # hit the cap

if [ -f "$FA/.quetrex/ESCALATION" ]; then
  ESC_SHA="$(jq -r '.sha // empty' "$FA/.quetrex/ESCALATION" 2>/dev/null)"
  if [ "$ESC_SHA" = "$FA_HEAD" ] && [[ "$ESC_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    ok "AC6: ESCALATION.sha ($ESC_SHA) is a 40-hex string equal to HEAD after the self-heal cap"
  else
    notok "AC6: ESCALATION.sha ('$ESC_SHA') does not equal HEAD ($FA_HEAD) or is not 40-hex"
  fi
  ESC_BRANCH="$(jq -r '.branch // empty' "$FA/.quetrex/ESCALATION" 2>/dev/null)"
  if [ "$ESC_BRANCH" = "main" ]; then
    ok "C4/AC6: ESCALATION.branch ($ESC_BRANCH) equals the branch the cap was hit on"
  else
    notok "C4/AC6: ESCALATION.branch ('$ESC_BRANCH') does not equal the expected branch (main)"
  fi
else
  notok "AC6: no .quetrex/ESCALATION written after 3 self-heal attempts on an always-red chain"
fi
rm -rf "$FA"

# --- AC6, HEAD unresolvable (0-commit repo): legacy shape, fail-closed -----
FB="$(mktemp -d "${TMPDIR:-/tmp}/qx-escsha-b.XXXXXX")"
mkdir -p "$FB/.quetrex"
git -C "$FB" init -q -b main >/dev/null 2>&1 || git init -q "$FB" >/dev/null 2>&1
git -C "$FB" config user.email t@e.com; git -C "$FB" config user.name t
printf '{"branchPrefix":"claude/"}' > "$FB/.quetrex/project.json"
jq -cn '{verify:["false"]}' > "$FB/.quetrex/verify.json"

run_vg "$FB" >/dev/null; run_vg "$FB" >/dev/null; run_vg "$FB" >/dev/null

if [ -f "$FB/.quetrex/ESCALATION" ]; then
  if jq -e '.sha' "$FB/.quetrex/ESCALATION" >/dev/null 2>&1; then
    notok "AC6: ESCALATION written with 0 commits still carries a usable .sha ('jq -e .sha' should fail — legacy fail-closed shape expected)"
  else
    ok "AC6: with HEAD unresolvable (0 commits), ESCALATION is the legacy shape — 'jq -e .sha' fails (fail-closed)"
  fi
else
  notok "AC6: no .quetrex/ESCALATION written after 3 self-heal attempts even with 0 commits"
fi
rm -rf "$FB"

# =============================================================================
# PART B (AC7, re-pinned to BRANCH by C4) — merge-gate.sh GATE 1
# =============================================================================
FC="$(mktemp -d "${TMPDIR:-/tmp}/qx-escsha-c.XXXXXX")"
git -C "$FC" init -q -b main
git -C "$FC" config user.email t@e.com; git -C "$FC" config user.name t
echo one > "$FC/f.txt"; git -C "$FC" add f.txt; git -C "$FC" commit -q -m c1
C1_SHA="$(git -C "$FC" rev-parse HEAD)"
echo two > "$FC/f.txt"; git -C "$FC" add f.txt; git -C "$FC" commit -q -m c2   # HEAD
HEAD_SHA="$(git -C "$FC" rev-parse HEAD)"
mkdir -p "$FC/.quetrex"
printf '{"branchPrefix":"claude/"}' > "$FC/.quetrex/project.json"

# An unrelated commit that is NOT an ancestor of main's HEAD (a disjoint
# history, built with --orphan so it shares nothing with main) — kept for
# the sha itself (fed into the fail-closed AC7(e) case below); no longer
# used to prove staleness, since staleness is branch-based now, not an
# ancestor test on sha.
git -C "$FC" checkout -q --orphan qx-unrelated
echo three > "$FC/g.txt"; git -C "$FC" add g.txt; git -C "$FC" commit -q -m unrelated
UNRELATED_SHA="$(git -C "$FC" rev-parse HEAD)"
git -C "$FC" checkout -q main
git -C "$FC" branch -q -D qx-unrelated

run_mg() {
  local payload
  payload="$(jq -cn --arg cwd "$FC" '{tool_input:{command:"git push origin main"},cwd:$cwd}')"
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$FC" bash "$MERGE_GATE" 2>&1
}
escalation_cited() { printf '%s' "$1" | grep -q '\.quetrex/ESCALATION is present'; }

# (a) marker {sha:HEAD, branch:main} — same branch -> deny, ESCALATE_HUMAN
jq -cn --arg sha "$HEAD_SHA" --arg branch "main" '{sha:$sha,branch:$branch,reason:"test"}' > "$FC/.quetrex/ESCALATION"
OUT="$(run_mg)"
if escalation_cited "$OUT" && printf '%s' "$OUT" | grep -q 'ESCALATE_HUMAN'; then
  ok "AC7(a): marker {sha:HEAD, branch:main} -> GATE 1 denies, reason contains ESCALATE_HUMAN"
else
  notok "AC7(a): marker {sha:HEAD, branch:main} did not deny with ESCALATE_HUMAN: [$OUT]"
fi

# (b) C4 REPRO — --amend. Marker pinned to the PRE-amend sha, same branch;
#     amend the tip commit (branch name unchanged, sha changes) and prove
#     GATE 1 STILL denies — this is the exact defect the review found: the
#     old ancestor-of-HEAD test satisfied "stale" here and silently cleared
#     a live escalation with no tampering of .quetrex/ required.
jq -cn --arg sha "$HEAD_SHA" --arg branch "main" '{sha:$sha,branch:$branch,reason:"test"}' > "$FC/.quetrex/ESCALATION"
# -m (not --no-edit) so the commit object genuinely differs even if this
# whole test runs inside the same wall-clock second as the original commit
# (git's timestamp granularity is 1s, so a content/message-identical amend
# within the same second would otherwise silently produce an IDENTICAL sha
# and this case would prove nothing).
git -C "$FC" commit -q --amend -m "c2 (amended)"
AMENDED_SHA="$(git -C "$FC" rev-parse HEAD)"
OUT="$(run_mg)"
if [ "$AMENDED_SHA" != "$HEAD_SHA" ] && escalation_cited "$OUT" && printf '%s' "$OUT" | grep -q 'ESCALATE_HUMAN'; then
  ok "C4/AC7(b): git commit --amend changes the sha but not the branch -> GATE 1 STILL denies (the C4 regression is fixed)"
else
  notok "C4/AC7(b): after --amend (new sha $AMENDED_SHA, same branch main), GATE 1 did not deny: [$OUT]"
fi

# (c) C4 REPRO — same-branch rebase shape. Reset the branch to an EARLIER
#     commit and add new history (the same branch name throughout, a
#     disjoint sha from the marker) — mirrors what a rebase does to a
#     branch's tip. GATE 1 must still deny: same branch, regardless of how
#     unrelated the current sha is to the one the marker recorded.
jq -cn --arg sha "$HEAD_SHA" --arg branch "main" '{sha:$sha,branch:$branch,reason:"test"}' > "$FC/.quetrex/ESCALATION"
git -C "$FC" reset -q --hard "$C1_SHA"
echo rebased > "$FC/f.txt"; git -C "$FC" add f.txt; git -C "$FC" commit -q -m "post-rebase commit"
REBASED_SHA="$(git -C "$FC" rev-parse HEAD)"
OUT="$(run_mg)"
if [ "$REBASED_SHA" != "$HEAD_SHA" ] && escalation_cited "$OUT" && printf '%s' "$OUT" | grep -q 'ESCALATE_HUMAN'; then
  ok "C4/AC7(c): a same-branch rebase (new, disjoint sha, same branch main) -> GATE 1 STILL denies"
else
  notok "C4/AC7(c): after a same-branch rebase (new sha $REBASED_SHA, same branch main), GATE 1 did not deny: [$OUT]"
fi
# restore HEAD to the original tip for the remaining cases
git -C "$FC" reset -q --hard "$HEAD_SHA"

# (d) marker names a DIFFERENT branch -> GATE 1 emits 0 deny decisions
#     (falls through to GATE 2, which may still deny for ITS OWN reason —
#     e.g. missing review-verdict.json — but GATE 1's ESCALATION-specific
#     text must not appear). This is the ONLY genuinely-stale shape now.
jq -cn --arg sha "$UNRELATED_SHA" --arg branch "qx-unrelated" '{sha:$sha,branch:$branch,reason:"test"}' > "$FC/.quetrex/ESCALATION"
OUT="$(run_mg)"
if escalation_cited "$OUT"; then
  notok "AC7(d): marker names a DIFFERENT branch (qx-unrelated), but GATE 1 still cited ESCALATION: [$OUT]"
else
  ok "AC7(d): marker names a DIFFERENT branch (qx-unrelated) than main -> GATE 1 emitted 0 deny decisions (ignored the stale marker, fell through to GATE 2)"
fi

# (e) legacy 0-byte marker -> deny, ESCALATE_HUMAN (no .branch at all fails closed)
: > "$FC/.quetrex/ESCALATION"
OUT="$(run_mg)"
if escalation_cited "$OUT" && printf '%s' "$OUT" | grep -q 'ESCALATE_HUMAN'; then
  ok "AC7(e): legacy 0-byte marker -> GATE 1 denies, reason contains ESCALATE_HUMAN"
else
  notok "AC7(e): legacy 0-byte marker did not deny with ESCALATE_HUMAN: [$OUT]"
fi

# (f) marker has a sha but NO .branch (old-shape / malformed) -> deny
#     (fail-closed) — a marker that cannot prove it names a different
#     branch is never treated as stale, regardless of what its sha is.
jq -cn --arg sha "abbaabbaabbaabbaabbaabbaabbaabbaabbaabba" '{sha:$sha,reason:"test"}' > "$FC/.quetrex/ESCALATION"
OUT="$(run_mg)"
if escalation_cited "$OUT" && printf '%s' "$OUT" | grep -q 'ESCALATE_HUMAN'; then
  ok "AC7(f): marker with a sha but no .branch -> GATE 1 denies (fail-closed), reason contains ESCALATE_HUMAN"
else
  notok "AC7(f): marker with a sha but no .branch did not deny (should fail closed): [$OUT]"
fi

rm -rf "$FC"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "escalation-sha-pin.test.sh: all checks passed"
else
  echo "escalation-sha-pin.test.sh: FAILURES above"
fi
exit "$FAIL"
