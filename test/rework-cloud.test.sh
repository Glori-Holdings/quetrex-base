#!/usr/bin/env bash
# test/rework-cloud.test.sh — /quetrex:task-rework re-dispatches the build to a
# CLOUD ROUTINE and its gate evidence comes home, EXECUTED.
#
# Run: bash test/rework-cloud.test.sh
#      QX_TASK_REWORK_MD=/path/to/other/task-rework.md bash test/rework-cloud.test.sh
#
# WHY THIS FILE EXISTS. `/quetrex:task-rework` is the documented recovery path
# for a failed unit — and it was the last command that still ran the build on
# the operator's laptop ("the heavy work runs in a background Workflow-tool
# run", "Dispatch the workflow in the background"). Two consequences, both
# measured against the shipped files rather than argued:
#
#   D1. It violated the locked decision that compute runs only on Anthropic's
#       servers: approving a rework from a phone started nothing, and closing
#       the lid stranded it.
#   D2. Whatever it produced could not be merged. `merge-gate.sh` demands an
#       AUTO_MERGE verdict pinned to the PR head plus a green ledger for that
#       same commit, and `/quetrex:merge` §2 reads BOTH out of the
#       `<prefix><TASK>-gates` BRANCH — overwriting (or rm -f'ing) whatever the
#       operator's own .quetrex/ happens to hold. A locally re-run gate is
#       therefore invisible: ASSERTION 6 below executes merge.md's own fetch
#       block and watches fresh local evidence get replaced by the failed run's
#       stale evidence. Only the cloud routine's step 5b republishes that
#       branch.
#
# So the rework dispatch is now task-build.md Step 6A verbatim, and the four
# resolutions it needs (target/base branch, plan recovery, base-sha pin,
# payload) are shell functions inside marked `quetrex:exec-block`s in
# task-rework.md. THIS FILE EXTRACTS THOSE BLOCKS AND RUNS THEM — same bytes
# the model is told to run, no restatement — against real git fixtures, the
# REAL `quetrex-cloud-prep sync`, and the REAL gate snippets sliced out of
# task-build.md and merge.md.
#
# ASSERTION MAP
#   0  the four exec-blocks extract, define their function, and parse
#   1  the dispatch is a cloud routine, not a local run   (text-anchored)
#   2  qx_rework_target: standalone -> main, child -> the epic integration
#      branch, epic parent refused, and a UUID parentTaskId is NEVER turned
#      into a branch name
#   3  qx_rework_plan_source: payload / epic-payload children[] / gates branch /
#      spec branch, and a refusal when no source carries a usable plan
#   4  qx_rework_base_sha: the sha it picks SYNCS — proven by running the real
#      quetrex-cloud-prep sync, with the naive choice as the negative control
#   5  qx_rework_payload: accepted by task-build.md's own Step 5 and Step 6A
#      snippets, carries the agreed fix where the pipeline reads it, and is
#      idempotent across repeated reworks
#   6  locally produced gate evidence does not survive /quetrex:merge — the
#      reason there is no local-gate fast path

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMAND="${QX_TASK_REWORK_MD:-$REPO_ROOT/.claude/commands/task-rework.md}"
TASK_BUILD="$REPO_ROOT/.claude/commands/task-build.md"
MERGE_MD="$REPO_ROOT/.claude/commands/merge.md"
CLOUD_PREP="$REPO_ROOT/bin/quetrex-cloud-prep"
export PATH="$REPO_ROOT/bin:$PATH"

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

for f in "$COMMAND" "$TASK_BUILD" "$MERGE_MD"; do
  if [ ! -f "$f" ]; then
    echo "NOT OK - rework-cloud.test.sh: file not found: $f"
    echo
    echo "rework-cloud.test.sh: FAILURES above"
    exit 1
  fi
done
if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node is not installed — every block under test is node-backed"
  exit 0
fi
if ! command -v git >/dev/null 2>&1; then
  echo "SKIP: git is not installed — plan recovery and the base pin are driven against real repos"
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qx-rework-cloud.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

GIT_ID=(-c user.name=qx-test -c user.email=qx@test.invalid -c commit.gpgsign=false)

# ==========================================================================
# Extraction helpers — by ANCHOR, never by line number.
# ==========================================================================
extract_block() {   # extract_block <name> [file] > stdout
  awk -v name="$1" '
    $0 ~ ("quetrex:exec-block " name "([^A-Za-z0-9_]|$)") && $0 !~ ("end quetrex:exec-block") { inb=1 }
    inb { print }
    $0 ~ ("end quetrex:exec-block " name "([^A-Za-z0-9_]|$)") { inb=0 }
  ' "${2:-$COMMAND}"
}

# slice <file> <start-substring> <exact-end-line> > stdout
# Fixed strings, never regexes: every anchor below is real shell full of [, $,
# | and " — a regex anchor would either need unreadable escaping or silently
# match nothing, and "silently matched nothing" is how a cross-file assertion
# goes vacuous (ASSERTION 5's negative control is what caught exactly that).
slice() {
  awk -v s="$2" -v e="$3" '
    index($0, s) > 0 && !inb && !done { inb=1 }
    inb { print }
    inb && $0 == e { inb=0; done=1 }
  ' "$1"
}

# slice_fence <file> <start-substring> > stdout
# The ```-fenced block containing the first line matching <start-substring>,
# from that line up to (but not including) the closing fence.
#
# WHY THIS EXISTS. ASSERTION 6 used `slice "$MERGE_MD" ... 'fi'` — bounded by a
# GUARD LINE. The moment merge.md's §2 grew a second `if` above its transport
# (the local-evidence precedence check), the slice stopped at that guard's `fi`
# and the fetch under test never ran at all: the assertion inverted, reporting
# that /quetrex:merge had "kept the locally produced verdict" when in fact it
# had never been executed. That is precisely the truncation
# test/shipped-blocks-shell-portable.test.sh documents at the top of its own
# extractor — a fence is the block's real boundary, a repeated guard line is
# not.
slice_fence() {
  awk -v s="$2" '
    index($0, s) > 0 && !inb && !done { inb=1 }
    inb && /^```/ { inb=0; done=1; next }
    inb { print }
  ' "$1"
}

# ==========================================================================
# ASSERTION 0 — the blocks are executable, and they are what they claim
# ==========================================================================
BLOCKS="qx_rework_target qx_rework_plan_source qx_rework_base_sha qx_rework_payload"
EXTRACTED_ALL=1
for b in $BLOCKS; do
  extract_block "$b" > "$WORK/$b.sh"
  if [ ! -s "$WORK/$b.sh" ]; then
    fail "0: task-rework.md has no executable block '$b' (anchor: '# ── quetrex:exec-block $b') — the re-dispatch is prose again, and this file could only check prose"
    EXTRACTED_ALL=0
    continue
  fi
  if ! grep -q "^[[:space:]]*$b()" "$WORK/$b.sh"; then
    fail "0: the '$b' block does not define a function named $b — extraction found the wrong text"
    EXTRACTED_ALL=0
    continue
  fi
  if ERR="$(bash -n "$WORK/$b.sh" 2>&1)"; then
    pass "0: extracted '$b' from task-rework.md ($(wc -l < "$WORK/$b.sh" | tr -d ' ') lines) and it parses"
  else
    fail "0: the '$b' block in task-rework.md is not valid shell: $ERR"
    EXTRACTED_ALL=0
  fi
done

if [ -n "$(extract_block qx_no_such_block_exists)" ]; then
  fail "0: the block extractor returned text for a block that does not exist — every extraction assertion is meaningless"
else
  pass "0: negative control — the extractor returns nothing for an absent block name"
fi

# ==========================================================================
# ASSERTION 1 — the dispatch is a CLOUD ROUTINE (text-anchored, and marked as
# such: a RemoteTrigger call is a tool invocation, not shell this file can run)
# ==========================================================================
need_text() {   # need_text <regex> <what>
  if grep -qE -- "$1" "$COMMAND"; then pass "1: $2"; else fail "1: $2 — no line matches /$1/"; fi
}
need_text 'RemoteTrigger'                     'the dispatch names the RemoteTrigger tool'
need_text 'cloud-build-routine\.md'           'it fires the shared self-contained routine prompt (.claude/lib/cloud-build-routine.md)'
need_text 'task-build\.md.*Step 6A|Step 6A'   'it reuses task-build.md Step 6A rather than inventing a second dispatch'
need_text 'quetrex-spec/'                     'it publishes the approved spec to the quetrex-spec/ helper branch'
need_text '\{"enabled": false\}|"enabled": false' 'the disarm (update enabled:false) is named — create+run alone arms a SECOND concurrent build'
need_text 'next_run_at'                       'the disarm is confirmed from next_run_at, not assumed'
need_text 'gates'                             'the gate evidence branch is named'
need_text '\$\{BRANCH_PREFIX\}.*-gates|<prefix><TASK>-gates|\$\{BRANCH_PREFIX\}\$\{TASK_ID\}-gates' \
                                              'the gates branch is <prefix><TASK>-gates, built from the prefix and never hardcoded'
need_text 'merge-gate\.sh'                    'it says which gate consumes that evidence'

# The three dispatch calls must appear in the create -> run -> update order.
# BYTE offsets, not line numbers: all three legitimately fit on one line.
POS_CREATE="$(grep -boF 'action:"create"' "$COMMAND" | head -1 | cut -d: -f1)"
POS_RUN="$(grep -boF 'action:"run"' "$COMMAND" | head -1 | cut -d: -f1)"
POS_UPD="$(grep -boF 'action:"update"' "$COMMAND" | head -1 | cut -d: -f1)"
if [ -n "$POS_CREATE" ] && [ -n "$POS_RUN" ] && [ -n "$POS_UPD" ] \
   && [ "$POS_CREATE" -lt "$POS_RUN" ] && [ "$POS_RUN" -lt "$POS_UPD" ]; then
  pass "1: the three dispatch calls are named in the create -> run -> update order"
else
  fail "1: task-rework.md must name action:create, then action:run, then action:update in that order (got create=$POS_CREATE run=$POS_RUN update=$POS_UPD) — create+run alone leaves run_once_at armed and fires a second concurrent build"
fi

# ...and NOTHING may still dispatch the build locally. `worktree-workflow` and
# `git-workflow` are the two legitimate compound names; any other use of the
# word is the old local Workflow-tool dispatch.
LOCALDISP="$(sed -e 's/worktree-workflow//g' -e 's/git-workflow//g' "$COMMAND" | grep -niE 'workflow' || true)"
if [ -z "$LOCALDISP" ]; then
  pass "1: no local Workflow-tool dispatch survives anywhere in task-rework.md"
else
  fail "1: task-rework.md still dispatches the build locally — $(printf '%s' "$LOCALDISP" | head -3 | tr '\n' ' ')"
fi
if grep -qE '/workflows' "$COMMAND"; then
  fail "1: task-rework.md still points the operator at /workflows — a cloud routine is watched at https://claude.ai/code/routines/{id}"
else
  pass "1: the operator is pointed at the routine monitor URL, not /workflows"
fi
if grep -qE 'claude\.ai/code/routines' "$COMMAND"; then
  pass "1: the report hands back the cloud routine monitor URL"
else
  fail "1: task-rework.md never reports https://claude.ai/code/routines/{id} — the operator has no way to watch the run it just fired"
fi

if [ "$EXTRACTED_ALL" -ne 1 ]; then
  echo
  echo "rework-cloud.test.sh: FAILURES above — could not load every block, refusing to report a partial run as green"
  exit 1
fi

# shellcheck source=/dev/null
for b in $BLOCKS; do . "$WORK/$b.sh"; done

# ==========================================================================
# ASSERTION 2 — qx_rework_target
# ==========================================================================
mk_task() {  # mk_task <json-fragment-fields...> via node argv pairs
  node -e '
    const o={}; const a=process.argv.slice(1);
    for(let i=0;i<a.length;i+=2){
      let v=a[i+1];
      if(v==="__null__") v=null;
      else if(v==="__array0__") v=[];
      else if(v==="__array2__") v=[{},{}];
      else if(/^\d+$/.test(v)) v=Number(v);
      o[a[i]]=v;
    }
    process.stdout.write(JSON.stringify(o));
  ' "$@"
}

T_SINGLE="$(mk_task identifier QDM-3 title 'a unit' parentTaskId __null__ parentIdentifier __null__ childNumber __null__)"
OUT="$(qx_rework_target "$T_SINGLE" "claude/" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qx 'BASE=main' && printf '%s\n' "$OUT" | grep -qx 'KIND=single'; then
  pass "2: a standalone task targets main"
else
  fail "2: a standalone task did not resolve to main (rc=$RC): $(printf '%s' "$OUT" | tr '\n' ' ')"
fi

# The real DTO shape: parentTaskId is the parent's UUID, parentIdentifier the human form.
UUID="9f3c8e21-4b21-4f6e-9a1c-0c7d2f5b8a10"
T_CHILD="$(mk_task identifier QDM-2.1 title 'child' parentTaskId "$UUID" parentIdentifier QDM-2 childNumber 1)"
OUT="$(qx_rework_target "$T_CHILD" "claude/" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qx 'BASE=claude/QDM-2' && printf '%s\n' "$OUT" | grep -qx 'EPIC=QDM-2'; then
  pass "2: an epic child targets the epic integration branch claude/QDM-2"
else
  fail "2: an epic child did not resolve to its integration branch (rc=$RC): $(printf '%s' "$OUT" | tr '\n' ' ')"
fi
if printf '%s\n' "$OUT" | grep -q "$UUID"; then
  fail "2: the UUID parentTaskId leaked into the branch name — that branch never existed and the child's work would never reach the integration branch"
else
  pass "2: the UUID parentTaskId is never used as a branch name"
fi
if printf '%s\n' "$OUT" | grep -qx 'BASE=main'; then
  fail "2: a child was pointed at main — child PRs target the epic integration branch, never main"
else
  pass "2: no child targets main"
fi

# parentIdentifier missing: the epic must still be derivable from CODE-N.C
T_CHILD2="$(mk_task identifier QDM-2.7 title 'child' parentTaskId "$UUID" parentIdentifier __null__ childNumber 7)"
OUT="$(qx_rework_target "$T_CHILD2" "claude/" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qx 'BASE=claude/QDM-2'; then
  pass "2: with parentIdentifier absent the epic is derived from the child's own CODE-N.C identifier"
else
  fail "2: could not derive the epic from a CODE-N.C identifier (rc=$RC): $(printf '%s' "$OUT" | tr '\n' ' ')"
fi

# Nothing on the record gives the epic: refuse loudly, never invent a branch.
T_CHILD3="$(mk_task identifier '' title 'child' parentTaskId "$UUID" parentIdentifier __null__ childNumber 3)"
OUT="$(qx_rework_target "$T_CHILD3" "claude/" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ]; then
  pass "2: a child whose epic identifier is unknowable is refused instead of branching off a UUID"
else
  fail "2: a child with only a UUID parent produced a base branch: $(printf '%s' "$OUT" | tr '\n' ' ')"
fi
case "$OUT" in *UUID*) pass "2: that refusal explains that parentTaskId is a UUID" ;;
  *) fail "2: the refusal does not say why: $(printf '%s' "$OUT" | tr '\n' ' ')" ;; esac

# Epic PARENT is not a rework target.
T_EPIC="$(mk_task identifier QDM-2 title 'epic' type project parentTaskId __null__ children __array2__)"
OUT="$(qx_rework_target "$T_EPIC" "claude/" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ]; then
  pass "2: an epic PARENT is refused — one routine for a whole epic is not a rework"
else
  fail "2: an epic parent was accepted as a rework target: $(printf '%s' "$OUT" | tr '\n' ' ')"
fi
case "$OUT" in *task-build*) pass "2: the epic-parent refusal names the way forward (/quetrex:task-build on the epic)" ;;
  *) fail "2: the epic-parent refusal names no way forward: $(printf '%s' "$OUT" | tr '\n' ' ')" ;; esac

# The prefix is data. A non-default prefix must be honoured everywhere.
OUT="$(qx_rework_target "$T_CHILD" "qx/" 2>&1)"
if printf '%s\n' "$OUT" | grep -qx 'BASE=qx/QDM-2'; then
  pass "2: a non-default branch prefix is honoured (qx/QDM-2)"
else
  fail "2: the branch prefix is hardcoded — with prefix qx/ the base came back as: $(printf '%s' "$OUT" | tr '\n' ' ')"
fi

# ==========================================================================
# Shared git fixture: a bare origin, a work clone, a base that MOVES, and a
# unit branch left behind by a failed build.
# ==========================================================================
ORIGIN="$WORK/origin.git"
WORKC="$WORK/work"
git init -q --bare -b main "$ORIGIN"
git init -q -b main "$WORKC"
( cd "$WORKC" && git remote add origin "$ORIGIN" ) >/dev/null
echo "base" > "$WORKC/README.md"
git -C "$WORKC" add -A >/dev/null
git -C "$WORKC" "${GIT_ID[@]}" commit -q -m "c1"
git -C "$WORKC" push -q origin main
C1="$(git -C "$WORKC" rev-parse HEAD)"

UNIT_BRANCH="claude/QDM-2.1-fix"
git -C "$WORKC" checkout -q -b "$UNIT_BRANCH"
echo "work in progress" > "$WORKC/unit.txt"
git -C "$WORKC" add -A >/dev/null
git -C "$WORKC" "${GIT_ID[@]}" commit -q -m "u1"
git -C "$WORKC" push -q origin "$UNIT_BRANCH"
U1="$(git -C "$WORKC" rev-parse HEAD)"

git -C "$WORKC" checkout -q main
echo "someone else merged" > "$WORKC/other.txt"
git -C "$WORKC" add -A >/dev/null
git -C "$WORKC" "${GIT_ID[@]}" commit -q -m "c2"
git -C "$WORKC" push -q origin main
C2="$(git -C "$WORKC" rev-parse HEAD)"

# A plan with a non-empty ownership map, published on two disposable branches.
mk_plan() {  # mk_plan <file> <ownership:1|0> [summary]
  node -e '
    const fs=require("fs"); const [f,own,sum]=process.argv.slice(1);
    fs.writeFileSync(f, JSON.stringify({
      task:"QDM-2.1", route:"COMPLEX", base_sha:null,
      summary: sum || "add the widget endpoint",
      ownership: own==="1" ? {"src/api/widget.ts":"api"} : {},
      acceptance:[{id:"AC1",workstream:"api",given:"g",when:"w",then:"t",measure:"m"}],
      security_surface:[], verify:["npm test"], required_env:[],
      security_review_required:false, db_migration:false, notes:["pre-existing note"]
    },null,2)+"\n");
  ' "$@"
}

publish_plan_branch() {  # publish_plan_branch <branch> <ownership:1|0>
  local br="$1" own="$2" wt="$WORK/pub-$RANDOM"
  git -C "$WORKC" worktree add --detach -q "$wt" "$C1"
  mkdir -p "$wt/.quetrex/plan"
  mk_plan "$wt/.quetrex/plan/QDM-2.1.json" "$own"
  git -C "$wt" checkout -q -B "$br"
  git -C "$wt" add -f ".quetrex/plan/QDM-2.1.json" >/dev/null
  git -C "$wt" "${GIT_ID[@]}" commit -q -m "chore(spec): $br"
  git -C "$wt" push -q origin "$br"
  git -C "$WORKC" worktree remove "$wt" --force >/dev/null 2>&1
}

# ==========================================================================
# ASSERTION 3 — qx_rework_plan_source
# ==========================================================================
PROBE="$WORK/probe"
git clone -q "$ORIGIN" "$PROBE"
git -C "$PROBE" config user.name qx-test
git -C "$PROBE" config user.email qx@test.invalid

OUTF="$WORK/recovered.json"

# 3a. nothing anywhere -> refuse
rm -f "$OUTF"
OUT="$(qx_rework_plan_source "$PROBE" QDM-2.1 QDM-2 "claude/" "$OUTF" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && [ ! -s "$OUTF" ]; then
  pass "3: with no payload and no published branch the plan recovery refuses (and writes nothing)"
else
  fail "3: plan recovery invented a plan from nowhere (rc=$RC): $(printf '%s' "$OUT" | tr '\n' ' ')"
fi
case "$OUT" in *task-build*) pass "3: the refusal points at /quetrex:task-build to re-plan" ;;
  *) fail "3: the refusal names no way forward: $(printf '%s' "$OUT" | tr '\n' ' ')" ;; esac

# 3b. the spec branch alone
publish_plan_branch "quetrex-spec/QDM-2.1" 1
rm -f "$OUTF"
OUT="$(qx_rework_plan_source "$PROBE" QDM-2.1 QDM-2 "claude/" "$OUTF" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -q 'PLAN_SOURCE=branch:quetrex-spec/QDM-2.1'; then
  pass "3: the plan is recovered from the spec branch when nothing local has it"
else
  fail "3: spec-branch recovery failed (rc=$RC): $(printf '%s' "$OUT" | tr '\n' ' ')"
fi

# 3c. the gates branch outranks the spec branch (it is the newer evidence)
publish_plan_branch "claude/QDM-2.1-gates" 1
rm -f "$OUTF"
OUT="$(qx_rework_plan_source "$PROBE" QDM-2.1 QDM-2 "claude/" "$OUTF" 2>&1)"
if printf '%s\n' "$OUT" | grep -q 'PLAN_SOURCE=branch:claude/QDM-2.1-gates'; then
  pass "3: the published gate evidence is preferred over the spec branch"
else
  fail "3: the gates branch was not preferred: $(printf '%s' "$OUT" | tr '\n' ' ')"
fi

# 3d. an epic child has NO payload of its own — its plan lives in the epic's children[]
mkdir -p "$PROBE/.quetrex/build"
node -e '
  const fs=require("fs");
  const plan={ownership:{"src/api/widget.ts":"api"},summary:"from the epic payload",
              acceptance:[],notes:[],verify:[]};
  fs.writeFileSync(process.argv[1], JSON.stringify({
    task:"QDM-2", kind:"epic", branchPrefix:"claude/", baseBranch:"main",
    integrationBranch:"claude/QDM-2", scopeApprovedAt:"2026-08-10T00:00:00.000Z",
    children:[{label:"C1",title:"first",desc:"d",id:"QDM-2.1",plan}], edges:[], edgeIds:[]
  },null,2)+"\n");
' "$PROBE/.quetrex/build/QDM-2.json"
rm -f "$OUTF"
OUT="$(qx_rework_plan_source "$PROBE" QDM-2.1 QDM-2 "claude/" "$OUTF" 2>&1)"
if printf '%s\n' "$OUT" | grep -q 'PLAN_SOURCE=epic-payload:'; then
  pass "3: an epic child's plan is recovered from the EPIC payload's children[] (children never get a payload of their own)"
else
  fail "3: the epic payload's children[] was not consulted — an epic child could never be reworked: $(printf '%s' "$OUT" | tr '\n' ' ')"
fi

# 3e. the task's own payload outranks everything
node -e '
  const fs=require("fs");
  const plan={ownership:{"src/api/widget.ts":"api"},summary:"from the unit payload",
              acceptance:[],notes:[],verify:[]};
  fs.writeFileSync(process.argv[1], JSON.stringify({
    task:"QDM-2.1", kind:"single", branchPrefix:"claude/", baseBranch:"claude/QDM-2",
    planSnapshot:plan, scopeApprovedAt:"2026-08-10T00:00:00.000Z", approvedBaseSha:null
  },null,2)+"\n");
' "$PROBE/.quetrex/build/QDM-2.1.json"
rm -f "$OUTF"
OUT="$(qx_rework_plan_source "$PROBE" QDM-2.1 QDM-2 "claude/" "$OUTF" 2>&1)"
if printf '%s\n' "$OUT" | grep -q 'PLAN_SOURCE=payload:'; then
  pass "3: the unit's own build payload is the first source consulted"
else
  fail "3: the unit payload was not preferred: $(printf '%s' "$OUT" | tr '\n' ' ')"
fi
if [ -s "$OUTF" ] && node -e '
    const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    process.exit(p.ownership && Object.keys(p.ownership).length ? 0 : 1);
  ' "$OUTF"; then
  pass "3: the recovered plan carries a non-empty ownership map"
else
  fail "3: the recovered plan has no ownership map — the cloud routine would abort as transport_failure"
fi

# 3f. a plan with an EMPTY ownership map is not a usable plan (negative control:
#     without this, 3e would pass on any JSON at all)
node -e '
  const fs=require("fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({
    task:"QDM-9", kind:"single", planSnapshot:{ownership:{},summary:"empty"}
  },null,2)+"\n");
' "$PROBE/.quetrex/build/QDM-9.json"
rm -f "$OUTF"
OUT="$(qx_rework_plan_source "$PROBE" QDM-9 - "claude/" "$OUTF" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ]; then
  pass "3: a plan with an empty ownership map is rejected here instead of burning a cloud run to learn it"
else
  fail "3: an ownership-less plan was accepted: $(printf '%s' "$OUT" | tr '\n' ' ')"
fi

# ==========================================================================
# ASSERTION 4 — qx_rework_base_sha, judged by the REAL quetrex-cloud-prep sync
# ==========================================================================
if [ ! -x "$CLOUD_PREP" ]; then
  fail "4: bin/quetrex-cloud-prep is missing or not executable — the base pin cannot be judged by the tool that consumes it"
else
  SYNC_A="$WORK/sync-a"; git clone -q "$ORIGIN" "$SYNC_A"
  git -C "$SYNC_A" config user.name qx-test; git -C "$SYNC_A" config user.email qx@test.invalid
  # NEGATIVE CONTROL / the defect: pin the LIVE tip of origin/main. sync must
  # refuse, because the failed unit branch cannot contain a commit made after it.
  OUT="$("$CLOUD_PREP" sync main "$C2" "$UNIT_BRANCH" --repo "$SYNC_A" 2>&1)"; RC=$?
  if [ "$RC" -ne 0 ]; then
    pass "4: negative control — pinning the live base tip makes the real cloud-prep sync fail (rc=$RC), which is the re-dispatch dead end"
  else
    fail "4: cloud-prep sync accepted the live base tip against an older unit branch — the negative control is dead and assertion 4 proves nothing"
  fi

  PICK="$(qx_rework_base_sha "$PROBE" main "$UNIT_BRANCH" - 2>&1)"; RC=$?
  if [ "$RC" -eq 0 ] && [ "$PICK" = "$C1" ]; then
    pass "4: with no previously pinned sha the merge-base of the failed branch and the base is chosen"
  else
    fail "4: expected the merge-base $C1, got '$PICK' (rc=$RC)"
  fi
  SYNC_B="$WORK/sync-b"; git clone -q "$ORIGIN" "$SYNC_B"
  git -C "$SYNC_B" config user.name qx-test; git -C "$SYNC_B" config user.email qx@test.invalid
  OUT="$("$CLOUD_PREP" sync main "$PICK" "$UNIT_BRANCH" --repo "$SYNC_B" 2>&1)"; RC=$?
  if [ "$RC" -eq 0 ]; then
    pass "4: the sha qx_rework_base_sha picked SYNCS against the real quetrex-cloud-prep (rc=0)"
  else
    fail "4: the picked sha does not sync (rc=$RC): $(printf '%s' "$OUT" | tr '\n' ' ')"
  fi
  case "$OUT" in *resum*) pass "4: sync RESUMED the failed unit branch — the existing PR is updated, not duplicated" ;;
    *) fail "4: sync did not resume the existing unit branch: $(printf '%s' "$OUT" | tr '\n' ' ')" ;; esac

  # A previously pinned sha that still satisfies both ancestry questions is reused.
  PICK2="$(qx_rework_base_sha "$PROBE" main "$UNIT_BRANCH" "$C1" 2>&1)"
  if [ "$PICK2" = "$C1" ]; then
    pass "4: a still-valid pinned base sha is reused, never re-resolved"
  else
    fail "4: a valid pinned sha was discarded: got '$PICK2'"
  fi
  # A pinned sha the unit branch cannot contain must NOT be handed back.
  PICK3="$(qx_rework_base_sha "$PROBE" main "$UNIT_BRANCH" "$C2" 2>&1)"
  if [ "$PICK3" = "$C1" ]; then
    pass "4: a pinned sha the failed branch cannot contain is replaced by the merge-base instead of dead-ending the run"
  else
    fail "4: a poisoned pin was handed straight back: got '$PICK3' (wanted the merge-base $C1)"
  fi
  # No unit branch at all -> the live base tip is right.
  PICK4="$(qx_rework_base_sha "$PROBE" main - - 2>&1)"
  if [ "$PICK4" = "$C2" ]; then
    pass "4: with no unit branch to resume, the live base tip is pinned"
  else
    fail "4: with no unit branch the pin should be the live tip $C2, got '$PICK4'"
  fi
fi

# ==========================================================================
# ASSERTION 5 — qx_rework_payload, judged by task-build.md's OWN snippets
# ==========================================================================
slice "$TASK_BUILD" '|| { echo "No build payload' "' \"\$PAYLOAD\" || exit 1" > "$WORK/tb-step5.sh"
slice "$TASK_BUILD" 'PLAN_JSON="$(node -e' "' \"\$PAYLOAD\")\" || exit 1" > "$WORK/tb-plan.sh"
printf '\nprintf %%s "$PLAN_JSON"\n' >> "$WORK/tb-plan.sh"

if [ -s "$WORK/tb-step5.sh" ] && grep -q 'scopeApprovedAt' "$WORK/tb-step5.sh"; then
  pass "5: sliced task-build.md's Step 5 approval gate out of the shipped file"
else
  fail "5: could not slice Step 5's approval gate out of task-build.md — the cross-file contract cannot be executed"
fi
if [ -s "$WORK/tb-plan.sh" ] && grep -q 'planSnapshot' "$WORK/tb-plan.sh"; then
  pass "5: sliced task-build.md's Step 6A planSnapshot extraction out of the shipped file"
else
  fail "5: could not slice Step 6A's planSnapshot extraction out of task-build.md"
fi

PAY="$WORK/payload/QDM-2.1.json"
PLANF="$WORK/plan-in.json"; mk_plan "$PLANF" 1 "add the widget endpoint"
NOTE="$WORK/note.md"
printf 'The 404 branch returns 200.\nFix the guard in widget.ts and add a red-first test.\n' > "$NOTE"

OUT="$(qx_rework_payload "$PAY" "QDM-2.1" "Widget endpoint" "claude/QDM-2" "claude/" "$PLANF" "$NOTE" "$C1" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && [ -s "$PAY" ]; then
  pass "5: the rework payload is written"
else
  fail "5: qx_rework_payload failed (rc=$RC): $(printf '%s' "$OUT" | tr '\n' ' ')"
fi

# task-build.md's own Step 5 gate must accept it — that is the contract.
if ( export TASK_ID="QDM-2.1" PAYLOAD="$PAY"; bash "$WORK/tb-step5.sh" >/dev/null 2>&1 ); then
  pass "5: task-build.md's Step 5 approval gate ACCEPTS the rework payload (the build half can be entered)"
else
  fail "5: task-build.md's Step 5 gate refused the rework payload — the re-dispatch cannot start"
fi
# ...and it must still refuse an unapproved one (negative control on the gate itself).
node -e '
  const fs=require("fs"); const [i,o]=process.argv.slice(1);
  const p=JSON.parse(fs.readFileSync(i,"utf8")); p.scopeApprovedAt=null;
  fs.writeFileSync(o, JSON.stringify(p,null,2)+"\n");
' "$PAY" "$WORK/unapproved.json"
if ( export TASK_ID="QDM-2.1" PAYLOAD="$WORK/unapproved.json"; bash "$WORK/tb-step5.sh" >/dev/null 2>&1 ); then
  fail "5: the Step 5 gate accepted a payload with no scopeApprovedAt — it is not gating anything and the assertion above is vacuous"
else
  pass "5: negative control — the Step 5 gate still refuses an unapproved payload"
fi

# Step 6A's own extraction must find a plan in it.
PLAN_OUT="$( export PAYLOAD="$PAY"; bash "$WORK/tb-plan.sh" 2>/dev/null )"
if printf '%s' "$PLAN_OUT" | node -e '
    let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
      let p; try{p=JSON.parse(s)}catch(e){process.exit(1)}
      process.exit(p.ownership && Object.keys(p.ownership).length ? 0 : 1);
    });' ; then
  pass "5: task-build.md Step 6A extracts a plan with a non-empty ownership map from the rework payload"
else
  fail "5: Step 6A could not extract a usable plan from the rework payload — the spec branch would ship empty"
fi

check_payload() {  # check_payload <expr-name> <node-expression>
  if node -e '
      const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
      const plan=p.planSnapshot||{};
      process.exit(eval(process.argv[2]) ? 0 : 1);
    ' "$PAY" "$2"; then pass "5: $1"; else fail "5: $1 — FAILED ($2)"; fi
}
check_payload 'kind is single (a rework rebuilds one unit)'                 'p.kind==="single"'
check_payload 'baseBranch is the epic integration branch, never main'       'p.baseBranch==="claude/QDM-2"'
check_payload 'branchPrefix is carried through'                             'p.branchPrefix==="claude/"'
check_payload 'scopeApprovedAt is stamped (the Step 2 dialog is the gate)'  '!!p.scopeApprovedAt'
check_payload 'the stamp records that task-rework approved it'              'p.scopeApprovedBy==="task-rework"'
check_payload 'approvedBaseSha is the pinned sha, not re-resolved'          'p.approvedBaseSha==="'"$C1"'"'
check_payload 'dispatch is cleared so a stale record cannot read as in-flight' 'p.dispatch===null'
check_payload 'the agreed fix is machine-readable at plan.rework'           'plan.rework && plan.rework.iteration===1 && /Fix the guard/.test(plan.rework.note)'
check_payload 'the agreed fix reaches notes[0], which every stage already reads' '/^REWORK #1 /.test(String(plan.notes[0])) && /Fix the guard/.test(String(plan.notes[0]))'
check_payload 'the pre-existing note is kept'                              'plan.notes.some(n=>/pre-existing note/.test(String(n)))'
check_payload 'summary is flagged as a rework and keeps the original text'  '/^REWORK #1 — add the widget endpoint$/.test(String(plan.summary))'
check_payload 'the approved ownership map is untouched'                    'JSON.stringify(plan.ownership)===JSON.stringify({"src/api/widget.ts":"api"})'
check_payload 'the acceptance criteria are untouched'                      'Array.isArray(plan.acceptance) && plan.acceptance.length===1 && plan.acceptance[0].id==="AC1"'

# A rework with no agreed note is refused — Step 2 cannot be skipped.
: > "$WORK/empty-note.md"
OUT="$(qx_rework_payload "$WORK/p2.json" "QDM-2.1" "t" "main" "claude/" "$PLANF" "$WORK/empty-note.md" - 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && [ ! -s "$WORK/p2.json" ]; then
  pass "5: an empty rework note is refused — a re-run with no agreed fix just reproduces the failure"
else
  fail "5: a rework with no agreed fix was dispatched (rc=$RC): $(printf '%s' "$OUT" | tr '\n' ' ')"
fi

# A plan with no ownership map is refused before the routine is fired.
mk_plan "$WORK/plan-empty.json" 0
OUT="$(qx_rework_payload "$WORK/p3.json" "QDM-2.1" "t" "main" "claude/" "$WORK/plan-empty.json" "$NOTE" - 2>&1)"; RC=$?
if [ "$RC" -ne 0 ]; then
  pass "5: a plan with no ownership map is refused before a routine is fired"
else
  fail "5: an ownership-less plan was dispatched: $(printf '%s' "$OUT" | tr '\n' ' ')"
fi

# IDEMPOTENCE: rework the same task twice. Iteration advances; the markers do
# not stack.
node -e '
  const fs=require("fs"); const [i,o]=process.argv.slice(1);
  const p=JSON.parse(fs.readFileSync(i,"utf8"));
  fs.writeFileSync(o, JSON.stringify(p.planSnapshot,null,2)+"\n");
' "$PAY" "$WORK/plan-round2.json"
printf 'Second pass: the guard still leaks on HEAD requests.\n' > "$WORK/note2.md"
qx_rework_payload "$PAY" "QDM-2.1" "Widget endpoint" "claude/QDM-2" "claude/" \
  "$WORK/plan-round2.json" "$WORK/note2.md" "$C1" >/dev/null 2>&1
check_payload 'a second rework advances to iteration 2'                    'plan.rework.iteration===2'
check_payload 'the summary is not double-prefixed'                         '/^REWORK #2 — add the widget endpoint$/.test(String(plan.summary))'
check_payload 'exactly one REWORK note is carried, superseded not stacked'  'plan.notes.filter(n=>/^REWORK #/.test(String(n))).length===1'
check_payload 'the second note is the current one'                         '/HEAD requests/.test(String(plan.notes[0]))'
check_payload 'the pre-existing note still survives a second rework'        'plan.notes.some(n=>/pre-existing note/.test(String(n)))'

# ==========================================================================
# ASSERTION 6 — WHY there is no local-gate fast path FOR A REWORK: when a gates
# BRANCH exists, /quetrex:merge overwrites bare locally produced evidence with
# whatever that branch carries.
#
# SCOPE, since §2 now has a local route too: that route is entered only when §1
# DISCOVERED a local evidence set and pinned it to the PR head (it sets
# LOCAL_EVIDENCE_DIR). Loose artifacts left in .quetrex/ by a local gate re-run
# — which is what this fixture writes, and what the "just re-run the gates
# locally" shortcut would produce — authorize nothing, and a published gates
# branch still wins. That is why task-rework re-dispatches to cloud rather than
# re-gating in place. test/merge-local-evidence.test.sh owns the local route.
# ==========================================================================
slice_fence "$MERGE_MD" 'rev-parse --show-toplevel)/.quetrex/merge-facts.env' > "$WORK/merge-fetch.sh"
if [ -s "$WORK/merge-fetch.sh" ] && grep -q 'GATES_BRANCH' "$WORK/merge-fetch.sh"; then
  pass "6: sliced /quetrex:merge's gate-evidence fetch out of the shipped merge.md"
else
  fail "6: could not slice merge.md's evidence fetch — assertion 6 cannot be executed"
fi

MREPO="$WORK/merge-repo"
git clone -q "$ORIGIN" "$MREPO"
git -C "$MREPO" config user.name qx-test; git -C "$MREPO" config user.email qx@test.invalid

# The gates branch as the FAILED cloud run left it: REWORK, pinned to the old sha.
GWT="$WORK/gates-wt"
git -C "$MREPO" worktree add --detach -q "$GWT" "$C1"
mkdir -p "$GWT/.quetrex/plan"
printf '%s\n' "$C1" > "$GWT/.quetrex/gates-head"
printf '{"verdict":"REWORK","sha":"%s"}\n' "$C1" > "$GWT/.quetrex/review-verdict.json"
printf '{"cmd":"npm test","exit":1}\n' > "$GWT/.quetrex/verify-ledger.jsonl"
printf '{"task":"QDM-7.1"}\n' > "$GWT/.quetrex/state.json"
mk_plan "$GWT/.quetrex/plan/QDM-7.1.json" 1
git -C "$GWT" checkout -q -B "claude/QDM-7.1-gates"
git -C "$GWT" add -f .quetrex/gates-head .quetrex/review-verdict.json .quetrex/verify-ledger.jsonl \
  .quetrex/state.json .quetrex/plan/QDM-7.1.json >/dev/null
git -C "$GWT" "${GIT_ID[@]}" commit -q -m "chore(gates): stale"
git -C "$GWT" push -q origin "claude/QDM-7.1-gates"
git -C "$MREPO" worktree remove "$GWT" --force >/dev/null 2>&1
# ...and the operator's laptop holding a FRESH, green, correctly pinned gate set
# — exactly what a local gate re-run would produce.
mkdir -p "$MREPO/.quetrex/plan"
printf '%s\n' "$U1" > "$MREPO/.quetrex/gates-head"
printf '{"verdict":"AUTO_MERGE","sha":"%s"}\n' "$U1" > "$MREPO/.quetrex/review-verdict.json"
printf '{"cmd":"npm test","exit":0}\n' > "$MREPO/.quetrex/verify-ledger.jsonl"
{
  printf 'TASK=%q\n' "QDM-7.1"
  printf 'REPO_ROOT=%q\n' "$MREPO"
  printf 'GATES_BRANCH=%q\n' "claude/QDM-7.1-gates"
} > "$MREPO/.quetrex/merge-facts.env"

( cd "$MREPO" && bash "$WORK/merge-fetch.sh" ) >/dev/null 2>&1

if grep -q 'AUTO_MERGE' "$MREPO/.quetrex/review-verdict.json" 2>/dev/null; then
  fail "6: /quetrex:merge kept the locally produced verdict — if that held, the local-gate path would be viable and this assertion no longer explains why task-rework dispatches to cloud"
else
  pass "6: /quetrex:merge REPLACED the locally produced AUTO_MERGE verdict with the gates branch's stale REWORK — locally re-run gates are invisible to the merge gate"
fi
GH="$(tr -d '[:space:]' < "$MREPO/.quetrex/gates-head" 2>/dev/null || echo "")"
if [ "$GH" = "$C1" ]; then
  pass "6: gates-head came back pinned to the FAILED run's commit, so the merge is refused as STALE EVIDENCE"
else
  fail "6: expected gates-head to be the stale $C1 after the fetch, got '$GH'"
fi

echo
if [ "$FAIL" -ne 0 ]; then
  echo "rework-cloud.test.sh: FAILURES above"
  exit 1
fi
echo "rework-cloud.test.sh: all assertions passed"
