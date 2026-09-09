#!/usr/bin/env bash
# test/merge-local-evidence.test.sh — /quetrex:merge accepts LOCAL gate
# evidence, by the same pin the remote path uses.
#
# Run: bash test/merge-local-evidence.test.sh
#
# OPERATOR EVIDENCE. "Seems /quetrex:merge can't handle local merges either.
# This needs to be fixed. We should be able to do both local and cloud."
#
# §1/§2 discovered gate evidence in exactly one place: a REMOTE branch
# `<prefix><TASK>-gates-*` whose committed .quetrex/gates-head equals the PR
# head. That is right for a cloud build, which publishes there. A build that ran
# LOCALLY publishes nothing — its seven artifacts are in the .quetrex/ of the
# checkout the pipeline ran in, usually a worktree of the same repo — so merge
# refused the merge for want of evidence that existed one directory away.
#
# WHAT THIS FILE PROVES. Not that merge.md "says" the right thing: it EXTRACTS
# the shipped exec block and the shipped §2 transport fence out of merge.md and
# RUNS them, under bash AND zsh, against real git repos, real worktrees and a
# real bare origin carrying a real gates branch.
#
#   AC1  local artifacts pinned to the PR head are DISCOVERED and COPIED into
#        $REPO_ROOT/.quetrex (all seven), and the printed line names the source
#        directory. A stale gates-head already at the destination is cleared
#        rather than left to contradict what was copied.
#   AC2  local artifacts pinned to a DIFFERENT sha are REFUSED, and nothing is
#        copied. Also: a gates-head that disagrees with the artifacts beside it
#        disqualifies the whole set.
#   AC3  remote AND local, both pinned to the PR head → the REMOTE set is the
#        one that lands, and one line says so while naming the local directory.
#   AC4  remote and local DISAGREE about the head → neither is used, both shas
#        are named, exit is non-zero, and $REPO_ROOT/.quetrex stays empty.
#   AC5  neither source → the message names BOTH possibilities (no published
#        gates branch, no local artifacts pinned to this head) and the prose
#        gives BOTH remedies (re-run the build / run the merge from the
#        worktree the local build used).
#   AC6  a worktree-resident evidence set is found via `git worktree list` —
#        the operator is standing in the main checkout, the evidence is not.
#   AC7  FAIL-FIRST against the literal pre-change sha 87dc34a (the main commit
#        this change is based on — never `main`, never a branch-only sha): that
#        merge.md carries no local-evidence discovery at all, and its own §2
#        fence, driven by this file's fixtures, finds nothing and copies
#        nothing.
#
# THE GATE IS NOT UNDER TEST HERE, AND THAT IS THE POINT: merge-gate.sh is
# untouched by this change. Local evidence changes what is DELIVERED to
# $REPO_ROOT/.quetrex, never what is required of it. test/merge-gate*.test.sh
# still own the gate's own rules.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MERGE_MD="$ROOT/.claude/commands/merge.md"
BASE_SHA="87dc34a"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }
finish() {
  printf '\n%s\n' "merge-local-evidence.test.sh: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
}

command -v node >/dev/null 2>&1 || { echo "SKIP: node unavailable — merge.md builds all its JSON with node"; exit 0; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
[ -f "$MERGE_MD" ] || { echo "NOT OK - merge.md not found at $MERGE_MD"; exit 1; }
if command -v zsh >/dev/null 2>&1; then SHELLS="bash zsh"; else SHELLS="bash"; fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qx-merge-local.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

ARTIFACTS="verify-ledger.jsonl review-verdict.json qa-report.json security-findings.json gates-head state.json"

# ---------------------------------------------------------------------------
# Extractors — everything executed below comes OUT of merge.md.
# ---------------------------------------------------------------------------

# fence_after <file> <heading-substring> <n> — the Nth ```-fenced block after
# the first line containing <heading-substring>. Same shape as
# test/merge-command.test.sh's, parameterised by file so the pre-change
# revision can be driven through the identical harness.
fence_after() {
  awk -v h="$2" -v want="$3" '
    !seen && index($0, h) { seen = 1; next }
    !seen { next }
    /^```/ { if (inb) { inb = 0; n++; if (n == want) exit } else { inb = 1; if (n + 1 == want) next } ; next }
    inb && n + 1 == want { print }
  ' "$1"
}

# exec_block <file> <name> — the shipped `quetrex:exec-block <name>` region.
exec_block() {
  awk -v name="$2" '
    $0 ~ ("quetrex:exec-block " name "([^A-Za-z0-9_]|$)") && $0 !~ ("end quetrex:exec-block") { inb=1 }
    inb { print }
    $0 ~ ("end quetrex:exec-block " name "([^A-Za-z0-9_]|$)") { inb=0 }
  ' "$1"
}

DISCOVER="$WORK/discover.sh"
exec_block "$MERGE_MD" qx_find_local_evidence > "$DISCOVER"
if [ -s "$DISCOVER" ] && grep -q 'qx_find_local_evidence()' "$DISCOVER" && bash -n "$DISCOVER" 2>/dev/null; then
  ok "AC0: extracted the shipped qx_find_local_evidence exec block ($(wc -l < "$DISCOVER" | tr -d ' ') lines) and it parses"
else
  notok "AC0: could not extract a parseable qx_find_local_evidence block from merge.md — every assertion below would pass vacuously"
  finish
fi

TRANSPORT="$WORK/transport.sh"
fence_after "$MERGE_MD" '## 2. Bring the gate evidence home' 1 > "$TRANSPORT"
if [ -s "$TRANSPORT" ] && grep -q 'LOCAL_EVIDENCE_DIR' "$TRANSPORT" && grep -q 'gates-head' "$TRANSPORT"; then
  ok "AC0: extracted §2's transport fence and it consults LOCAL_EVIDENCE_DIR"
else
  notok "AC0: §2's transport fence is missing or never mentions LOCAL_EVIDENCE_DIR"
  finish
fi

# ---------------------------------------------------------------------------
# Fixtures. A bare origin, a clone (the operator's checkout), and a worktree of
# that clone (where a local build would have run).
# ---------------------------------------------------------------------------
ORIGIN="$WORK/origin.git"
REPO="$WORK/repo"
git init -q --bare -b main "$ORIGIN"
git -C "$WORK" clone -q "$ORIGIN" repo 2>/dev/null
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Fixture"
echo "fixture" > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m "chore: fixture"
git -C "$REPO" push -q origin main
PR_SHA="$(git -C "$REPO" rev-parse HEAD)"
OTHER_SHA="0123456789abcdef0123456789abcdef01234567"

git -C "$REPO" worktree add -q -b feature/loc-1 "$WORK/wt" >/dev/null 2>&1
# git resolves a worktree path through its realpath; compare against the same.
WT="$(git -C "$REPO" worktree list --porcelain | sed -n 's/^worktree //p' | sed -n '2p')"
if [ -n "$WT" ] && [ -d "$WT" ]; then
  ok "AC0: fixture worktree registered at $WT"
else
  notok "AC0: could not create the fixture worktree — AC6 would prove nothing"
  finish
fi

# write_evidence <dir> <sha> <label> [gates-head-sha|"-" for none]
write_evidence() {
  local d="$1" sha="$2" label="$3"
  local gh="${4:-}"
  mkdir -p "$d/.quetrex/plan"
  printf '{"verdict":"AUTO_MERGE","sha":"%s","source":"%s","confirmed":[],"inputs":{"nativeSecurityReview":"clean"}}\n' "$sha" "$label" > "$d/.quetrex/review-verdict.json"
  printf '{"ts":"2026-01-01T00:00:00Z","cmd":"true","sha":"%s","exit":0,"tail":""}\n' "$sha" > "$d/.quetrex/verify-ledger.jsonl"
  printf '{"task":"LOC-1","base":"main","head_sha":"%s","verdict":"PASS","findings":[]}\n' "$sha" > "$d/.quetrex/security-findings.json"
  printf '{"units":1,"source":"%s"}\n' "$label" > "$d/.quetrex/qa-report.json"
  printf '{"task":"LOC-1","source":"%s"}\n' "$label" > "$d/.quetrex/state.json"
  printf '{"task":"LOC-1","source":"%s","security_review_required":false,"ownership":{"README.md":"dev-a"}}\n' "$label" > "$d/.quetrex/plan/LOC-1.json"
  case "$gh" in
    ""|"-") rm -f "$d/.quetrex/gates-head" ;;
    *)      printf '%s\n' "$gh" > "$d/.quetrex/gates-head" ;;
  esac
}

# publish_gates <branch> <gates-head-sha> <label> — the branch a CLOUD build pushes.
publish_gates() {
  local branch="$1" gh="$2" label="$3"
  local gb="$WORK/gb-$label"
  rm -rf "$gb"
  git -C "$WORK" clone -q "$ORIGIN" "gb-$label" 2>/dev/null
  git -C "$gb" config user.email "test@example.com"
  git -C "$gb" config user.name "Fixture"
  git -C "$gb" switch -q --orphan "$branch"
  git -C "$gb" rm -rq --cached . 2>/dev/null
  rm -f "$gb/README.md"
  write_evidence "$gb" "$gh" "$label" "$gh"
  git -C "$gb" add -f .quetrex/gates-head .quetrex/review-verdict.json .quetrex/qa-report.json \
    .quetrex/security-findings.json .quetrex/verify-ledger.jsonl .quetrex/state.json .quetrex/plan/LOC-1.json
  git -C "$gb" commit -q -m "gates: LOC-1 ($label)"
  git -C "$gb" push -q origin "$branch"
}

reset_dest() { rm -rf "$REPO/.quetrex"; mkdir -p "$REPO/.quetrex"; }

# facts <gates-branch> <local-evidence-dir> — the merge-facts.env §1 writes.
facts() {
  mkdir -p "$REPO/.quetrex"
  {
    printf "TASK='%s'\n"               "LOC-1"
    printf "REPO_ROOT='%s'\n"          "$REPO"
    printf "SLUG='%s'\n"               "glori-holdings/fixture"
    printf "IS_EPIC='%s'\n"            "0"
    printf "PR_NUM='%s'\n"             "42"
    printf "PR_SHA='%s'\n"             "$PR_SHA"
    printf "GATES_BRANCH='%s'\n"       "$1"
    printf "SPEC_BRANCH='%s'\n"        "quetrex-spec/LOC-1"
    printf "LOCAL_EVIDENCE_DIR='%s'\n" "$2"
  } > "$REPO/.quetrex/merge-facts.env"
}

# run_transport <shell> [fence] — execute §2's shipped fence from inside the
# checkout. Prints the output; the exit status lands in $WORK/rc, read via rc().
#
# The rc goes through a FILE, not a variable: run_transport is called inside a
# command substitution, so anything it assigns dies with that subshell. An
# earlier draft set a TRANSPORT_RC variable directly and every exit-status assertion read
# a stale 0 — i.e. AC4 reported "disagreeing evidence was allowed through"
# while the shipped fence was in fact exiting 1.
run_transport() {
  local sh_bin="$1" fence="${2:-$TRANSPORT}"
  ( cd "$REPO" && "$sh_bin" "$fence" 2>&1; echo "$?" > "$WORK/rc" )
}
rc() { cat "$WORK/rc" 2>/dev/null || echo 0; }

# run_discover <shell> — source the exec block and call it.
run_discover() {
  local sh_bin="$1"
  printf '. %s\nqx_find_local_evidence %s %s\n' "'$DISCOVER'" "'$REPO'" "'$PR_SHA'" > "$WORK/run-discover.sh"
  "$sh_bin" "$WORK/run-discover.sh" 2>/dev/null
}

# dest_has <file...> — every named artifact present and non-empty at the destination.
dest_has() {
  local f
  for f in "$@"; do [ -s "$REPO/.quetrex/$f" ] || return 1; done
  return 0
}
dest_source() {
  [ -s "$REPO/.quetrex/$1" ] || return 0
  node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(String(JSON.parse(s).source||""))}catch{}})' < "$REPO/.quetrex/$1" 2>/dev/null
}

# ===========================================================================
# AC1 / AC6 — a worktree-resident, head-pinned set is found and copied.
# ===========================================================================
for sh_bin in $SHELLS; do
  reset_dest
  write_evidence "$WT" "$PR_SHA" "local" "$PR_SHA"

  FOUND="$(run_discover "$sh_bin")"
  if [ "$FOUND" = "$WT" ]; then
    ok "AC6 [$sh_bin]: evidence living in a WORKTREE (not the operator's checkout) is found via git worktree list"
  else
    notok "AC6 [$sh_bin]: expected the worktree $WT, got '$FOUND'"
  fi

  facts "" "$WT"
  OUT="$(run_transport "$sh_bin")"
  if dest_has $ARTIFACTS "plan/LOC-1.json"; then
    ok "AC1 [$sh_bin]: all SEVEN artifacts were copied from the local evidence dir into \$REPO_ROOT/.quetrex"
  else
    notok "AC1 [$sh_bin]: local transport did not deliver every artifact (output: $(printf '%s' "$OUT" | tr '\n' '|'))"
  fi
  if [ "$(dest_source state.json)" = "local" ] && [ "$(dest_source review-verdict.json)" = "local" ]; then
    ok "AC1 [$sh_bin]: the artifacts at the destination are the LOCAL ones (not a leftover)"
  else
    notok "AC1 [$sh_bin]: destination artifacts are not the local set"
  fi
  if printf '%s' "$OUT" | grep -qF "$WT"; then
    ok "AC1 [$sh_bin]: the printed line names the source directory ($WT) — the operator can see what authorized the merge"
  else
    notok "AC1 [$sh_bin]: the output never names the source directory: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi
  if [ "$(rc)" -eq 0 ]; then
    ok "AC1 [$sh_bin]: the local route exits 0"
  else
    notok "AC1 [$sh_bin]: the local route exited $(rc)"
  fi
done

# AC1b — a local build usually writes no gates-head. The other six + the plan
# must still land, and a STALE gates-head already at the destination must not
# survive to contradict them.
reset_dest
printf '%s\n' "$OTHER_SHA" > "$REPO/.quetrex/gates-head"
write_evidence "$WT" "$PR_SHA" "local" "-"
facts "" "$WT"
OUT="$(run_transport bash)"
if dest_has verify-ledger.jsonl review-verdict.json qa-report.json security-findings.json state.json "plan/LOC-1.json" \
   && [ ! -e "$REPO/.quetrex/gates-head" ]; then
  ok "AC1b: with no gates-head in the local set, the rest still lands and a STALE destination gates-head is cleared, not left contradicting it"
else
  notok "AC1b: gates-head handling is wrong (present=$([ -e "$REPO/.quetrex/gates-head" ] && echo yes || echo no)); output: $(printf '%s' "$OUT" | tr '\n' '|')"
fi

# ===========================================================================
# AC2 — evidence pinned to a DIFFERENT commit is refused; nothing is copied.
# ===========================================================================
for sh_bin in $SHELLS; do
  reset_dest
  write_evidence "$WT" "$OTHER_SHA" "wrong-sha" "$OTHER_SHA"
  FOUND="$(run_discover "$sh_bin")"
  if [ -z "$FOUND" ]; then
    ok "AC2 [$sh_bin]: artifacts pinned to another commit are NOT accepted as evidence for this PR head"
  else
    notok "AC2 [$sh_bin]: accepted evidence pinned to $OTHER_SHA as if it described $PR_SHA (got '$FOUND')"
  fi

  facts "" "$FOUND"
  OUT="$(run_transport "$sh_bin")"
  if ! dest_has review-verdict.json && ! dest_has verify-ledger.jsonl && ! dest_has state.json; then
    ok "AC2 [$sh_bin]: nothing was copied — the refusal is a no-op at the destination, not a partial delivery"
  else
    notok "AC2 [$sh_bin]: refused evidence was copied anyway"
  fi
done

# AC2b — a gates-head that disagrees with the artifacts beside it disqualifies
# the set, even though every artifact itself pins the PR head.
reset_dest
write_evidence "$WT" "$PR_SHA" "local" "$OTHER_SHA"
FOUND="$(run_discover bash)"
if [ -z "$FOUND" ]; then
  ok "AC2b: a gates-head naming a different commit than the artifacts beside it disqualifies the whole set"
else
  notok "AC2b: accepted a set whose gates-head ($OTHER_SHA) contradicts its artifacts ($PR_SHA)"
fi

# AC2c — an incomplete set (no review verdict) is not evidence.
reset_dest
write_evidence "$WT" "$PR_SHA" "local" "-"
rm -f "$WT/.quetrex/review-verdict.json"
if [ -z "$(run_discover bash)" ]; then
  ok "AC2c: a set with no review-verdict.json is not accepted"
else
  notok "AC2c: accepted a set with no review-verdict.json"
fi

# ===========================================================================
# AC3 — both sources pinned to the PR head → the REMOTE set wins, and says so.
# ===========================================================================
publish_gates "claude/LOC-1-gates-aaaaaaa" "$PR_SHA" "remote"
for sh_bin in $SHELLS; do
  reset_dest
  write_evidence "$WT" "$PR_SHA" "local" "$PR_SHA"
  facts "claude/LOC-1-gates-aaaaaaa" "$WT"
  OUT="$(run_transport "$sh_bin")"
  if [ "$(dest_source state.json)" = "remote" ] && [ "$(dest_source review-verdict.json)" = "remote" ]; then
    ok "AC3 [$sh_bin]: with both sources pinned to the head, the REMOTE gates branch is the one that lands"
  else
    notok "AC3 [$sh_bin]: the local set won (state.json source='$(dest_source state.json)'); output: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi
  if printf '%s' "$OUT" | grep -qF "$WT" && printf '%s' "$OUT" | grep -qi 'remote'; then
    ok "AC3 [$sh_bin]: one line says the local set was seen and the remote preferred, naming both"
  else
    notok "AC3 [$sh_bin]: the precedence was silent: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi
  if [ "$(rc)" -eq 0 ]; then
    ok "AC3 [$sh_bin]: agreement is not an error — exit 0"
  else
    notok "AC3 [$sh_bin]: exited $(rc) on agreeing evidence"
  fi
done

# ===========================================================================
# AC4 — the two sources DISAGREE about the head → neither, both shas named.
# ===========================================================================
publish_gates "claude/LOC-1-gates" "$OTHER_SHA" "stale-remote"   # the legacy fixed-name ref §1 falls back to
for sh_bin in $SHELLS; do
  reset_dest
  write_evidence "$WT" "$PR_SHA" "local" "$PR_SHA"
  facts "claude/LOC-1-gates" "$WT"
  OUT="$(run_transport "$sh_bin")"
  if [ "$(rc)" -ne 0 ]; then
    ok "AC4 [$sh_bin]: disagreeing evidence stops the command (exit $(rc))"
  else
    notok "AC4 [$sh_bin]: disagreeing evidence was allowed through: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi
  if printf '%s' "$OUT" | grep -qF "$OTHER_SHA" && printf '%s' "$OUT" | grep -qF "$PR_SHA"; then
    ok "AC4 [$sh_bin]: both shas are named — the remote's ($OTHER_SHA) and the local's"
  else
    notok "AC4 [$sh_bin]: the conflict message does not name both shas: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi
  if ! dest_has review-verdict.json && ! dest_has state.json; then
    ok "AC4 [$sh_bin]: NEITHER set was copied — no half-delivered evidence is left for the gate to read"
  else
    notok "AC4 [$sh_bin]: something was copied despite the conflict (state.json source='$(dest_source state.json)')"
  fi
done

# ===========================================================================
# AC5 — neither source: name both possibilities, and both remedies.
# ===========================================================================
rm -rf "$WT/.quetrex"
for sh_bin in $SHELLS; do
  reset_dest
  if [ -z "$(run_discover "$sh_bin")" ]; then
    ok "AC5 [$sh_bin]: with no artifacts anywhere, discovery finds nothing (rather than offering the checkout it is standing in)"
  else
    notok "AC5 [$sh_bin]: discovery invented evidence out of an empty tree"
  fi
  facts "" ""
  OUT="$(run_transport "$sh_bin")"
  if printf '%s' "$OUT" | grep -qi 'no gates branch' && printf '%s' "$OUT" | grep -qi 'local'; then
    ok "AC5 [$sh_bin]: the no-evidence line names BOTH possibilities — no gates branch AND no local artifacts"
  else
    notok "AC5 [$sh_bin]: the no-evidence line names only one source: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi
  if ! dest_has review-verdict.json; then
    ok "AC5 [$sh_bin]: nothing is delivered when nothing was found"
  else
    notok "AC5 [$sh_bin]: artifacts appeared at the destination from nowhere"
  fi
done

# The two remedies live in the prose §2 tells the operator to say. Both must be
# there: "re-run the build" alone is the wrong advice for a local build whose
# worktree is still on disk.
NOEV="$(awk '/^With no evidence at all/,/^\*\*If `IS_EPIC=1`/' "$MERGE_MD")"
if printf '%s' "$NOEV" | grep -q 'task-build' \
   && printf '%s' "$NOEV" | grep -qi 'worktree' \
   && printf '%s' "$NOEV" | grep -qi 'no local'; then
  ok "AC5: the no-evidence message names both possibilities and both remedies (re-run the build / run the merge from the local build's worktree)"
else
  notok "AC5: the no-evidence message is missing a possibility or a remedy"
fi

# ===========================================================================
# THE GATE IS UNCHANGED — proved mechanically, not asserted in prose.
# ===========================================================================
# The whole claim of this change is that a local build merges only on the same
# evidence a cloud build needs. The strongest available proof is that the file
# making that decision did not move: merge-gate.sh must be byte-identical to
# its pre-change self.
GATE="$ROOT/plugins/quetrex-factory/scripts/merge-gate.sh"
if git -C "$ROOT" show "$BASE_SHA:plugins/quetrex-factory/scripts/merge-gate.sh" 2>/dev/null | cmp -s - "$GATE"; then
  ok "AC5: merge-gate.sh is byte-identical to $BASE_SHA — the gate was not weakened, special-cased, or taught about local builds"
else
  notok "AC5: merge-gate.sh differs from $BASE_SHA — this change must not touch the gate"
fi
# And nothing in the transport reaches for an unlock or an admin merge.
if ! grep -qE 'QUETREX_UNLOCK_FLOOR|--admin|--force|no-verify' "$TRANSPORT"; then
  ok "AC5: §2's transport carries no unlock, no --admin and no --force — it changes what is delivered, not what is required"
else
  notok "AC5: §2's transport fence reaches for a bypass"
fi

# ===========================================================================
# AC7 — FAIL-FIRST against the literal pre-change sha.
# ===========================================================================
OLD_MD="$WORK/merge-$BASE_SHA.md"
if git -C "$ROOT" show "$BASE_SHA:.claude/commands/merge.md" > "$OLD_MD" 2>/dev/null && [ -s "$OLD_MD" ]; then
  ok "AC7: fetched .claude/commands/merge.md at the pre-change sha $BASE_SHA"

  if [ -z "$(exec_block "$OLD_MD" qx_find_local_evidence)" ] && ! grep -q 'LOCAL_EVIDENCE_DIR' "$OLD_MD"; then
    ok "AC7: at $BASE_SHA merge.md has no local-evidence discovery at all — the gap, in the source"
  else
    notok "AC7: $BASE_SHA already carries local-evidence discovery; this test is measuring nothing"
  fi

  OLD_TRANSPORT="$WORK/transport-old.sh"
  fence_after "$OLD_MD" '## 2. Bring the gate evidence home' 1 > "$OLD_TRANSPORT"
  if [ -s "$OLD_TRANSPORT" ] && grep -q 'GATES_OK' "$OLD_TRANSPORT"; then
    ok "AC7: extracted $BASE_SHA's own §2 transport fence"
  else
    notok "AC7: could not extract $BASE_SHA's §2 fence — the fail-first proof would be vacuous"
  fi

  # Drive the OLD shipped fence with THIS file's local-evidence fixture: a
  # head-pinned set sitting in the worktree, and no gates branch on origin.
  reset_dest
  write_evidence "$WT" "$PR_SHA" "local" "$PR_SHA"
  facts "" "$WT"
  OLD_OUT="$(cd "$REPO" && bash "$OLD_TRANSPORT" 2>&1)"
  if ! dest_has review-verdict.json && ! dest_has verify-ledger.jsonl && ! dest_has state.json; then
    ok "AC7: RED — $BASE_SHA's §2 copies NOTHING while head-pinned evidence sits in $WT (the operator's defect, reproduced)"
  else
    notok "AC7: $BASE_SHA's §2 delivered artifacts from the local set — the reproduction is broken"
  fi
  if ! printf '%s' "$OLD_OUT" | grep -qF "$WT"; then
    ok "AC7: RED — $BASE_SHA's §2 never so much as mentions the local evidence directory: on-disk artifacts are invisible to it"
  else
    notok "AC7: $BASE_SHA's §2 named the local directory — the reproduction is broken: $(printf '%s' "$OLD_OUT" | tr '\n' '|')"
  fi

  # AC7b — the second, quieter half of the same gap: with GATES_BRANCH empty
  # (§1's value when origin carries no gates ref), `git fetch origin ""` is a
  # SUCCESSFUL default fetch, so $BASE_SHA took its GATES_OK=1 branch and
  # announced a fetch it had not made, with a blank branch name and a blank
  # pin, while deleting every artifact it failed to `show`.
  if printf '%s' "$OLD_OUT" | grep -q 'Fetched gate evidence from  (pinned to )'; then
    ok "AC7b: RED — with no gates ref, $BASE_SHA still printed 'Fetched gate evidence from  (pinned to )'"
  else
    notok "AC7b: could not reproduce the empty-refspec false fetch at $BASE_SHA: $(printf '%s' "$OLD_OUT" | tr '\n' '|')"
  fi

  # And GREEN: the shipped fence, same fixture, delivers.
  reset_dest
  facts "" "$WT"
  NEW_OUT="$(cd "$REPO" && bash "$TRANSPORT" 2>&1)"
  if dest_has $ARTIFACTS "plan/LOC-1.json"; then
    ok "AC7: GREEN — the shipped §2, same fixture, brings the local evidence home"
  else
    notok "AC7: the shipped §2 did not deliver on the fixture $BASE_SHA fails on: $(printf '%s' "$NEW_OUT" | tr '\n' '|')"
  fi
  reset_dest
  facts "" ""
  NEW_EMPTY="$(cd "$REPO" && bash "$TRANSPORT" 2>&1)"
  if ! printf '%s' "$NEW_EMPTY" | grep -q 'Fetched gate evidence from'; then
    ok "AC7b: GREEN — the shipped §2 guards the empty branch name and never claims a fetch it did not make"
  else
    notok "AC7b: the shipped §2 still announces a fetch with no gates ref: $(printf '%s' "$NEW_EMPTY" | tr '\n' '|')"
  fi
else
  notok "AC7: could not read merge.md at $BASE_SHA — the fail-first baseline is unavailable"
fi

# ---------------------------------------------------------------------------
# AC8 — SYMLINKS. Discovery walks directories it does not own and the transport
# copies into a directory anything on the machine may have touched, so both
# ends have to distinguish "the file the build wrote" from "a link standing
# where that file should be". Two separate holes, both found by execution
# against 8a17394 and both fixed here; the baseline is 8a17394 (not $BASE_SHA)
# because that is the revision where local discovery first existed AND followed
# links.
# ---------------------------------------------------------------------------
SYM_SHA="8a17394"
SYM_MD="$WORK/merge-sym-base.md"
if git -C "$ROOT" show "$SYM_SHA:.claude/commands/merge.md" > "$SYM_MD" 2>/dev/null && [ -s "$SYM_MD" ]; then
  ok "AC8: fetched merge.md at $SYM_SHA — the revision that shipped discovery before it refused links"
  SYM_DISCOVER="$WORK/discover-sym.sh"
  SYM_TRANSPORT="$WORK/transport-sym.sh"
  exec_block "$SYM_MD" qx_find_local_evidence > "$SYM_DISCOVER"
  fence_after "$SYM_MD" '## 2. Bring the gate evidence home' 1 > "$SYM_TRANSPORT"
  if [ -s "$SYM_DISCOVER" ] && [ -s "$SYM_TRANSPORT" ]; then
    ok "AC8: extracted $SYM_SHA's discovery block and §2 fence"
  else
    notok "AC8: could not extract $SYM_SHA's blocks — the fail-first proof would be vacuous"
  fi

  # --- 8a: a symlink at the COPY DESTINATION must not be written through -----
  # cp -f opens the destination O_TRUNC. On a symlink that writes the TARGET,
  # so a link planted at .quetrex/<artifact> turns the transport into a
  # write primitive aimed anywhere the operator can write.
  for SH in $SHELLS; do
    OUTSIDE="$WORK/outside-$SH"; mkdir -p "$OUTSIDE"
    VICTIM="$OUTSIDE/victim.txt"
    write_evidence "$WT" "$PR_SHA" "local" "$PR_SHA"

    reset_dest; facts "" "$WT"
    printf 'ORIGINAL\n' > "$VICTIM"
    ln -s "$VICTIM" "$REPO/.quetrex/review-verdict.json"
    run_transport "$SH" "$SYM_TRANSPORT" >/dev/null 2>&1
    if [ "$(cat "$VICTIM")" != "ORIGINAL" ]; then
      ok "AC8a [$SH]: RED — $SYM_SHA's §2 wrote THROUGH the destination symlink and clobbered a file outside .quetrex/"
    else
      notok "AC8a [$SH]: could not reproduce the write-through at $SYM_SHA — the fix would prove nothing"
    fi

    reset_dest; facts "" "$WT"
    printf 'ORIGINAL\n' > "$VICTIM"
    ln -s "$VICTIM" "$REPO/.quetrex/review-verdict.json"
    run_transport "$SH" >/dev/null 2>&1
    if [ "$(cat "$VICTIM")" = "ORIGINAL" ]; then
      ok "AC8a [$SH]: GREEN — the shipped §2 unlinks the destination first; the outside file is untouched"
    else
      notok "AC8a [$SH]: the shipped §2 STILL writes through a destination symlink — the hole is open"
    fi
    if [ ! -L "$REPO/.quetrex/review-verdict.json" ] && [ -s "$REPO/.quetrex/review-verdict.json" ]; then
      ok "AC8a [$SH]: the destination is now a real regular file carrying the build's own verdict"
    else
      notok "AC8a [$SH]: destination is still a symlink, or the copy did not land"
    fi
  done

  # --- 8b: a worktree whose .quetrex is a SYMLINK is not evidence ------------
  SYMWT="$WORK/wt-symlink"
  git -C "$REPO" worktree add -q -b feature/loc-sym "$SYMWT" >/dev/null 2>&1
  SYMWT="$(git -C "$REPO" worktree list --porcelain | sed -n 's/^worktree //p' | grep 'wt-symlink' | head -1)"
  PLANTED="$WORK/planted"
  if [ -n "$SYMWT" ]; then
    rm -rf "$PLANTED"; mkdir -p "$PLANTED"
    write_evidence "$PLANTED" "$PR_SHA" "planted" "$PR_SHA"
    # The worktree's .quetrex IS a link to a directory the worktree never wrote.
    rm -rf "$SYMWT/.quetrex"
    ln -s "$PLANTED/.quetrex" "$SYMWT/.quetrex"
    # Nothing else on the machine may answer for this head, or 8b proves nothing.
    rm -rf "$WT/.quetrex"; reset_dest
    for SH in $SHELLS; do
      OLD_HIT="$(printf '. %s\nqx_find_local_evidence %s %s\n' "'$SYM_DISCOVER'" "'$REPO'" "'$PR_SHA'" > "$WORK/rd.sh"; "$SH" "$WORK/rd.sh" 2>/dev/null)"
      if [ "$OLD_HIT" = "$SYMWT" ]; then
        ok "AC8b [$SH]: RED — $SYM_SHA's discovery followed the symlinked .quetrex and accepted planted evidence"
      else
        notok "AC8b [$SH]: could not reproduce the symlinked-.quetrex accept at $SYM_SHA (got [$OLD_HIT])"
      fi
      NEW_HIT="$(run_discover "$SH")"
      if [ -z "$NEW_HIT" ]; then
        ok "AC8b [$SH]: GREEN — the shipped discovery refuses a worktree whose .quetrex is a symlink"
      else
        notok "AC8b [$SH]: the shipped discovery STILL accepted the symlinked .quetrex (got [$NEW_HIT])"
      fi
    done
    git -C "$REPO" worktree remove --force "$SYMWT" >/dev/null 2>&1
  else
    notok "AC8b: could not create the symlink fixture worktree"
  fi

  # --- 8c: a symlinked ARTIFACT is refused HARD, never softened to "absent" --
  # security-findings.json is absent-legal, so resolving a planted link there —
  # or reporting it as missing — would turn a redirect into a silent pass.
  write_evidence "$WT" "$PR_SHA" "local" "$PR_SHA"
  rm -rf "$PLANTED"; mkdir -p "$PLANTED/.quetrex"
  printf '{"task":"LOC-1","head_sha":"%s","verdict":"PASS","findings":[]}\n' "$PR_SHA" > "$PLANTED/.quetrex/security-findings.json"
  rm -f "$WT/.quetrex/security-findings.json"
  ln -s "$PLANTED/.quetrex/security-findings.json" "$WT/.quetrex/security-findings.json"
  reset_dest
  for SH in $SHELLS; do
    if [ -n "$(printf '. %s\nqx_find_local_evidence %s %s\n' "'$SYM_DISCOVER'" "'$REPO'" "'$PR_SHA'" > "$WORK/rd.sh"; "$SH" "$WORK/rd.sh" 2>/dev/null)" ]; then
      ok "AC8c [$SH]: RED — $SYM_SHA's discovery read the symlinked security-findings.json straight through"
    else
      notok "AC8c [$SH]: could not reproduce the symlinked-artifact read at $SYM_SHA"
    fi
    if [ -z "$(run_discover "$SH")" ]; then
      ok "AC8c [$SH]: GREEN — the shipped discovery refuses a symlinked artifact instead of resolving it or calling it absent"
    else
      notok "AC8c [$SH]: the shipped discovery STILL followed the symlinked security-findings.json"
    fi
  done
  rm -f "$WT/.quetrex/security-findings.json"
else
  notok "AC8: could not read merge.md at $SYM_SHA — the symlink fail-first baseline is unavailable"
fi

finish
