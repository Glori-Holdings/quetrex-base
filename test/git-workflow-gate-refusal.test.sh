#!/usr/bin/env bash
# test/git-workflow-gate-refusal.test.sh — a git-workflow REFUSAL must reach a human.
#
# THE MEASURED DEFECT (QDM-6, Glori-Holdings/quetrex-demo, 2026-08-26). A cloud build
# reached HEAD c26bc72 with qa PASS, review verdict AUTO_MERGE pinned to HEAD, and
# security findings PASS — and git-workflow correctly REFUSED to open a PR (see
# test/git-workflow-nsr-contract.test.sh for that half). It still published a COMPLETE
# gates branch (state.json.git_workflow="refused" is one of the five REQUIRED files in
# cloud-build-routine.md's publication step, so the refusal reason travels home). But
# nothing on the operator side ever looked at it:
#   - git-workflow.md is forbidden to touch the tracker ("You do not touch the
#     tracker/kanban").
#   - cloud-build-routine.md forbids the routine from calling the kanban API at all
#     ("Do NOT depend on cloud board-MCP").
#   - task-build.md's liveness probe treated "a ref is present on origin" as
#     dead/gone -> RECOVERABLE, which would just re-fire the identical prompt and burn
#     the attempt budget proving it refuses again, before ever surfacing the reason.
#   The card sat at in_progress forever.
#
# THE FIX has two parts, both proven here by EXECUTING the shipped bytes, never a
# paraphrase:
#   1. cloud-build-routine.md's new "GIT_WORKFLOW_REFUSED" detection (its own node
#      one-liner, extracted and run against real state.json fixtures) correctly tells a
#      git-workflow refusal apart from a normal, unrefused pipeline state.
#   2. task-build.md's new `qx_probe_gate_refusal` (extracted, executed against a real
#      gates branch pushed to a real bare remote) finds the refusal recorded there, and
#      `qx_actionability`'s new `gate_refused` liveness case reports REFUSE — never
#      RECOVERABLE — for it.
#   PART 3 is fail-first: the pre-fix contract at commit 1032770 has NEITHER the
#      detection snippet NOR the probe function at all, confirming the gap was real.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASKBUILD="$REPO_ROOT/.claude/commands/task-build.md"
ROUTINE="$REPO_ROOT/.claude/lib/cloud-build-routine.md"
PREFIX_SHA="1032770"
export PATH="$REPO_ROOT/bin:$PATH"

for f in "$TASKBUILD" "$ROUTINE"; do
  [ -f "$f" ] || { echo "FAIL: not found: $f"; exit 1; }
done
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node not installed — both snippets under test are node-backed"; exit 0; }

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gwf-gate-refusal.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# =============================================================================
# PART 1 — cloud-build-routine.md's GIT_WORKFLOW_REFUSED detection
# =============================================================================
extract_gwr_node() {  # extract_gwr_node <file>
  grep -o "node -e '[^']*process\.exit(s\.git_workflow===\"refused\"?0:1)[^']*'" "$1" | head -n1
}

NEW_SNIPPET="$(extract_gwr_node "$ROUTINE")"
if [ -n "$NEW_SNIPPET" ]; then
  ok "SETUP: extracted the current GIT_WORKFLOW_REFUSED detection from cloud-build-routine.md"
else
  notok "SETUP: could not extract the GIT_WORKFLOW_REFUSED detection — PART 1 would test a paraphrase"
fi

run_gwr_check() {  # run_gwr_check <snippet> <state.json content>
  local dir; dir="$(mktemp -d "$WORK/gwr.XXXXXX")"
  mkdir -p "$dir/.quetrex"
  printf '%s' "$2" > "$dir/.quetrex/state.json"
  ( cd "$dir" && eval "$1" ) >/dev/null 2>&1
}

if [ -n "$NEW_SNIPPET" ]; then
  if run_gwr_check "$NEW_SNIPPET" '{"git_workflow":"refused","git_workflow_reason":"nativeSecurityReview errored, no independent artifact"}'; then
    ok "PART 1: detects a real git_workflow=refused state.json"
  else
    notok "PART 1: failed to detect a real git_workflow=refused state.json"
  fi
  if run_gwr_check "$NEW_SNIPPET" '{"stage":"reviewer"}'; then
    notok "PART 1: falsely fired on a state.json with no git_workflow field at all"
  else
    ok "PART 1: does not fire on a state.json with no git_workflow field"
  fi
  if run_gwr_check "$NEW_SNIPPET" 'not json at all {{{'; then
    notok "PART 1: falsely fired on malformed state.json"
  else
    ok "PART 1: fails closed (does not fire) on malformed state.json"
  fi
fi

# --- FAIL-FIRST: the pre-fix routine has no such detection at all -----------
OLD_ROUTINE_CONTENT="$(git -C "$REPO_ROOT" show "${PREFIX_SHA}:.claude/lib/cloud-build-routine.md" 2>/dev/null)"
if [ -z "$OLD_ROUTINE_CONTENT" ]; then
  notok "FAIL-FIRST SETUP: could not read cloud-build-routine.md at $PREFIX_SHA"
elif printf '%s' "$OLD_ROUTINE_CONTENT" | grep -q "GIT_WORKFLOW_REFUSED"; then
  notok "FAIL-FIRST: the pre-fix ($PREFIX_SHA) routine ALREADY had a GIT_WORKFLOW_REFUSED check — the fail-first baseline is not actually pre-fix"
else
  ok "FAIL-FIRST: pre-fix ($PREFIX_SHA) routine has NO GIT_WORKFLOW_REFUSED detection at all — confirms a git-workflow refusal was published and then ignored"
fi

# =============================================================================
# PART 2 — task-build.md's qx_probe_gate_refusal + qx_actionability(gate_refused)
# =============================================================================
extract_block() {   # extract_block <name> <file>
  awk -v name="$1" '
    $0 ~ ("quetrex:exec-block " name "([^A-Za-z0-9_]|$)") && $0 !~ ("end quetrex:exec-block") { inb=1 }
    inb { print }
    $0 ~ ("end quetrex:exec-block " name "([^A-Za-z0-9_]|$)") { inb=0 }
  ' "$2"
}

extract_block qx_probe_gate_refusal "$TASKBUILD" > "$WORK/probe.sh"
extract_block qx_actionability "$TASKBUILD" > "$WORK/act.sh"

if [ -s "$WORK/probe.sh" ] && grep -q '^qx_probe_gate_refusal()' "$WORK/probe.sh"; then
  ok "SETUP: extracted qx_probe_gate_refusal from task-build.md"
else
  notok "SETUP: task-build.md has no executable qx_probe_gate_refusal block — PART 2 cannot run"
fi
if [ -s "$WORK/act.sh" ] && grep -q '^qx_actionability()' "$WORK/act.sh"; then
  ok "SETUP: extracted qx_actionability from task-build.md"
else
  notok "SETUP: could not extract qx_actionability — PART 2's gate_refused assertion cannot run"
fi

if [ -s "$WORK/probe.sh" ]; then
  # --- fixture: a bare remote, a clone, and a pushed gates branch -----------
  # NOTE: the fixture's default branch is deliberately named "trunk", never
  # "main"/"master" — this repo's own merge-gate.sh PreToolUse hook fires on
  # ANY `git push` whose OWN target argument is master/main, regardless of
  # which repo `-C`/`cwd` actually points at (it resolves $ROOT from
  # $CLAUDE_PROJECT_DIR, not from the command's own -C flag), and would deny
  # this fixture's push against THIS repo's real, unrelated gate state.
  BARE="$WORK/origin.git"
  CLONE="$WORK/clone"
  git init -q --bare "$BARE"
  git init -q -b trunk "$CLONE"
  git -C "$CLONE" config user.email "test@example.com"
  git -C "$CLONE" config user.name "Fixture"
  echo "fixture" > "$CLONE/README.md"
  git -C "$CLONE" add README.md
  git -C "$CLONE" commit -q -m "chore: fixture commit"
  git -C "$CLONE" remote add origin "$BARE"
  git -C "$CLONE" push -q origin trunk

  push_gates_branch() {  # push_gates_branch <branch> <state.json content>
    local branch="$1" content="$2"
    git -C "$CLONE" checkout -q -b "$branch" trunk
    mkdir -p "$CLONE/.quetrex"
    printf '%s' "$content" > "$CLONE/.quetrex/state.json"
    git -C "$CLONE" add -f .quetrex/state.json
    git -C "$CLONE" commit -q -m "chore(gates): $branch"
    git -C "$CLONE" push -q origin "$branch"
    git -C "$CLONE" checkout -q trunk
  }

  # Call the extracted function via a FILE, on its own line, never via
  # `bash -c "$(cat f); call"` — command substitution strips the trailing
  # newline off the file's content, so a call glued onto that string lands on
  # the SAME line as the block's closing `# ── end quetrex:exec-block ── ...`
  # comment and silently never runs (measured: rc=0, no output at all, not
  # even the NONE branch — the entire call was swallowed into the comment).
  call_probe() {  # call_probe <task> <prefix>
    cp "$WORK/probe.sh" "$WORK/probe-call.sh"
    printf '\nqx_probe_gate_refusal %q %q\n' "$1" "$2" >> "$WORK/probe-call.sh"
    ( cd "$CLONE" && bash "$WORK/probe-call.sh" )
  }

  TASK="QDM-6"
  PREFIX="claude/"
  push_gates_branch "${PREFIX}${TASK}-gates-c26bc72" \
    '{"task":"QDM-6","git_workflow":"refused","git_workflow_reason":"nativeSecurityReview=errored, no independent security-findings.json"}'

  OUT="$(call_probe "$TASK" "$PREFIX")"
  RC=$?
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^GATE_REFUSED ' && printf '%s' "$OUT" | grep -q 'nativeSecurityReview=errored'; then
    ok "PART 2: qx_probe_gate_refusal finds a real refusal recorded on the gates branch and returns the reason"
  else
    notok "PART 2: qx_probe_gate_refusal did not detect the recorded refusal (rc=$RC): $OUT"
  fi

  # --- control: a gates branch with NO recorded refusal (ordinary state) ----
  TASK2="QDM-7"
  push_gates_branch "${PREFIX}${TASK2}-gates-abc1234" '{"task":"QDM-7","stage":"git-workflow"}'
  OUT="$(call_probe "$TASK2" "$PREFIX")"
  RC=$?
  if [ "$RC" -ne 0 ] && ! printf '%s' "$OUT" | grep -q '^GATE_REFUSED'; then
    ok "PART 2: a gates branch with NO recorded refusal is correctly left as NONE (not mistaken for a refusal)"
  else
    notok "PART 2: a NORMAL gates branch was falsely reported as a refusal (rc=$RC): $OUT"
  fi

  # --- control: no gates branch published at all -----------------------------
  TASK3="QDM-8"
  OUT="$(call_probe "$TASK3" "$PREFIX")"
  RC=$?
  if [ "$RC" -ne 0 ] && ! printf '%s' "$OUT" | grep -q '^GATE_REFUSED'; then
    ok "PART 2: no gates branch at all -> correctly NONE (falls through to ordinary dead/gone handling)"
  else
    notok "PART 2: a task with NO gates branch was falsely reported as a refusal (rc=$RC): $OUT"
  fi
fi

if [ -s "$WORK/act.sh" ]; then
  # A payload with BOTH scopeApprovedAt and dispatch.dispatchedAt set — the
  # precondition qx_actionability requires before it even looks at $liveness
  # (`if [ -n "$approved" ] && [ -n "$dispatched" ]`). Same shape as
  # test/task-build-guards.test.sh's mk_payload.
  P_GATEREFUSED="$WORK/payload-gate-refused.json"
  node -e '
    const fs=require("fs");
    fs.writeFileSync(process.argv[1], JSON.stringify({
      task:"QDM-6",kind:"single",branchPrefix:"claude/",baseBranch:"main",
      scopeApprovedAt:"2026-08-26T00:00:00.000Z",
      dispatch:{routineId:"rt_qdm6",monitorUrl:"https://claude.ai/code/routines/rt_qdm6",
                specBranch:"quetrex-spec/QDM-6",baseSha:"deadbeef",dispatchedAt:"2026-08-26T00:05:00.000Z"}
    }, null, 2) + "\n");
  ' "$P_GATEREFUSED"

  OUT="$(TASK_ID="QDM-6"; . "$WORK/act.sh"; qx_actionability in_progress single full "$P_GATEREFUSED" gate_refused 2>&1)"; RC=$?
  if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qi 'REFUSE'; then
    ok "PART 2: qx_actionability(gate_refused) reports REFUSE (rc=$RC), never RECOVERABLE"
  else
    notok "PART 2: qx_actionability(gate_refused) did not REFUSE as expected (rc=$RC): $OUT"
  fi
  if printf '%s' "$OUT" | grep -qi 'RECOVERABLE'; then
    notok "PART 2: qx_actionability(gate_refused) said RECOVERABLE — this would re-fire an identical, already-refused build"
  else
    ok "PART 2: qx_actionability(gate_refused) never says RECOVERABLE"
  fi
fi

# --- FAIL-FIRST: the pre-fix task-build.md has no qx_probe_gate_refusal or gate_refused
OLD_TASKBUILD_CONTENT="$(git -C "$REPO_ROOT" show "${PREFIX_SHA}:.claude/commands/task-build.md" 2>/dev/null)"
if [ -z "$OLD_TASKBUILD_CONTENT" ]; then
  notok "FAIL-FIRST SETUP: could not read task-build.md at $PREFIX_SHA"
else
  if printf '%s' "$OLD_TASKBUILD_CONTENT" | grep -q "qx_probe_gate_refusal\|gate_refused"; then
    notok "FAIL-FIRST: the pre-fix ($PREFIX_SHA) task-build.md ALREADY had gate-refusal handling — the fail-first baseline is not actually pre-fix"
  else
    ok "FAIL-FIRST: pre-fix ($PREFIX_SHA) task-build.md has NEITHER qx_probe_gate_refusal NOR a gate_refused liveness case — a published git-workflow refusal was indistinguishable from a crashed container, and RECOVERABLE would re-fire it"
  fi
fi

echo
echo "git-workflow-gate-refusal.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
