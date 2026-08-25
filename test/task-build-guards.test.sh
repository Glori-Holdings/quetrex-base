#!/usr/bin/env bash
# test/task-build-guards.test.sh — the dispatch guards in
# .claude/commands/task-build.md, EXECUTED.
#
# Run: bash test/task-build-guards.test.sh
#      QX_TASK_BUILD_MD=/path/to/other/task-build.md bash test/task-build-guards.test.sh
#
# WHY THIS FILE EXISTS. task-build.md is model-instructions, so for years its
# guards were prose that nobody ever ran, and an adversarial audit found five
# separate holes in exactly the places prose cannot be checked:
#
#   1. WEDGE. The plan half marks the task `in_progress` before the human taps
#      Approve. Decline the gate (or lose the session) and Step 1 answered
#      "its pipeline is already running" forever — for a task where nothing was
#      running at all. `/quetrex:task-build <TASK>`, the command the product is
#      built around, became permanently unusable for that task.
#   2. RE-FIRE. `--build-only` skipped Step 1 entirely ("skip straight to
#      Step 5"), and Step 5's only gate is the payload's `scopeApprovedAt`.
#      Nothing ever deletes that payload, so a merged or deployed task could be
#      re-dispatched from a stale approval: a second PR for landed work, or two
#      runs racing on one spec branch / unit branch / gates branch, after which
#      /quetrex:merge reports STALE EVIDENCE for a PR that was built correctly.
#   3. FOREIGN ENVIRONMENT. `environment_id` was the bare literal
#      env_011CUpkAEM4fzsAD6dx1zW3r — one account's environment, hardcoded, and
#      neither /quetrex:login nor /quetrex:init nor /quetrex:doctor provisions or
#      checks one. For anybody else the dispatch went nowhere, silently.
#   4. RE-DISPATCH DEAD END. The base sha was re-resolved from origin/<base> on
#      EVERY dispatch. `quetrex-cloud-prep sync` resumes the existing unit branch
#      and asserts the approved base is an ancestor of it — so once main moved,
#      the re-stamped sha could not be contained by the branch and sync exited 3
#      `transport_failure`, permanently. That dead end sat under merge.md's own
#      stale-gates advice ("re-run --build-only").
#   5. EPIC NEVER REACHED THE CLOUD. Children were dispatched as local
#      Workflow-tool runs driven by a /loop — i.e. the biggest unit of work the
#      product supports required the operator's laptop to stay open, which is the
#      workflow Quetrex replaces.
#
# So the guards are no longer prose. Each one is a shell function inside a
# marked `quetrex:exec-block` in task-build.md, and THIS FILE EXTRACTS THOSE
# BLOCKS AND RUNS THEM — same bytes the model is told to run, no restatement.
# Assertions that cannot be executed (a whole section's dispatch shape) are
# anchored on text, and are marked as such.
#
# Nothing here touches the network or the kanban: every function under test is a
# pure function of files + git, by construction.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMAND="${QX_TASK_BUILD_MD:-$REPO_ROOT/.claude/commands/task-build.md}"
export PATH="$REPO_ROOT/bin:$PATH"

if [ ! -f "$COMMAND" ]; then
  echo "NOT OK - task-build-guards.test.sh: command file not found: $COMMAND"
  echo
  echo "task-build-guards.test.sh: FAILURES above"
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node is not installed — every guard in task-build.md is node-backed"
  exit 0
fi
if ! command -v git >/dev/null 2>&1; then
  echo "SKIP: git is not installed — the approved-base guard is driven against a real repo"
  exit 0
fi

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qx-task-build-guards.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --------------------------------------------------------------------------
# Extraction — by ANCHOR, never by line number.
# --------------------------------------------------------------------------
extract_block() {   # extract_block <name> > file
  awk -v name="$1" '
    $0 ~ ("quetrex:exec-block " name "([^A-Za-z0-9_]|$)") && $0 !~ ("end quetrex:exec-block") { inb=1 }
    inb { print }
    $0 ~ ("end quetrex:exec-block " name "([^A-Za-z0-9_]|$)") { inb=0 }
  ' "$COMMAND"
}

BLOCKS="qx_cloud_env_id qx_actionability qx_approved_base_sha qx_child_dispatch_params"
EXTRACTED_ALL=1
for b in $BLOCKS; do
  extract_block "$b" > "$WORK/$b.sh"
  if [ ! -s "$WORK/$b.sh" ]; then
    fail "task-build.md has no executable block '$b' (anchor: '# ── quetrex:exec-block $b') — the guard is prose again, and this file can only check prose"
    EXTRACTED_ALL=0
    continue
  fi
  if ! grep -q "^[[:space:]]*$b()" "$WORK/$b.sh"; then
    fail "the '$b' block does not define a function named $b — extraction found the wrong text"
    EXTRACTED_ALL=0
    continue
  fi
  if ERR="$(bash -n "$WORK/$b.sh" 2>&1)"; then
    pass "extracted executable block '$b' from task-build.md ($(wc -l < "$WORK/$b.sh" | tr -d ' ') lines) and it parses"
  else
    fail "the '$b' block in task-build.md is not valid shell: $ERR"
    EXTRACTED_ALL=0
  fi
done

if [ "$EXTRACTED_ALL" -ne 1 ]; then
  echo
  echo "task-build-guards.test.sh: FAILURES above — could not load every guard, refusing to report a partial run as green"
  exit 1
fi

# Negative control on the extractor itself: a name that does not exist must come
# back empty. Without this, a broken awk that emits the WHOLE file would make
# every "block found" assertion above pass vacuously.
if [ -n "$(extract_block qx_no_such_block_exists)" ]; then
  fail "the block extractor returned text for a block that does not exist — every extraction assertion above is meaningless"
else
  pass "negative control: the extractor returns nothing for an absent block name"
fi

# shellcheck source=/dev/null
for b in $BLOCKS; do . "$WORK/$b.sh"; done

TASK_ID="T-1"   # the guards quote it in their messages

# =============================================================================
# GUARD 1 — qx_actionability: status x kind x mode, with the payload as evidence
# =============================================================================
mk_payload() {   # mk_payload <file> <scopeApprovedAt|-> <dispatchedAt|-> [monitorUrl]
  node -e '
    const fs=require("fs");
    const [f,appr,disp,mon]=process.argv.slice(1);
    const o={task:"T-1",kind:"single",branchPrefix:"claude/",baseBranch:"main",
             scopeApprovedAt: appr==="-"?null:appr,
             dispatch: disp==="-"?null:{routineId:"rt_1",monitorUrl:mon||"https://claude.ai/code/routines/rt_1",
                                        specBranch:"quetrex-spec/T-1",baseSha:"deadbeef",dispatchedAt:disp}};
    fs.writeFileSync(f, JSON.stringify(o,null,2)+"\n");
  ' "$@"
}

P_NONE="$WORK/payload-missing.json"                       # deliberately not created
P_UNAPPROVED="$WORK/payload-unapproved.json"; mk_payload "$P_UNAPPROVED" - -
P_APPROVED="$WORK/payload-approved.json";     mk_payload "$P_APPROVED" "2026-08-10T20:56:57.837Z" -
P_INFLIGHT="$WORK/payload-inflight.json";     mk_payload "$P_INFLIGHT" "2026-08-10T20:56:57.837Z" "2026-08-10T21:00:00.000Z"

check_verdict() {  # check_verdict <label> <expect-verdict> <expect-rc> <status> <kind> <mode> <payload>
  local label="$1" want="$2" wantrc="$3"; shift 3
  local out rc verdict
  out="$(qx_actionability "$@" 2>&1)"; rc=$?
  verdict="${out%% *}"
  if [ "$verdict" = "$want" ] && [ "$rc" -eq "$wantrc" ]; then
    pass "$label → $verdict (rc=$rc)"
  else
    fail "$label → expected $want/rc=$wantrc, got ${verdict:-<empty>}/rc=$rc — full line: $out"
  fi
}

# The re-fire defect, exactly as found on disk (QDM-4: payload still approved,
# board says merged). Every one of these was a silent re-dispatch before.
check_verdict "merged + --build-only + stale approved payload"   REFUSE     1 merged    single build "$P_APPROVED"
check_verdict "deployed + --build-only"                          REFUSE     1 deployed  single build "$P_APPROVED"
check_verdict "complete + --build-only"                          REFUSE     1 complete  single build "$P_APPROVED"
check_verdict "merged + --tick"                                  REFUSE     1 merged    epic   tick  "$P_APPROVED"
check_verdict "needs_clarity + --build-only"                     REFUSE     1 needs_clarity single build "$P_APPROVED"
check_verdict "in flight (dispatch recorded) + --build-only"     REFUSE     1 in_progress single build "$P_INFLIGHT"
check_verdict "in flight (dispatch recorded) + full"             REFUSE     1 in_progress single full  "$P_INFLIGHT"

# The wedge: in_progress with nothing in flight is RESUMABLE, not "already running".
check_verdict "wedged: in_progress, payload unapproved"          RESUMABLE  0 in_progress single full  "$P_UNAPPROVED"
check_verdict "wedged: in_progress, no payload at all"           RESUMABLE  0 in_progress single full  "$P_NONE"
check_verdict "approved but dispatch never fired"                RESUMABLE  0 in_progress single build "$P_APPROVED"

# Everything that must still be allowed — a guard that refuses everything is not a guard.
check_verdict "backlog + full"                                   PROCEED    0 backlog   single full  "$P_NONE"
check_verdict "queued + full"                                    PROCEED    0 queued    single full  "$P_NONE"
check_verdict "queued + --build-only"                            PROCEED    0 queued    single build "$P_APPROVED"
check_verdict "epic in_progress + full (drain the DAG)"          RESUME     0 in_progress epic  full  "$P_APPROVED"
check_verdict "epic in_progress + --tick"                        RESUME     0 in_progress epic  tick  "$P_APPROVED"
# merge.md's documented stale-evidence repair MUST stay open, or the fix for
# defect 2 would break the recovery path defect 4 is about.
check_verdict "pr_ready + --build-only (merge.md stale-gates repair)" REDISPATCH 0 pr_ready single build "$P_APPROVED"
check_verdict "pr_ready + full (nothing to plan)"                REFUSE     1 pr_ready  single full  "$P_APPROVED"
check_verdict "status the command does not model"                REFUSE     1 wat       single full  "$P_NONE"

# The in-flight refusal has to be actionable — the operator's next move is to
# open the run, and the payload is the only place that URL exists.
INFLIGHT_MSG="$(qx_actionability in_progress single build "$P_INFLIGHT" 2>&1)"
case "$INFLIGHT_MSG" in
  *"https://claude.ai/code/routines/rt_1"*) pass "the in-flight refusal names the monitor URL from the payload" ;;
  *) fail "the in-flight refusal does not name the run's monitor URL, so the operator has nothing to look at: $INFLIGHT_MSG" ;;
esac
case "$INFLIGHT_MSG" in
  *"in flight"*) pass "the in-flight refusal says a run is in flight" ;;
  *) fail "the in-flight refusal does not say why it refused: $INFLIGHT_MSG" ;;
esac
RESUMABLE_MSG="$(qx_actionability in_progress single full "$P_UNAPPROVED" 2>&1)"
case "$RESUMABLE_MSG" in
  *"already running"*) fail "the RESUMABLE verdict still tells the operator a pipeline is 'already running' — that is the wedge message: $RESUMABLE_MSG" ;;
  *) pass "the RESUMABLE verdict does not claim a pipeline is already running" ;;
esac

# =============================================================================
# GUARD 2 — qx_cloud_env_id: the environment is data, and its absence is loud
# =============================================================================
ENVDIR="$WORK/envrepo"; mkdir -p "$ENVDIR/.quetrex"
printf '%s\n' '{"projectCode":"QUE","branchPrefix":"claude/","cloudEnvironmentId":"env_ABC123def"}' \
  > "$ENVDIR/.quetrex/project.json"
OUT="$(QUETREX_CLOUD_ENVIRONMENT_ID= qx_cloud_env_id "$ENVDIR" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "env_ABC123def" ]; then
  pass "the cloud environment id is read from the repo binding (.quetrex/project.json)"
else
  fail "binding-supplied cloudEnvironmentId not returned: rc=$RC out=$OUT"
fi

printf '%s\n' '{"projectCode":"QUE","branchPrefix":"claude/"}' > "$ENVDIR/.quetrex/project.json"
OUT="$(QUETREX_CLOUD_ENVIRONMENT_ID=env_FALLBACK9 qx_cloud_env_id "$ENVDIR" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "env_FALLBACK9" ]; then
  pass "QUETREX_CLOUD_ENVIRONMENT_ID is honoured when the binding carries no id"
else
  fail "env-var fallback for the cloud environment id does not work: rc=$RC out=$OUT"
fi

OUT="$(QUETREX_CLOUD_ENVIRONMENT_ID= qx_cloud_env_id "$ENVDIR" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ]; then
  pass "no environment bound → the guard fails instead of dispatching into someone else's account"
else
  fail "with NO environment configured the guard returned 0 ($OUT) — the dispatch would go nowhere, silently"
fi
case "$OUT" in
  *cloudEnvironmentId*env_*) pass "the missing-environment message names the field to set and the shape of the value" ;;
  *) fail "the missing-environment message is not actionable — it must name cloudEnvironmentId and the env_ id shape: $OUT" ;;
esac

OUT="$(QUETREX_CLOUD_ENVIRONMENT_ID=my-environment qx_cloud_env_id "$ENVDIR" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ]; then
  pass "a value that is not an env_… id is rejected rather than posted to the API"
else
  fail "a malformed environment id ('my-environment') was accepted: $OUT"
fi

# NO hardcoded environment id in ANY shipped file — not just this one command.
#
# WHY THIS IS A SWEEP AND NOT A SINGLE grep. The original guard checked task-build.md
# alone, and passed, while the very same literal sat in .claude/lib/cloud-build-routine.md
# (shipped in every published version) and as a live `environment_id` value in another
# repo's copy of the command. A guard scoped to one file while the string walks out the
# door in others is a green tick that measures nothing. Any file the plugin ships is in
# scope, and the pattern is the SHAPE of an environment id, not one memorised literal:
# a guard that only knows today's id cannot catch tomorrow's paste.
ENV_ID_RE='env_[0-9A-Za-z]\{20,\}'
SHIPPED_HITS=""
while IFS= read -r f; do
  case "$f" in
    "$REPO_ROOT"/test/*) continue ;;   # tests legitimately name ids in fixtures and prose
  esac
  if grep -q "$ENV_ID_RE" "$f" 2>/dev/null; then
    SHIPPED_HITS="$SHIPPED_HITS
  - $f: $(grep -o "$ENV_ID_RE" "$f" | sort -u | tr '\n' ' ')"
  fi
done <<EOF
$(find "$REPO_ROOT/.claude" "$REPO_ROOT/.claude-plugin" -type f \( -name '*.md' -o -name '*.json' -o -name '*.sh' \) 2>/dev/null)
EOF
if [ -z "$SHIPPED_HITS" ]; then
  pass "no hardcoded environment id literal in any shipped file (.claude/**, .claude-plugin/**)"
else
  fail "a hardcoded environment id ships to every operator — it belongs to one account and silently misroutes everyone else's build:$SHIPPED_HITS"
fi
if grep -q '"environment_id": "<QX_CLOUD_ENV_ID>"' "$COMMAND"; then
  pass "the RemoteTrigger body takes environment_id from the resolved \$QX_CLOUD_ENV_ID"
else
  fail "the RemoteTrigger body does not fill environment_id from \$QX_CLOUD_ENV_ID"
fi

# =============================================================================
# GUARD 3 — qx_approved_base_sha, against a REAL repo whose base branch moves
# =============================================================================
# This reproduces the measured dead end: dispatch 1 leaves a unit branch on
# origin; main advances; dispatch 2 must still resume, which is only true if the
# approved base sha is REUSED rather than re-resolved.
ORIGIN="$WORK/origin.git"
CLONE="$WORK/clone"
git init -q --bare "$ORIGIN"
git init -q "$CLONE"
git -C "$CLONE" config user.email t@example.com
git -C "$CLONE" config user.name  tester
git -C "$CLONE" checkout -q -b main
echo one > "$CLONE/a.txt"; git -C "$CLONE" add a.txt; git -C "$CLONE" commit -qm one
git -C "$CLONE" remote add origin "$ORIGIN"
git -C "$CLONE" push -q origin main
APPROVED_TRUTH="$(git -C "$CLONE" rev-parse HEAD)"

BP="$WORK/base-payload.json"
node -e '
  const fs=require("fs");
  fs.writeFileSync(process.argv[1], JSON.stringify(
    {task:"T-1",kind:"single",branchPrefix:"claude/",baseBranch:"main",
     scopeApprovedAt:"2026-08-10T20:56:57.837Z",approvedBaseSha:null},null,2)+"\n");
' "$BP"

SHA1="$(qx_approved_base_sha "$BP" "$CLONE" main)"; RC=$?
if [ "$RC" -eq 0 ] && [ "$SHA1" = "$APPROVED_TRUTH" ]; then
  pass "first dispatch resolves the base sha from origin/main"
else
  fail "first dispatch did not resolve origin/main: rc=$RC sha=$SHA1 want=$APPROVED_TRUTH"
fi
PINNED="$(node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).approvedBaseSha))' "$BP")"
if [ "$PINNED" = "$APPROVED_TRUTH" ]; then
  pass "the approved base sha is PINNED into the payload at the first dispatch"
else
  fail "the first dispatch did not persist approvedBaseSha (got '$PINNED') — a re-dispatch has nothing to reuse"
fi

# Dispatch 1's unit branch, exactly as quetrex-cloud-prep would leave it.
git -C "$CLONE" checkout -q -b claude/T-1 "$APPROVED_TRUTH"
echo work > "$CLONE/b.txt"; git -C "$CLONE" add b.txt; git -C "$CLONE" commit -qm "work"
git -C "$CLONE" push -q origin claude/T-1
UNIT_TIP="$(git -C "$CLONE" rev-parse HEAD)"

# ...and now main moves, which is the normal state of an active repo.
git -C "$CLONE" checkout -q main
echo two > "$CLONE/c.txt"; git -C "$CLONE" add c.txt; git -C "$CLONE" commit -qm two
git -C "$CLONE" push -q origin main
git -C "$CLONE" fetch -q origin main
MOVED_MAIN="$(git -C "$CLONE" rev-parse refs/remotes/origin/main)"
if [ "$MOVED_MAIN" != "$APPROVED_TRUTH" ]; then
  pass "fixture: origin/main has advanced past the approved base"
else
  fail "fixture is broken — origin/main did not move, so the re-dispatch case is not exercised"
fi

SHA2="$(qx_approved_base_sha "$BP" "$CLONE" main)"; RC=$?
if [ "$RC" -eq 0 ] && [ "$SHA2" = "$APPROVED_TRUTH" ]; then
  pass "re-dispatch REUSES the approved base sha instead of re-resolving origin/main"
else
  fail "re-dispatch returned rc=$RC sha=$SHA2 — expected the approved $APPROVED_TRUTH. Re-resolving stamps a sha the existing unit branch cannot contain, and quetrex-cloud-prep sync then exits 3 transport_failure forever"
fi
SHA3="$(qx_approved_base_sha "$BP" "$CLONE" main)"
if [ "$SHA3" = "$APPROVED_TRUTH" ]; then
  pass "a third dispatch is still pinned to the same approved base"
else
  fail "the approved base drifted on the third dispatch: $SHA3"
fi

# The ancestry assertion quetrex-cloud-prep sync actually makes.
if git -C "$CLONE" merge-base --is-ancestor "$SHA2" "$UNIT_TIP"; then
  pass "quetrex-cloud-prep's ancestry check PASSES with the reused sha (resume works)"
else
  fail "the reused base is not an ancestor of the existing unit branch — sync would exit 3 transport_failure"
fi
# Negative control: prove that check has teeth by feeding it the value the OLD
# code path produced. If this ever passes, the assertion above proves nothing.
if git -C "$CLONE" merge-base --is-ancestor "$MOVED_MAIN" "$UNIT_TIP" 2>/dev/null; then
  fail "negative control: the moved origin/main IS an ancestor of the unit branch, so the ancestry assertion above cannot distinguish the defect from the fix"
else
  pass "negative control: the OLD behaviour (re-resolve origin/main) yields a sha the unit branch cannot contain — the dead end, reproduced"
fi

# A pinned sha the repo no longer has must fail loudly, not silently re-target.
BP2="$WORK/base-payload-gone.json"
node -e '
  const fs=require("fs");
  fs.writeFileSync(process.argv[1], JSON.stringify(
    {task:"T-1",baseBranch:"main",scopeApprovedAt:"x",
     approvedBaseSha:"0123456789abcdef0123456789abcdef01234567"},null,2)+"\n");
' "$BP2"
OUT="$(qx_approved_base_sha "$BP2" "$CLONE" main 2>&1)"; RC=$?
if [ "$RC" -ne 0 ]; then
  pass "an approved base commit that no longer exists fails loudly instead of silently re-targeting"
else
  fail "a missing approved base commit was accepted: $OUT"
fi

# =============================================================================
# GUARD 4 — qx_child_dispatch_params: epic children dispatch like single units
# =============================================================================
mk_epic_payload() {  # mk_epic_payload <file> <withPlan:1|0> <withIntegration:1|0>
  node -e '
    const fs=require("fs");
    const [f,withPlan,withInt]=process.argv.slice(1);
    const plan={acceptance:[],ownership:{"dev-a":["src/a.ts"]},security_surface:[],
                security_review_required:false};
    fs.writeFileSync(f, JSON.stringify({
      task:"T-9", kind:"epic", branchPrefix:"claude/", baseBranch:"main",
      integrationBranch: withInt==="1" ? "claude/T-9" : null,
      scopeApprovedAt:"2026-08-10T00:00:00.000Z",
      children:[{label:"C1",title:"first slice",desc:"d",id:"T-9.1",
                 plan: withPlan==="1" ? plan : null}],
      edges:[], edgeIds:[], childDispatch:{}
    },null,2)+"\n");
  ' "$@"
}
EP="$WORK/epic.json"; mk_epic_payload "$EP" 1 1
OUT="$(qx_child_dispatch_params "$EP" T-9.1 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then
  pass "a child with a plan yields dispatch parameters"
else
  fail "qx_child_dispatch_params failed on a well-formed epic payload: $OUT"
fi
# CHILD_SPEC_BRANCH is deliberately NOT emitted: the spec branch is named after the sha of
# the spec commit, which does not exist yet at this point. Step 6A assigns it. Asserting a
# fixed name here would lock in the collision that forced a remote ref delete per re-dispatch.
if printf '%s' "$OUT" | grep -q 'CHILD_SPEC_BRANCH='; then
  fail "qx_child_dispatch_params still emits a fixed CHILD_SPEC_BRANCH — the spec branch must be derived from its own commit sha in Step 6A, not precomputed here"
else
  pass "no precomputed CHILD_SPEC_BRANCH — the child spec branch is derived from its commit sha"
fi
for want in "CHILD_BASE_BRANCH=claude/T-9" "CHILD_BRANCH_PREFIX=claude/"; do
  if printf '%s\n' "$OUT" | grep -qxF "$want"; then
    pass "child dispatch parameter: $want"
  else
    fail "child dispatch parameters are missing '$want' — got: $(printf '%s' "$OUT" | tr '\n' ' ')"
  fi
done
if printf '%s\n' "$OUT" | grep -qx 'CHILD_BASE_BRANCH=main'; then
  fail "a child was pointed at main — child PRs target the epic's integration branch, never main"
else
  pass "no child targets main"
fi

mk_epic_payload "$EP" 0 1
OUT="$(qx_child_dispatch_params "$EP" T-9.1 2>&1)"; RC=$?
if [ "$RC" -ne 0 ]; then
  pass "a child with no plan/ownership map is refused before it is fired (its routine would abort as transport_failure)"
else
  fail "a planless child was dispatched: $OUT"
fi
case "$OUT" in *transport_failure*) pass "the planless-child refusal names the failure it prevents" ;;
  *) fail "the planless-child refusal does not explain the consequence: $OUT" ;; esac

mk_epic_payload "$EP" 1 0
OUT="$(qx_child_dispatch_params "$EP" T-9.1 2>&1)"; RC=$?
if [ "$RC" -ne 0 ]; then
  pass "an epic payload with no integrationBranch is refused rather than defaulting to main"
else
  fail "a child was dispatched with no integration branch: $OUT"
fi

mk_epic_payload "$EP" 1 1
OUT="$(qx_child_dispatch_params "$EP" T-9.404 2>&1)"; RC=$?
if [ "$RC" -ne 0 ]; then
  pass "an unknown child id is refused"
else
  fail "an unknown child id produced dispatch parameters: $OUT"
fi

# =============================================================================
# SECTION SHAPE — the parts that are instructions, not code (text-anchored)
# =============================================================================
line_of() { grep -n -- "$1" "$COMMAND" | head -n1 | cut -d: -f1; }

# The build/tick shortcut must not jump the guard any more.
if grep -q 'skip straight to Step 5' "$COMMAND"; then
  fail "task-build.md still says '--build-only ... skip straight to Step 5' — that is the bypass that let a merged task re-fire"
else
  pass "the --build-only bypass sentence ('skip straight to Step 5') is gone"
fi
GUARD_LINE="$(line_of 'qx_actionability "$STATUS"')"
STEP5_LINE="$(line_of 'go to Step 5 now')"
if [ -n "$GUARD_LINE" ] && [ -n "$STEP5_LINE" ] && [ "$GUARD_LINE" -lt "$STEP5_LINE" ]; then
  pass "the actionability guard is invoked (line $GUARD_LINE) BEFORE build/tick mode leaves for Step 5 (line $STEP5_LINE)"
else
  fail "build/tick mode does not run the actionability guard before Step 5 (guard line='${GUARD_LINE:-none}', step5 line='${STEP5_LINE:-none}')"
fi

# The epic section must dispatch to the cloud, not to a local Workflow run.
awk '/^### B\) Epic/{inb=1} /^## Step 7/{inb=0} inb{print}' "$COMMAND" > "$WORK/step6b.md"
if [ -s "$WORK/step6b.md" ]; then
  pass "located Step 6B ($(wc -l < "$WORK/step6b.md" | tr -d ' ') lines)"
else
  fail "cannot locate Step 6B in task-build.md — the epic assertions below would pass vacuously"
fi
if grep -q 'its own named Workflow-tool run' "$WORK/step6b.md"; then
  fail "Step 6B still launches each child as a local 'named Workflow-tool run' — an epic approved from a phone would start nothing, and closing the laptop strands the DAG"
else
  pass "Step 6B no longer launches children as local Workflow-tool runs"
fi
if grep -q 'Step 6A' "$WORK/step6b.md" && grep -qi 'cloud Routine' "$WORK/step6b.md"; then
  pass "Step 6B dispatches each child as a cloud Routine, reusing the Step 6A shape"
else
  fail "Step 6B does not route children through the Step 6A cloud-Routine dispatch"
fi
if grep -q 'QX_CLOUD_ENV_ID' "$WORK/step6b.md"; then
  pass "Step 6B fires children into the resolved cloud environment"
else
  fail "Step 6B does not name \$QX_CLOUD_ENV_ID — a child dispatch with no environment is the hardcoded-id defect again"
fi
if grep -q 'childDispatch' "$WORK/step6b.md"; then
  pass "Step 6B records each child's dispatch, so an in-flight child cannot be re-fired"
else
  fail "Step 6B records nothing about a fired child — the per-child in-flight refusal has no evidence to read"
fi

# The payload has to carry the two fields every guard above depends on.
if grep -q 'approvedBaseSha' "$COMMAND" && grep -q 'dispatch: null' "$COMMAND"; then
  pass "the Step 4a payload declares approvedBaseSha and dispatch"
else
  fail "the Step 4a payload does not declare approvedBaseSha/dispatch — the guards would read fields nothing ever writes"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "task-build-guards.test.sh: all checks passed"
  exit 0
else
  echo "task-build-guards.test.sh: FAILURES above"
  exit 1
fi
