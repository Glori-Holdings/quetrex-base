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
  call_probe() {  # call_probe <task> <prefix> [expected-head-sha]
    cp "$WORK/probe.sh" "$WORK/probe-call.sh"
    printf '\nqx_probe_gate_refusal %q %q %q\n' "$1" "$2" "${3:-}" >> "$WORK/probe-call.sh"
    ( cd "$CLONE" && bash "$WORK/probe-call.sh" )
  }

  # Like push_gates_branch but also writes .quetrex/gates-head — needed for the
  # SEC-2 (head-sha-pinned selection) assertions below.
  push_gates_branch_with_head() {  # push_gates_branch_with_head <branch> <state.json content> <gates-head>
    local branch="$1" content="$2" ghead="$3"
    git -C "$CLONE" checkout -q -b "$branch" trunk
    mkdir -p "$CLONE/.quetrex"
    printf '%s' "$content" > "$CLONE/.quetrex/state.json"
    printf '%s\n' "$ghead" > "$CLONE/.quetrex/gates-head"
    git -C "$CLONE" add -f .quetrex/state.json .quetrex/gates-head
    git -C "$CLONE" commit -q -m "chore(gates): $branch"
    git -C "$CLONE" push -q origin "$branch"
    git -C "$CLONE" checkout -q trunk
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

  # =============================================================================
  # PART 4 (SEC-2, review finding on the first version of qx_probe_gate_refusal):
  # `ls-remote | sort | tail -n1` let ANY branch matching the glob win by naming itself
  # to sort last — MEASURED: a crafted decoy branch beat the real run's branch. The fix
  # requires exactly one candidate (safe with no anchor) OR an exact gates-head match
  # (safe with an anchor); two-or-more with no anchor now refuses to guess.
  # =============================================================================
  TASK4="QDM-9"
  REAL_GHEAD="1111111111111111111111111111111111111111"
  DECOY_GHEAD="2222222222222222222222222222222222222222"
  # The decoy's branch NAME is engineered to sort lexicographically LAST — the exact
  # property the old `sort | tail -n1` selection trusted.
  push_gates_branch_with_head "${PREFIX}${TASK4}-gates-1111111" \
    '{"task":"QDM-9","git_workflow":"refused","git_workflow_reason":"the REAL refusal"}' "$REAL_GHEAD"
  push_gates_branch_with_head "${PREFIX}${TASK4}-gates-zzzzzzz" \
    '{"task":"QDM-9","git_workflow":"refused","git_workflow_reason":"a DECOY branch forged by anyone with push access"}' "$DECOY_GHEAD"

  # No expected sha to anchor on, and now TWO candidates exist -> must refuse to guess.
  OUT="$(call_probe "$TASK4" "$PREFIX")"
  RC=$?
  if [ "$RC" -ne 0 ] && ! printf '%s' "$OUT" | grep -q '^GATE_REFUSED'; then
    ok "PART 4 (SEC-2): two candidate gates branches with no expected head sha -> refuses to guess (NONE), never silently picks the lexicographically-last one"
  else
    notok "PART 4 (SEC-2): with two candidates and no anchor, the probe still picked one (rc=$RC): $OUT — the lexicographic-sort defect is not fixed"
  fi

  # With the REAL gates-head as the expected sha, the REAL branch must be selected —
  # never the decoy, even though the decoy's name sorts after it.
  OUT="$(call_probe "$TASK4" "$PREFIX" "$REAL_GHEAD")"
  RC=$?
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'the REAL refusal' && ! printf '%s' "$OUT" | grep -q 'DECOY'; then
    ok "PART 4 (SEC-2): given the real gates-head as an anchor, the REAL branch is selected — the decoy (which sorts last) is never chosen"
  else
    notok "PART 4 (SEC-2): given the real gates-head, the wrong branch was selected or none was (rc=$RC): $OUT"
  fi

  # =============================================================================
  # PART 5 (SEC-3, review finding): a truthy NON-STRING git_workflow_reason (e.g. a
  # hostile or malformed state.json) must not throw inside the node snippet and turn
  # into a silent NONE (which the caller would misread as "not a refusal" and
  # RECOVERABLE re-fire an already-refused build).
  # =============================================================================
  TASK5="QDM-10"
  push_gates_branch "${PREFIX}${TASK5}-gates-badreason" \
    '{"task":"QDM-10","git_workflow":"refused","git_workflow_reason":{"gate":"NSR","detail":"nested object, not a string"}}'
  OUT="$(call_probe "$TASK5" "$PREFIX")"
  RC=$?
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^GATE_REFUSED ' && printf '%s' "$OUT" | grep -q 'NSR'; then
    ok "PART 5 (SEC-3): a non-string git_workflow_reason (object) does not crash the probe — it is coerced and reported as GATE_REFUSED, never silently NONE"
  else
    notok "PART 5 (SEC-3): a non-string git_workflow_reason produced (rc=$RC): $OUT — expected a coerced GATE_REFUSED, not a silent NONE/crash"
  fi

  # --- O9 (reviewer, cosmetic): git_workflow_reason: null must read as MISSING, the
  #     same "no reason recorded" default an absent/empty reason gets — not the
  #     literal string "null" (JSON.stringify(null) is a truthy non-empty string,
  #     which slipped past the SEC-3 coercion's `if (!r)` guard). The refusal is
  #     still correctly DETECTED either way; only the reason text was wrong. -------
  TASK5B="QDM-10b"
  push_gates_branch "${PREFIX}${TASK5B}-gates-nullreason" \
    '{"task":"QDM-10b","git_workflow":"refused","git_workflow_reason":null}'
  OUT="$(call_probe "$TASK5B" "$PREFIX")"
  RC=$?
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^GATE_REFUSED .*no reason recorded' && ! printf '%s' "$OUT" | grep -qE ': null$|: null '; then
    ok "PART 5 (O9): git_workflow_reason:null reads as 'no reason recorded', never the literal string 'null'"
  else
    notok "PART 5 (O9): git_workflow_reason:null did not read as 'no reason recorded' (rc=$RC): $OUT"
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

  # =============================================================================
  # PART 7 (R3, reviewer): when the needs_clarity transition itself FAILED,
  # qx_actionability must report a DIFFERENT liveness (`gate_refused_manual`) that
  # never claims the board was updated, and must tell the operator to do it by hand.
  # =============================================================================
  OUT="$(TASK_ID="QDM-6"; . "$WORK/act.sh"; qx_actionability in_progress single full "$P_GATEREFUSED" gate_refused_manual 2>&1)"; RC=$?
  if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qi 'REFUSE'; then
    ok "PART 7 (R3): qx_actionability(gate_refused_manual) reports REFUSE"
  else
    notok "PART 7 (R3): qx_actionability(gate_refused_manual) did not REFUSE as expected (rc=$RC): $OUT"
  fi
  if printf '%s' "$OUT" | grep -qi 'has been moved to needs_clarity'; then
    notok "PART 7 (R3): qx_actionability(gate_refused_manual) falsely claims the board WAS updated — the whole point of this liveness value is that the transition FAILED. Output: $OUT"
  else
    ok "PART 7 (R3): qx_actionability(gate_refused_manual) does not falsely claim the transition succeeded"
  fi
  if printf '%s' "$OUT" | grep -qi 'FAILED' && printf '%s' "$OUT" | grep -q 'needs_clarity'; then
    ok "PART 7 (R3): qx_actionability(gate_refused_manual) says the transition FAILED and names needs_clarity as what must be set manually"
  else
    notok "PART 7 (R3): qx_actionability(gate_refused_manual) does not clearly say the transition failed / what to do about it. Output: $OUT"
  fi
fi

# =============================================================================
# PART 6 (SEC-1, review finding): qx_gate_refusal_handoff must bound the reason to 800
# chars before use, and must check BOTH quetrex-api calls' exit status — on failure it
# must print the reason inline rather than silently claiming it reached the board.
#
# MEASURED (pre-fix): a multi-MiB git_workflow_reason made `quetrex-api task-status`
# succeed and `quetrex-api task-comment` die with E2BIG (argv too long), and the block
# ignored the exit code entirely — the card landed in needs_clarity with NO reason
# attached anywhere and no error surfaced to the operator.
# =============================================================================
extract_block qx_gate_refusal_handoff "$TASKBUILD" > "$WORK/handoff.sh"
extract_block qx_probe_gate_refusal "$TASKBUILD" > "$WORK/handoff-probe.sh"
if [ -s "$WORK/handoff.sh" ] && grep -q '^qx_gate_refusal_handoff()' "$WORK/handoff.sh"; then
  ok "SETUP: extracted qx_gate_refusal_handoff from task-build.md"

  # A mock quetrex-api that logs every invocation's argv lengths and can be told (via
  # env vars) to fail either subcommand — this proves the CALLER's exit-code handling,
  # not just that some call happened.
  MOCKBIN="$WORK/mockbin"
  mkdir -p "$MOCKBIN"
  cat > "$MOCKBIN/quetrex-api" <<'MOCKAPI'
#!/usr/bin/env bash
LOG="${QX_MOCK_API_LOG:?QX_MOCK_API_LOG must be set}"
sub="$1"; shift
if [ "$sub" = "task-status" ]; then
  printf 'task-status %s %s\n' "$1" "$2" >> "$LOG"
  [ "${QX_MOCK_STATUS_FAIL:-0}" = "1" ] && exit 1
  exit 0
fi
if [ "$sub" = "task-comment" ]; then
  # Record the BYTE LENGTH of the comment body arg, not its content, so a truncation
  # regression is caught mechanically rather than by eyeballing a long string.
  printf 'task-comment %s bodylen=%d\n' "$1" "${#2}" >> "$LOG"
  [ "${QX_MOCK_COMMENT_FAIL:-0}" = "1" ] && exit 1
  exit 0
fi
echo "mock quetrex-api: unhandled subcommand: $sub $*" >&2
exit 1
MOCKAPI
  chmod +x "$MOCKBIN/quetrex-api"

  # Push a fresh gates branch with a reason LONGER than 800 chars (a synthetic
  # multi-KB value stands in for the measured multi-MiB one — 800+ is all that
  # matters for the truncation assertion).
  TASK6="QDM-11"
  LONG_REASON="$(printf 'x%.0s' $(seq 1 2000))"
  push_gates_branch "${PREFIX}${TASK6}-gates-longreason" \
    "$(printf '{"task":"QDM-11","git_workflow":"refused","git_workflow_reason":"%s"}' "$LONG_REASON")"

  # run_handoff <task> <status_fail 0|1> <comment_fail 0|1>
  # Prints, on stdout: whatever qx_gate_refusal_handoff itself echoed (its WARNING
  # lines, if any), THEN a sentinel line, THEN the mock's own call log — so a single
  # capture can assert on both "what the function said" and "what it actually sent".
  run_handoff() {
    local log; log="$(mktemp "$WORK/mocklog.XXXXXX")"
    ( cd "$CLONE" \
      && PATH="$MOCKBIN:$PATH" QX_MOCK_API_LOG="$log" \
         QX_MOCK_STATUS_FAIL="$2" QX_MOCK_COMMENT_FAIL="$3" \
         bash -c "$(cat "$WORK/handoff-probe.sh")"$'\n'"$(cat "$WORK/handoff.sh")"$'\n'"qx_gate_refusal_handoff $1 $PREFIX" 2>&1 )
    echo "---MOCK-LOG---"
    cat "$log"
  }

  # --- R1/R4: the exact status transition is `needs_clarity` — the ONLY status this
  #     codebase models for "the pipeline sent this back" (task-rework.md, dev-
  #     pipeline.md's rework terminus). `needs_human` is not a status anything here
  #     writes, checks, or expects. ------------------------------------------------
  OUT="$(run_handoff "$TASK6" 0 0)"
  if printf '%s' "$OUT" | grep -q "task-status $TASK6 needs_clarity"; then
    ok "PART 6 (R1/R4): qx_gate_refusal_handoff calls quetrex-api task-status with exactly 'needs_clarity' — the modelled rework-terminus status, never 'needs_human'"
  else
    notok "PART 6 (R1/R4): expected 'task-status $TASK6 needs_clarity' in the mock's call log, got: $OUT"
  fi

  # --- both calls succeed: the comment body must be <= 800 bytes even though the
  #     underlying reason was 2000 --------------------------------------------------
  BODYLEN="$(printf '%s' "$OUT" | sed -n 's/.*bodylen=\([0-9]*\).*/\1/p' | head -n1)"
  # The comment body is the 800-char-capped reason PLUS a small fixed wrapper (the
  # "Cloud build's..."/"Gate evidence preserved on..." prose) — so the bound to check
  # is well under what an UNtruncated 2000-char reason plus that same wrapper would
  # produce (~2170), not the reason length alone.
  if [ -n "$BODYLEN" ] && [ "$BODYLEN" -gt 0 ] && [ "$BODYLEN" -le 1100 ]; then
    ok "PART 6 (SEC-1): a 2000-char git_workflow_reason is truncated before task-comment (body length $BODYLEN, well under the ~2170 an untruncated 2000-char reason plus wrapper would produce)"
  else
    notok "PART 6 (SEC-1): the comment body was not bounded — bodylen='$BODYLEN' (expected non-empty and <= ~1100). Output: $OUT"
  fi

  # --- task-status succeeds, task-comment FAILS: the failure must be surfaced with
  #     the reason printed inline, not silently swallowed ------------------------
  OUT="$(run_handoff "$TASK6" 0 1)"
  if printf '%s' "$OUT" | grep -q 'WARNING.*task-comment.*FAILED' && printf '%s' "$OUT" | grep -q 'Reason:'; then
    ok "PART 6 (SEC-1): a failing quetrex-api task-comment is surfaced as a WARNING with the reason printed inline, not silently claimed as delivered"
  else
    notok "PART 6 (SEC-1): a failing task-comment call was NOT surfaced — the exit code is still being ignored. Output: $OUT"
  fi

  # --- task-status ITSELF fails: must also be surfaced, not just task-comment's ----
  OUT="$(run_handoff "$TASK6" 1 0)"
  if printf '%s' "$OUT" | grep -q 'WARNING.*task-status.*FAILED'; then
    ok "PART 6 (SEC-1): a failing quetrex-api task-status is ALSO surfaced (not just task-comment's)"
  else
    notok "PART 6 (SEC-1): a failing task-status call was not surfaced. Output: $OUT"
  fi
else
  notok "SETUP: task-build.md has no executable qx_gate_refusal_handoff block — PART 6 cannot run"
fi

# =============================================================================
# PART 8 (R2, reviewer, high): an open (or ever-opened) PR for the unit branch must
# short-circuit qx_probe_gate_refusal entirely — a rework can leave an OLDER refused
# gates branch sitting next to a NEWER run that actually succeeded, and picking among
# gates branches (even sha-anchored) is the wrong tool once a PR exists at all.
# =============================================================================
if command -v gh >/dev/null 2>&1 && [ -s "$WORK/probe.sh" ]; then
  MOCKBIN_GH="$WORK/mockbin-gh"
  mkdir -p "$MOCKBIN_GH"
  # Distinguishes `--state open` from any other --state value, and LOGS the exact
  # invocation, so R5's "must query --state open, never --state all" claim is proven
  # mechanically rather than assumed from the count alone.
  cat > "$MOCKBIN_GH/gh" <<'MOCKGH'
#!/usr/bin/env bash
LOG="${QX_MOCK_GH_LOG:-/dev/null}"
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  echo "$*" >> "$LOG"
  state=""
  prev=""
  for a in "$@"; do
    [ "$prev" = "--state" ] && state="$a"
    prev="$a"
  done
  if [ "$state" = "open" ]; then
    printf '%s\n' "${QX_MOCK_GH_PR_COUNT_OPEN:-0}"
  else
    printf '%s\n' "${QX_MOCK_GH_PR_COUNT_OTHER:-0}"
  fi
  exit 0
fi
echo "mock gh: unhandled: $*" >&2
exit 1
MOCKGH
  chmod +x "$MOCKBIN_GH/gh"

  TASK8="QDM-12"
  # A stale REFUSED gates branch from an EARLIER, since-superseded attempt — if the
  # PR-existence check is skipped or broken, the probe would still find and report
  # this as the current state.
  push_gates_branch "${PREFIX}${TASK8}-gates-stale" \
    '{"task":"QDM-12","git_workflow":"refused","git_workflow_reason":"stale refusal from an earlier attempt, superseded by a later successful rework"}'

  call_probe_with_gh() {  # call_probe_with_gh <task> <prefix> <open-count> [other-count] [expected-sha]
    local log rc
    log="$(mktemp "$WORK/ghlog.XXXXXX")"
    cp "$WORK/probe.sh" "$WORK/probe-call-gh.sh"
    printf '\nqx_probe_gate_refusal %q %q %q\n' "$1" "$2" "${5:-}" >> "$WORK/probe-call-gh.sh"
    ( cd "$CLONE" && PATH="$MOCKBIN_GH:$PATH" QX_MOCK_GH_LOG="$log" \
        QX_MOCK_GH_PR_COUNT_OPEN="$3" QX_MOCK_GH_PR_COUNT_OTHER="${4:-0}" \
        bash "$WORK/probe-call-gh.sh" )
    rc=$?
    echo "---GHLOG---"; cat "$log"
    return "$rc"
  }

  OUT="$(call_probe_with_gh "$TASK8" "$PREFIX" 1)"
  RC=$?
  if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q '^NONE' && printf '%s' "$OUT" | grep -qi 'open PR exists'; then
    ok "PART 8 (R2): an OPEN PR exists for the unit branch -> the probe short-circuits to NONE and never even looks at the stale refused gates branch"
  else
    notok "PART 8 (R2): with an open PR, the probe should short-circuit to NONE naming it — got (rc=$RC): $OUT"
  fi
  if printf '%s' "$OUT" | grep -q -- '--state open'; then
    ok "PART 8 (R5): the gh query used is --state open (never --state all)"
  else
    notok "PART 8 (R5): the gh query did not use --state open. Log: $OUT"
  fi

  # Control: no open PR (mock reports 0) -> falls through to the normal gates-branch
  # probe, which DOES find the (only, real-for-this-test) stale refusal.
  OUT="$(call_probe_with_gh "$TASK8" "$PREFIX" 0)"
  RC=$?
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^GATE_REFUSED '; then
    ok "PART 8 (R2): with NO open PR, the probe still falls through to the normal gates-branch logic (regression guard — the short-circuit must not swallow genuine refusals)"
  else
    notok "PART 8 (R2): with no open PR, the probe should still find the gates-branch refusal normally — got (rc=$RC): $OUT"
  fi

  # =============================================================================
  # R5 (reviewer, medium — this check's OWN review finding): the first version used
  # `--state all`, so a MERGED/CLOSED PR from an earlier attempt at the same unit
  # branch name permanently masked every LATER genuine refusal. MEASURED against real
  # GitHub: `gh pr list --head claude/one-copy-perf --state all` -> 1 (merged, branch
  # long deleted), `--state open` -> 0.
  # =============================================================================
  # A PR exists but is MERGED/CLOSED (open count 0, "other"/all count 1) -> must NOT
  # short-circuit; the fresh refusal on the stale gates branch must still be found.
  OUT="$(call_probe_with_gh "$TASK8" "$PREFIX" 0 1)"
  RC=$?
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^GATE_REFUSED '; then
    ok "PART 8 (R5): a MERGED/CLOSED PR from an earlier attempt does NOT mask a fresh genuine refusal (the exact regression R5 was raised about)"
  else
    notok "PART 8 (R5): a merged/closed PR masked a fresh refusal — got (rc=$RC): $OUT"
  fi

  # With an EXPECTED_HEAD_SHA supplied, the PR check must be skipped ENTIRELY — the
  # gates-head anchor is already the stronger evidence. Prove it by having the mock
  # report an OPEN PR (which would otherwise short-circuit) while ALSO supplying an
  # anchor that resolves to the one real refusal: the anchored answer must win, and
  # the mock's log must show gh was never even invoked.
  push_gates_branch_with_head "${PREFIX}${TASK8}b-gates-anchored" \
    '{"task":"QDM-12b","git_workflow":"refused","git_workflow_reason":"anchored refusal, must be found even though gh reports an open PR"}' \
    "3333333333333333333333333333333333333333"
  OUT="$(call_probe_with_gh "${TASK8}b" "$PREFIX" 1 0 "3333333333333333333333333333333333333333")"
  RC=$?
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^GATE_REFUSED ' && printf '%s' "$OUT" | grep -q 'anchored refusal'; then
    ok "PART 8 (R5): with an EXPECTED_HEAD_SHA anchor, the PR-existence short-circuit is skipped entirely — the anchored gates-head match wins even though gh reports an open PR"
  else
    notok "PART 8 (R5): an anchored call should skip the PR check and use the gates-head match — got (rc=$RC): $OUT"
  fi
  if printf '%s' "$OUT" | grep -q '\-\-state'; then
    notok "PART 8 (R5): gh was invoked even though EXPECTED_HEAD_SHA was supplied — the PR check must be skipped entirely when anchored. Log: $OUT"
  else
    ok "PART 8 (R5): gh is never called at all when EXPECTED_HEAD_SHA is supplied"
  fi
else
  echo "SKIP: PART 8 (R2/R5) needs gh and a working probe.sh extraction"
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
