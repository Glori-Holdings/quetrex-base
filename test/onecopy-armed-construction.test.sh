#!/usr/bin/env bash
# test/onecopy-armed-construction.test.sh — SEC-ONECOPY-1 (High, round 2):
# "the project.json kill switch is narrowed, not closed". Round 1 tried to
# ENUMERATE the shell idioms that remove one working-tree file
# (rm/mv/cp/redirect/tee/git rm/git checkout --) and closed exactly those —
# leaving an open-ended list of equivalent one-liners still able to disarm
# the whole floor: `cd .quetrex && rm -f project.json`, a glob
# (`.quetrex/*.json`), `python3 -c "import os; os.remove(...)"`,
# `bash -c "rm -f ..."`, `find .quetrex -delete`, etc.
#
# ROUND 2 FIX (design A, orchestrator decision): stop enumerating command
# shapes and stop depending SOLELY on working-tree file state. The shared
# predicate plugins/quetrex-factory/scripts/qx-armed.sh's qx_repo_armed()
# treats a repo as armed if EITHER the working-tree file exists, OR
# .quetrex/project.json is tracked at HEAD, OR it is tracked at the tip of
# the repo's default branch. Once project.json is COMMITTED, no command run
# against the WORKING TREE alone can make this predicate return "unarmed"
# for that repo — closing the whole class of one-liner "by construction, not
# by enumeration" (round-2 mandate), rather than adding more cases to
# deny-guard's existing _kg_check_path enumeration (which remains in place
# as an active, belt-and-suspenders DENY of the common shapes — see
# deny-guard.sh's own check_quetrex_killswitch).
#
# AC1-AC7: unit coverage of qx_repo_armed()'s three signals in isolation
#          (working-tree file, HEAD-tracked, default-branch-tip-tracked,
#          and the fail-closed cases: empty root, non-repo root, no commits).
# AC8: THE MANDATORY END-TO-END TEST. In an ARMED fixture with a COMMIT
#      containing project.json, execute each of the round-2 disarm
#      one-liners FOR REAL (the file is actually gone from the working tree
#      afterward — this is not a dry run), then prove all three consuming
#      gates still hold:
#        - deny-guard.sh:  `rm -rf /`            -> still DENY
#        - enforce-branch.sh: `git commit -m x` on main -> still DENY
#        - verify-gate.sh: Stop with a red/undefined chain -> still block
# AC9: FAIL-FIRST (mechanical) against e384c11 (round-2 base sha): the SAME
#      disarm one-liner, against the OLD (pre-qx-armed.sh) deny-guard.sh and
#      enforce-branch.sh, DOES flip all three from DENY/block to silent
#      ALLOW — reproducing security-findings.json's own "END-TO-END PROOF"
#      for SEC-ONECOPY-1 exactly, proving round 2 is a genuine fix.
#
# Run: bash test/onecopy-armed-construction.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QX_ARMED="$REPO_ROOT/plugins/quetrex-factory/scripts/qx-armed.sh"
DENY_GUARD="${QX_DENY_GUARD_HOOK:-$REPO_ROOT/plugins/quetrex-factory/scripts/deny-guard.sh}"
ENFORCE_BRANCH="${QX_ENFORCE_BRANCH_HOOK:-$REPO_ROOT/plugins/quetrex-factory/scripts/enforce-branch.sh}"
VERIFY_GATE="${QX_VERIFY_GATE_HOOK:-$REPO_ROOT/plugins/quetrex-factory/scripts/verify-gate.sh}"
BASE_SHA_R2="e384c11"

for f in "$QX_ARMED" "$DENY_GUARD" "$ENFORCE_BRANCH" "$VERIFY_GATE"; do
  [ -f "$f" ] || { echo "FAIL: required file not found at $f"; echo; echo "onecopy-armed-construction.test.sh: 0 passed, 1 failed"; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq is not installed"; echo; echo "onecopy-armed-construction.test.sh: 0 passed, 0 failed"; exit 0; }

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

# =============================================================================
# AC1-AC7 — qx_repo_armed() unit coverage, sourced directly.
# =============================================================================
# shellcheck disable=SC1090
source "$QX_ARMED"

U1="$(mktemp -d "${TMPDIR:-/tmp}/qx-unit1.XXXXXX")"
git -C "$U1" init -q -b main
git -C "$U1" config user.email "t@example.com"; git -C "$U1" config user.name "T"

# AC1: no .quetrex at all -> unarmed
if qx_repo_armed "$U1"; then notok "AC1: expected unarmed for a repo with no .quetrex at all"; else ok "AC1: a repo with no .quetrex at all is unarmed"; fi

# AC2: working-tree file only (uncommitted) -> armed
mkdir -p "$U1/.quetrex"; printf '{}' > "$U1/.quetrex/project.json"
if qx_repo_armed "$U1"; then ok "AC2: an uncommitted working-tree project.json arms the repo (the /quetrex:init shape)"; else notok "AC2: expected armed for an uncommitted working-tree project.json"; fi

# AC3: committed at HEAD, then working-tree file deleted -> STILL armed
git -C "$U1" add .quetrex/project.json
echo x > "$U1/README.md"; git -C "$U1" add README.md
git -C "$U1" commit -q -m "chore: arm"
rm -f "$U1/.quetrex/project.json"
if qx_repo_armed "$U1"; then ok "AC3: deleting the working-tree file leaves the repo armed once project.json is committed at HEAD"; else notok "AC3: expected still-armed after deleting a HEAD-tracked working-tree file"; fi

# AC4: empty root -> unarmed, never throws
if qx_repo_armed ""; then notok "AC4: expected unarmed for an empty root"; else ok "AC4: an empty root is unarmed (and did not throw)"; fi

# AC5: non-repo directory -> unarmed, never throws
U5="$(mktemp -d "${TMPDIR:-/tmp}/qx-unit5.XXXXXX")"
if qx_repo_armed "$U5"; then notok "AC5: expected unarmed for a directory that is not a git repo"; else ok "AC5: a non-repo directory is unarmed (and did not throw)"; fi
rm -rf "$U5"

# AC6: a repo with zero commits (unborn HEAD) and no working-tree file -> unarmed, never throws
U6="$(mktemp -d "${TMPDIR:-/tmp}/qx-unit6.XXXXXX")"
git -C "$U6" init -q -b main
if qx_repo_armed "$U6"; then notok "AC6: expected unarmed for a zero-commit repo with no project.json"; else ok "AC6: a zero-commit repo with no project.json is unarmed (and did not throw)"; fi
rm -rf "$U6"

# AC7: armed at the default branch tip (origin/main) even with no local
# project.json at all — a bare "origin" remote stands in for a real push.
U7="$(mktemp -d "${TMPDIR:-/tmp}/qx-unit7.XXXXXX")"
BARE7="$(mktemp -d "${TMPDIR:-/tmp}/qx-unit7-bare.XXXXXX")"
git init -q --bare -b main "$BARE7"
git -C "$U7" init -q -b main
git -C "$U7" config user.email "t@example.com"; git -C "$U7" config user.name "T"
mkdir -p "$U7/.quetrex"; printf '{}' > "$U7/.quetrex/project.json"
git -C "$U7" add .quetrex/project.json
git -C "$U7" commit -q -m "chore: arm"
git -C "$U7" remote add origin "$BARE7"
git -C "$U7" push -q origin main
CLONE7="$(mktemp -d "${TMPDIR:-/tmp}/qx-unit7-clone.XXXXXX")"
git clone -q "$BARE7" "$CLONE7"
rm -rf "$CLONE7/.quetrex"
if qx_repo_armed "$CLONE7"; then
  ok "AC7: a fresh clone with no local .quetrex is armed via origin/main's tracked project.json"
else
  notok "AC7: expected armed via the default-branch-tip signal (origin/main) for a fresh clone"
fi
rm -rf "$U7" "$BARE7" "$CLONE7"
rm -rf "$U1"

# =============================================================================
# AC8 — THE MANDATORY END-TO-END TEST.
# =============================================================================
DISARM_ONE_LINERS=(
  'cd .quetrex && rm -f project.json'
  'rm -f .quetrex/*.json'
  "python3 -c \"import os; os.remove('.quetrex/project.json')\""
  'bash -c "rm -f .quetrex/project.json"'
  'find .quetrex -name project.json -delete'
)

new_committed_armed_fixture() {
  local f
  f="$(mktemp -d "${TMPDIR:-/tmp}/qx-e2e.XXXXXX")"
  git -C "$f" init -q -b main
  git -C "$f" config user.email "t@example.com"; git -C "$f" config user.name "T"
  mkdir -p "$f/.quetrex"
  printf '{"branchPrefix":"claude/"}' > "$f/.quetrex/project.json"
  printf '{"verify":["false"]}' > "$f/.quetrex/verify.json"
  echo readme > "$f/README.md"
  git -C "$f" add README.md .quetrex/project.json .quetrex/verify.json
  git -C "$f" commit -q -m "chore: arm (committed)"
  printf '%s' "$f"
}

is_deny()  { printf '%s' "$1" | grep -q '"permissionDecision":"deny"'; }
is_block() { printf '%s' "$1" | grep -q '"decision":"block"'; }
is_silent(){ [ -z "$1" ]; }

fire_dg() {  # fire_dg <hook> <command> <cwd>
  jq -cn --arg c "$2" --arg d "$3" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' \
    | env -u QUETREX_UNLOCK_FLOOR bash "$1" 2>&1
}
fire_eb() {  # fire_eb <hook> <command> <cwd>
  jq -cn --arg c "$2" --arg d "$3" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' \
    | env -u QUETREX_UNLOCK_FLOOR CLAUDE_PROJECT_DIR="$3" bash "$1" 2>&1
}
fire_vg() {  # fire_vg <hook> <cwd>
  jq -cn --arg d "$2" '{cwd:$d,hook_event_name:"Stop"}' \
    | env -u QUETREX_UNLOCK_FLOOR CLAUDE_PROJECT_DIR="$2" bash "$1" 2>&1
}

for D in "${DISARM_ONE_LINERS[@]}"; do
  F="$(new_committed_armed_fixture)"
  # Execute the disarm one-liner FOR REAL against the fixture's working tree.
  ( cd "$F" && eval "$D" ) >/dev/null 2>&1
  if [ -f "$F/.quetrex/project.json" ]; then
    notok "AC8 SETUP: disarm one-liner did not remove the working-tree file, cannot test the construction fix: $D"
  else
    ok "AC8 SETUP: disarm one-liner removed the working-tree project.json for real: $D"
  fi

  OUT_DG="$(fire_dg "$DENY_GUARD" "rm -rf /" "$F")"
  if is_deny "$OUT_DG"; then
    ok "AC8: deny-guard STILL DENIES 'rm -rf /' after [$D]"
  else
    notok "AC8: deny-guard no longer denies 'rm -rf /' after [$D] — got [$OUT_DG]"
  fi

  OUT_EB="$(fire_eb "$ENFORCE_BRANCH" "git commit -m x" "$F")"
  if is_deny "$OUT_EB"; then
    ok "AC8: enforce-branch STILL DENIES 'git commit' on main after [$D]"
  else
    notok "AC8: enforce-branch no longer denies 'git commit' on main after [$D] — got [$OUT_EB]"
  fi

  OUT_VG="$(fire_vg "$VERIFY_GATE" "$F")"
  if is_block "$OUT_VG"; then
    ok "AC8: verify-gate STILL GATES (blocks) after [$D]"
  else
    notok "AC8: verify-gate no longer gates after [$D] — got [$OUT_VG]"
  fi

  rm -rf "$F"
done

# =============================================================================
# AC9 — FAIL-FIRST (mechanical) against e384c11: the SAME disarm one-liner,
# against the OLD deny-guard.sh/enforce-branch.sh/verify-gate.sh (pre-
# qx-armed.sh, working-tree-file-only arming), flips all three from
# DENY/block to silent ALLOW — reproducing security-findings.json's
# SEC-ONECOPY-1 "END-TO-END PROOF" exactly.
# =============================================================================
if ! git -C "$REPO_ROOT" cat-file -e "${BASE_SHA_R2}^{commit}" 2>/dev/null; then
  notok "AC9 FAIL-FIRST: baseline commit $BASE_SHA_R2 is not reachable in this checkout — cannot prove SEC-ONECOPY-1 was still open pre-fix"
else
  F="$(new_committed_armed_fixture)"
  D='cd .quetrex && rm -f project.json'
  ( cd "$F" && eval "$D" ) >/dev/null 2>&1

  OLD_DG="$F/.old-deny-guard.sh"; OLD_EB="$F/.old-enforce-branch.sh"; OLD_VG="$F/.old-verify-gate.sh"
  git -C "$REPO_ROOT" show "$BASE_SHA_R2:plugins/quetrex-factory/scripts/deny-guard.sh" > "$OLD_DG" 2>/dev/null
  git -C "$REPO_ROOT" show "$BASE_SHA_R2:plugins/quetrex-factory/scripts/enforce-branch.sh" > "$OLD_EB" 2>/dev/null
  git -C "$REPO_ROOT" show "$BASE_SHA_R2:plugins/quetrex-factory/scripts/verify-gate.sh" > "$OLD_VG" 2>/dev/null

  OLD_DG_OUT="$(fire_dg "$OLD_DG" "rm -rf /" "$F")"
  OLD_EB_OUT="$(fire_eb "$OLD_EB" "git commit -m x" "$F")"
  OLD_VG_OUT="$(fire_vg "$OLD_VG" "$F")"

  if is_silent "$OLD_DG_OUT" && is_silent "$OLD_EB_OUT" && is_silent "$OLD_VG_OUT"; then
    ok "AC9 FAIL-FIRST: at $BASE_SHA_R2, [$D] flipped deny-guard/enforce-branch/verify-gate ALL to silent allow — SEC-ONECOPY-1 was real there, this is a genuine fix"
  else
    notok "AC9 FAIL-FIRST: expected all three to silently allow at $BASE_SHA_R2; deny-guard=[$OLD_DG_OUT] enforce-branch=[$OLD_EB_OUT] verify-gate=[$OLD_VG_OUT]"
  fi
  rm -rf "$F"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "onecopy-armed-construction.test.sh: all checks passed"
else
  echo "onecopy-armed-construction.test.sh: FAILURES above"
fi
exit "$FAIL"
