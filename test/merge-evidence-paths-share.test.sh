#!/usr/bin/env bash
# =============================================================================
# merge-evidence-paths-share.test.sh
#
# /quetrex:merge has two evidence routes — a cloud build's published gates
# branch, and a local build's on-disk .quetrex/. They must place the SAME set
# of artifacts into $REPO_ROOT/.quetrex/, because that directory is the single
# location merge-gate.sh reads.
#
# WHY THIS TEST EXISTS. The two routes used to carry the same six-name artifact
# list LITERALLY, forty lines apart, with plan/<TASK>.json appended by its own
# separate statement in each, and nothing pinned them equal. Within one commit
# they had already drifted in hardening: the local route unlinked its
# destination before writing, the remote route still used a bare `>` redirect
# that follows a destination symlink and writes THROUGH it. Add a seventh
# artifact to one loop and the other silently omits it — and while a missing
# REQUIRED artifact fails closed at the gate, security-findings.json is
# absent-legal, so that direction does not.
#
# HOW IT PINS THEM — MECHANICALLY, NOT BY GREP. Asserting each route's list
# separately is precisely the thing that drifts: both assertions get updated by
# whoever edits one route, or neither does. So this test RUNS the shipped §2
# transport fence twice against equivalent sources — once via the remote route,
# once via the local one, in two separate clones so neither can inherit the
# other's files — and compares the resulting file sets. If the routes ever
# place different files, the sets differ and this fails.
#
# It is fail-first by construction: it first mutates the shipped fence so the
# remote route places one extra artifact, proves the comparison CATCHES that
# divergence, and only then asserts the shipped fence passes. Without the RED
# half the GREEN half would prove nothing.
#
# Run:  bash test/merge-evidence-paths-share.test.sh
#       zsh  test/merge-evidence-paths-share.test.sh
# =============================================================================
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
MERGE_MD="$ROOT/.claude/commands/merge.md"

PASS=0; FAIL=0
ok()    { echo "ok - $*";     PASS=$((PASS+1)); }
notok() { echo "NOT OK - $*"; FAIL=$((FAIL+1)); }
finish() {
  echo
  echo "merge-evidence-paths-share.test.sh: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
}

command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
[ -f "$MERGE_MD" ] || { echo "NOT OK - merge.md not found at $MERGE_MD"; exit 1; }

# NEVER `for SH in $SHELLS` — zsh does not word-split an unquoted $VAR, so a
# two-word value collapses into ONE iteration with SH="bash zsh".
zsh_available=0
command -v zsh >/dev/null 2>&1 && zsh_available=1

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qx-paths-share.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Extraction — the shipped fence, never a hand-copy.
# ---------------------------------------------------------------------------
fence_after() {  # fence_after <file> <heading-substring> <n>
  awk -v h="$2" -v want="$3" '
    !seen && index($0, h) { seen = 1; next }
    !seen { next }
    /^```/ { if (inb) { inb = 0; n++; if (n == want) exit } else { inb = 1; if (n + 1 == want) next } ; next }
    inb && n + 1 == want { print }
  ' "$1"
}

TRANSPORT="$WORK/transport.sh"
fence_after "$MERGE_MD" '## 2. Bring the gate evidence home' 1 > "$TRANSPORT"
if [ -s "$TRANSPORT" ] && grep -q 'qx_place_all' "$TRANSPORT" && grep -q 'qx_gate_artifacts' "$TRANSPORT"; then
  ok "AC0: extracted §2's transport fence and it routes both paths through the shared helper"
else
  notok "AC0: §2's transport fence is missing, or no longer uses qx_gate_artifacts/qx_place_all — every assertion below would be vacuous"
  finish
fi

# The single-source claim, asserted structurally: exactly one artifact list.
LIST_DEFS="$(grep -c 'verify-ledger.jsonl' "$TRANSPORT")"
if [ "$LIST_DEFS" -eq 1 ]; then
  ok "AC1: the artifact set is named exactly ONCE in §2 (found $LIST_DEFS occurrence of verify-ledger.jsonl)"
else
  notok "AC1: the artifact set is named $LIST_DEFS times in §2 — a second literal list is exactly what drifts"
fi

# ---------------------------------------------------------------------------
# Fixture. A bare origin, a gates branch carrying the artifacts, and — for each
# route — its OWN clone, so one run can never inherit the other's files.
# ---------------------------------------------------------------------------
ORIGIN="$WORK/origin.git"
git init -q --bare -b main "$ORIGIN"
SEED="$WORK/seed"
git -C "$WORK" clone -q "$ORIGIN" seed 2>/dev/null
git -C "$SEED" config user.email t@e.com; git -C "$SEED" config user.name t
echo seed > "$SEED/README.md"
git -C "$SEED" add -A; git -C "$SEED" commit -q -m seed
git -C "$SEED" push -q origin main
PR_SHA="$(git -C "$SEED" rev-parse HEAD)"
TASK="T-1"

# write_artifacts <dir> — every artifact either route could place, plus a DECOY
# that neither should. The decoy is what proves the comparison is testing the
# routes' chosen SET and not merely "copy whatever is there".
write_artifacts() {
  local d="$1"
  mkdir -p "$d/plan"
  printf '%s\n' "$PR_SHA"                                  > "$d/gates-head"
  printf '{"verdict":"AUTO_MERGE","sha":"%s"}\n' "$PR_SHA" > "$d/review-verdict.json"
  printf '{"ts":"x","cmd":"true","sha":"%s","exit":0}\n' "$PR_SHA" > "$d/verify-ledger.jsonl"
  printf '{"verdict":"GREEN","sha":"%s"}\n' "$PR_SHA"      > "$d/qa-report.json"
  printf '{"head_sha":"%s","findings":[]}\n' "$PR_SHA"     > "$d/security-findings.json"
  printf '{"task":"%s"}\n' "$TASK"                         > "$d/state.json"
  printf '{"task":"%s","base_sha":"%s"}\n' "$TASK" "$PR_SHA" > "$d/plan/$TASK.json"
  printf '{"not":"an artifact"}\n'                         > "$d/decoy.json"
}

# The gates branch, built from the same artifact bytes.
GATES_BRANCH="claude/${TASK}-gates-abc1234"
GB="$WORK/gatesbuild"
git -C "$WORK" clone -q "$ORIGIN" gatesbuild 2>/dev/null
git -C "$GB" config user.email t@e.com; git -C "$GB" config user.name t
git -C "$GB" checkout -q -b "$GATES_BRANCH"
mkdir -p "$GB/.quetrex"
write_artifacts "$GB/.quetrex"
git -C "$GB" add -A -f .quetrex
git -C "$GB" commit -q -m "gates for $TASK"
git -C "$GB" push -q origin "$GATES_BRANCH"

# mkclone <name> -> prints the clone path, scaffolded with the non-artifact
# files /quetrex:merge expects to already exist.
mkclone() {
  local name="$1" d="$WORK/$1"
  git -C "$WORK" clone -q "$ORIGIN" "$name" 2>/dev/null
  git -C "$d" config user.email t@e.com; git -C "$d" config user.name t
  mkdir -p "$d/.quetrex"
  printf '{"branchPrefix":"claude/"}\n' > "$d/.quetrex/project.json"
  printf '{"verify":["true"]}\n'        > "$d/.quetrex/verify.json"
  printf '%s\n' "$d"
}

# facts <repo> <gates-branch> <local-evidence-dir>
facts() {
  local d="$1"
  {
    printf 'REPO_ROOT=%q\n' "$d"
    printf 'TASK=%q\n' "$TASK"
    printf 'PR_NUM=123\n'
    printf 'PR_SHA=%q\n' "$PR_SHA"
    printf 'GATES_BRANCH=%q\n' "$2"
    printf 'SPEC_BRANCH=quetrex-spec/%s\n' "$TASK"
    printf 'LOCAL_EVIDENCE_DIR=%q\n' "$3"
  } > "$d/.quetrex/merge-facts.env"
}

# placed <repo> — the artifact file set the fence put in .quetrex/, with the
# scaffolding this test created itself excluded.
placed() {
  ( cd "$1/.quetrex" 2>/dev/null && find . -type f \
      ! -name project.json ! -name verify.json ! -name merge-facts.env \
      | sed 's#^\./##' | LC_ALL=C sort )
}

# run_route <shell> <fence> <remote|local> -> prints the placed set
run_route() {
  local sh="$1" fence="$2" mode="$3" d
  d="$(mkclone "r$(date +%s%N 2>/dev/null || echo $$)$RANDOM")"
  if [ "$mode" = remote ]; then
    facts "$d" "$GATES_BRANCH" ""
  else
    local wt="$d-evidence"
    mkdir -p "$wt/.quetrex"
    write_artifacts "$wt/.quetrex"
    facts "$d" "" "$wt"
  fi
  ( cd "$d" && "$sh" "$fence" ) >/dev/null 2>&1
  placed "$d"
}

# ---------------------------------------------------------------------------
# AC2 (RED, fail-first) — a fence in which the remote route places ONE extra
# artifact must be CAUGHT. This is the drift the test exists to detect; if the
# comparison cannot see it here, AC3 below proves nothing.
# ---------------------------------------------------------------------------
DRIFTED="$WORK/drifted.sh"
awk '
  { print }
  /^  qx_place_all remote$/ && !done { print "  qx_place_artifact remote \"decoy.json\""; done=1 }
' "$TRANSPORT" > "$DRIFTED"
if grep -q 'qx_place_artifact remote "decoy.json"' "$DRIFTED"; then
  ok "AC2: built a drifted fence in which the remote route places one artifact the local route does not"
else
  notok "AC2: could not synthesize the drifted fence — the fail-first half is vacuous"
  finish
fi

for SH in bash zsh; do
  [ "$SH" = zsh ] && [ "$zsh_available" -ne 1 ] && continue

  D_REMOTE="$(run_route "$SH" "$DRIFTED" remote)"
  D_LOCAL="$(run_route "$SH" "$DRIFTED" local)"
  if [ "$D_REMOTE" != "$D_LOCAL" ]; then
    ok "AC2 [$SH]: RED — the drifted fence's two routes place DIFFERENT sets, and the comparison catches it"
  else
    notok "AC2 [$SH]: the drifted fence went undetected — both routes reported [$D_REMOTE]; this test cannot see drift"
  fi
  if printf '%s\n' "$D_REMOTE" | grep -qx 'decoy.json'; then
    ok "AC2 [$SH]: RED — the divergence is the extra artifact the drifted remote route placed"
  else
    notok "AC2 [$SH]: the drifted remote route did not place decoy.json — the mutation did not take effect"
  fi

  # -------------------------------------------------------------------------
  # AC3 (GREEN) — the SHIPPED fence: both routes place exactly the same set.
  # -------------------------------------------------------------------------
  S_REMOTE="$(run_route "$SH" "$TRANSPORT" remote)"
  S_LOCAL="$(run_route "$SH" "$TRANSPORT" local)"
  if [ -n "$S_REMOTE" ] && [ "$S_REMOTE" = "$S_LOCAL" ]; then
    ok "AC3 [$SH]: GREEN — both routes place an identical, non-empty artifact set"
  else
    notok "AC3 [$SH]: the routes diverge — remote=[$(printf '%s' "$S_REMOTE" | tr '\n' ' ')] local=[$(printf '%s' "$S_LOCAL" | tr '\n' ' ')]"
  fi

  # The set is the real one, and the decoy is NOT in it.
  for want in verify-ledger.jsonl review-verdict.json qa-report.json security-findings.json gates-head state.json "plan/$TASK.json"; do
    if printf '%s\n' "$S_REMOTE" | grep -qx -- "$want"; then
      ok "AC3 [$SH]: both routes placed $want"
    else
      notok "AC3 [$SH]: $want was not placed — set was [$(printf '%s' "$S_REMOTE" | tr '\n' ' ')]"
    fi
  done
  if printf '%s\n' "$S_REMOTE" | grep -qx 'decoy.json'; then
    notok "AC3 [$SH]: decoy.json was placed — the routes copy whatever is present rather than a defined set"
  else
    ok "AC3 [$SH]: decoy.json was NOT placed — the routes place a defined set, not everything present"
  fi

  # -------------------------------------------------------------------------
  # AC4 — the shared helper's destination-unlink now protects BOTH routes. The
  # remote route carried this weakness before local evidence existed; it is
  # fixed here only as a consequence of sharing one helper.
  # -------------------------------------------------------------------------
  for mode in remote local; do
    D="$(mkclone "sym-$mode-$SH")"
    OUTSIDE="$D/../outside-$mode-$SH.txt"
    printf 'PRECIOUS\n' > "$OUTSIDE"
    if [ "$mode" = remote ]; then
      facts "$D" "$GATES_BRANCH" ""
    else
      WT="$D-evidence"; mkdir -p "$WT/.quetrex"; write_artifacts "$WT/.quetrex"
      facts "$D" "" "$WT"
    fi
    ln -s "$OUTSIDE" "$D/.quetrex/review-verdict.json"
    ( cd "$D" && "$SH" "$TRANSPORT" ) >/dev/null 2>&1
    if grep -q PRECIOUS "$OUTSIDE" 2>/dev/null; then
      ok "AC4 [$SH/$mode]: a destination symlink was unlinked, not written through — the outside file is intact"
    else
      notok "AC4 [$SH/$mode]: the $mode route wrote THROUGH a destination symlink and clobbered a file outside .quetrex/"
    fi
    if [ -f "$D/.quetrex/review-verdict.json" ] && [ ! -L "$D/.quetrex/review-verdict.json" ]; then
      ok "AC4 [$SH/$mode]: the destination is now a real regular file"
    else
      notok "AC4 [$SH/$mode]: the destination is not a regular file after the run"
    fi
  done
done

finish
