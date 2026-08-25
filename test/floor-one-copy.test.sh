#!/usr/bin/env bash
# test/floor-one-copy.test.sh — ONE COPY: the 6 safety-floor scripts and every
# pipeline agent contract exist in exactly ONE tracked path,
# plugins/quetrex-factory/{scripts,agents}/, and nowhere else.
#
# Run: bash test/floor-one-copy.test.sh
#
# WHY. Before this task the floor lived in .claude/hooks/ (this repo) AND
# plugins/quetrex-factory/scripts/ (the quetrex-plugins marketplace repo,
# published independently) — two copies that drifted (verify-gate.sh: 722
# lines here vs 683 lines published; the 39-line delta was a fix that had
# NEVER shipped). This test pins the fix MECHANICALLY: it walks `git ls-files`
# (never `find`, so an UNTRACKED stray copy is never a false red, and a
# TRACKED stray copy is always caught) and asserts every floor basename and
# every agent basename appears exactly once, at exactly the one path this
# repo now publishes verbatim (by git-subdir) to quetrex-plugins.
#
# AMENDMENT (orchestrator decision, 2026-08-25): agents get ONE copy too —
# `git mv .claude/agents/*.md plugins/quetrex-factory/agents/`, not a
# duplicate. There is therefore no second `.claude/agents/` copy to compare
# byte-for-byte (superseding the plan's original AC11 cmp-pair assertion);
# instead this file asserts the SAME one-tracked-copy property for agents
# that it asserts for floor scripts.
#
# FAIL-FIRST (AC2): to prove this test goes red against the pre-move tree,
# check out a worktree at this branch's merge-base, drop THIS file into its
# test/ directory unchanged, and run it there:
#   git worktree add /tmp/qx-premove <merge-base-sha>
#   git show HEAD:test/floor-one-copy.test.sh > /tmp/qx-premove/test/floor-one-copy.test.sh
#   bash /tmp/qx-premove/test/floor-one-copy.test.sh
# Pre-change: every floor basename and agent basename is tracked under
# .claude/{hooks,agents}/ instead, so every "expected under
# plugins/quetrex-factory/..." assertion below prints NOT OK (>=1 line
# naming .claude/hooks/verify-gate.sh) and the run exits 1. Post-change:
# every assertion passes (>=6 "ok - " lines for the floor scripts alone) and
# the run exits 0.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

FLOOR_BASENAMES="deny-guard.sh secret-scan.sh enforce-branch.sh merge-gate.sh verify-gate.sh verify-gate-quick-chain.sh"
AGENT_BASENAMES="architect.md database-architect.md developer.md git-workflow.md qa.md quetrex-cleanup-auditor.md quetrex-cleanup-proposer.md reviewer.md security-reviewer.md"

check_one_copy() {  # check_one_copy <basename> <required-dir-prefix> <kind-label>
  local b="$1" want_dir="$2" kind="$3" hits n
  hits="$(git ls-files | grep -E "(^|/)${b//./\\.}\$" || true)"
  if [ -z "$hits" ]; then
    notok "$kind '$b' is not tracked anywhere (expected exactly 1, under $want_dir)"
    return
  fi
  n="$(printf '%s\n' "$hits" | grep -c .)"
  if [ "$n" -ne 1 ]; then
    notok "$kind '$b' is tracked $n times (expected exactly 1): $(printf '%s' "$hits" | tr '\n' ' ')"
    return
  fi
  if printf '%s' "$hits" | grep -q "^${want_dir}${b}\$"; then
    ok "$kind '$b' is tracked in exactly 1 place, under $want_dir"
  else
    notok "$kind '$b' is tracked exactly once but NOT under $want_dir (found: $hits)"
  fi
}

# --- AC1 (floor scripts): exactly one tracked copy each, under scripts/ ----
for b in $FLOOR_BASENAMES; do
  check_one_copy "$b" "plugins/quetrex-factory/scripts/" "floor script"
done

# --- AC1: verify-gate.sh's move is a real `git mv`, not copy+delete -------
FOLLOW_COUNT="$(git log --follow --format=%H -- plugins/quetrex-factory/scripts/verify-gate.sh 2>/dev/null | wc -l | tr -d ' ')"
case "$FOLLOW_COUNT" in
  ''|0|1)
    notok "AC1: git log --follow for plugins/quetrex-factory/scripts/verify-gate.sh shows only ${FOLLOW_COUNT:-0} commit(s) — expected >=2, which would prove a real \`git mv\` (not copy+delete)"
    ;;
  *)
    ok "AC1: git log --follow shows $FOLLOW_COUNT commit(s) for verify-gate.sh — rename history preserved"
    ;;
esac

# --- AMENDMENT: every pipeline agent contract, exactly one copy, under
# plugins/quetrex-factory/agents/ (supersedes the plan's original AC11
# byte-for-byte duplicate-pair assertion — there is no second copy anymore) -
for b in $AGENT_BASENAMES; do
  check_one_copy "$b" "plugins/quetrex-factory/agents/" "agent contract"
done

# --- no residual .claude/agents/ or .claude/hooks/<floor> tracked files ----
if git ls-files | grep -q '^\.claude/agents/'; then
  notok "AMENDMENT: .claude/agents/ still has tracked file(s) — every agent contract must live ONLY under plugins/quetrex-factory/agents/ ($(git ls-files | grep '^\.claude/agents/' | tr '\n' ' '))"
else
  ok "AMENDMENT: .claude/agents/ has 0 tracked files left"
fi

RESIDUAL_HOOKS=""
for b in $FLOOR_BASENAMES; do
  hit="$(git ls-files | grep -E "^\.claude/hooks/${b//./\\.}\$" || true)"
  [ -n "$hit" ] && RESIDUAL_HOOKS="$RESIDUAL_HOOKS $b"
done
if [ -n "$RESIDUAL_HOOKS" ]; then
  notok ".claude/hooks/ still tracks floor script(s) that should have moved:$RESIDUAL_HOOKS"
else
  ok ".claude/hooks/ tracks 0 of the 6 floor scripts"
fi

# --- AC21 (cross-repo, OPTIONAL): the sibling quetrex-plugins checkout
# carries NO floor scripts of its own. SKIPs with a stated reason (never
# silently passes) when no sibling checkout is reachable — see the
# run-all.sh VACUOUS/SKIP rule.
SIBLING="${QX_SIBLING_PLUGINS_REPO:-$ROOT/../quetrex-plugins}"
if git -C "$SIBLING" rev-parse --show-toplevel >/dev/null 2>&1; then
  found=""
  for b in $FLOOR_BASENAMES; do
    hit="$(git -C "$SIBLING" ls-files 2>/dev/null | grep -E "(^|/)${b//./\\.}\$" || true)"
    [ -n "$hit" ] && found="$found $b"
  done
  if [ -n "$found" ]; then
    notok "AC21: sibling quetrex-plugins checkout ($SIBLING) still tracks floor script(s):$found"
  else
    ok "AC21: sibling quetrex-plugins checkout ($SIBLING) tracks 0 of the 6 floor scripts"
  fi
else
  echo "SKIP: AC21 cross-repo assertion not run — no sibling quetrex-plugins git checkout reachable at $SIBLING (set QX_SIBLING_PLUGINS_REPO to point at one)"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "floor-one-copy.test.sh: all checks passed"
else
  echo "floor-one-copy.test.sh: FAILURES above"
fi
exit "$FAIL"
