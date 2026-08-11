#!/usr/bin/env bash
# test/epic-tick.test.sh — the epic dispatch tick in
# .claude/commands/task-build.md, EXECUTED against fixture DAGs.
#
# Run: bash test/epic-tick.test.sh
#      QX_TASK_BUILD_MD=/path/to/other/task-build.md bash test/epic-tick.test.sh
#
# WHY THIS FILE EXISTS — two defects, both of which made an epic (the largest
# unit of work the product supports) impossible to finish.
#
#   GAP 1. THE TICK COUNTED A STATUS NOTHING WRITES. Launch headroom was
#      `cap − (children whose card reads in_progress)` and the exit condition was
#      "no child in_progress AND the ready set is empty". Nothing in the system
#      ever writes `in_progress` on a CHILD: dev-pipeline.md's writer is
#      forbidden to a cloud routine (cloud-build-routine.md: "Do NOT depend on
#      cloud board-MCP") and task-build.md's own write is on the EPIC. So
#      in-flight was identically 0 — the very first tick after wave one fired saw
#      "0 in-flight, 0 ready" (the dependents are blocked until their parents are
#      `merged`), printed EPIC FIXPOINT REACHED, stopped its own /loop and fell
#      into Step 7, which reported every still-building child as failed. Wave two
#      was never dispatched. The cap was inert for the same reason.
#      ASSERTION GROUP B below reproduces that exact board state and proves the
#      legacy rule declares a fixpoint on it while the shipped planner does not.
#
#   GAP 2. A DEAD ROUTINE WEDGED THE TASK FOREVER. `in_progress` + any
#      `dispatch.dispatchedAt` was an unconditional REFUSE in all three modes,
#      with no age bound, no liveness test, and nothing anywhere clearing the
#      record. One killed container took the task out of the product; the only
#      escape was hand-editing a git-ignored JSON file. The fix is NOT a clock —
#      age alone re-firing a build would duplicate a legitimately long run, and
#      two sessions racing one branch namespace is a corrupt build. Age obliges a
#      PROBE (`RemoteTrigger action:"get"` on `dispatch.routineId`); only a probed
#      dead/gone routine is recoverable, and only while attempts remain.
#      ASSERTION GROUPS E and F prove both halves: proven-dead recovers, and
#      neither the clock alone nor an exhausted attempt count ever re-fires.
#
# Nothing here touches the network or the kanban. Every function under test is a
# pure function of files plus an injectable clock, by construction — the board
# snapshot the tick reads is a file, so the whole dispatcher is testable offline.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMAND="${QX_TASK_BUILD_MD:-$REPO_ROOT/.claude/commands/task-build.md}"
export PATH="$REPO_ROOT/bin:$PATH"

if [ ! -f "$COMMAND" ]; then
  echo "NOT OK - epic-tick.test.sh: command file not found: $COMMAND"
  echo
  echo "epic-tick.test.sh: FAILURES above"
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node is not installed — every guard in task-build.md is node-backed"
  exit 0
fi

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qx-epic-tick.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Extraction — by ANCHOR, never by line number (same contract as
# test/task-build-guards.test.sh: the model is told to run these bytes, so the
# test runs the same bytes).
# ---------------------------------------------------------------------------
extract_block() {   # extract_block <name>
  awk -v name="$1" '
    $0 ~ ("quetrex:exec-block " name "([^A-Za-z0-9_]|$)") && $0 !~ ("end quetrex:exec-block") { inb=1 }
    inb { print }
    $0 ~ ("end quetrex:exec-block " name "([^A-Za-z0-9_]|$)") { inb=0 }
  ' "$COMMAND"
}

BLOCKS="qx_epic_tick_plan qx_actionability qx_record_dispatch qx_clear_dead_dispatch qx_record_child_dispatch"
EXTRACTED_ALL=1
for b in $BLOCKS; do
  extract_block "$b" > "$WORK/$b.sh"
  if [ ! -s "$WORK/$b.sh" ]; then
    fail "task-build.md has no executable block '$b' (anchor: '# ── quetrex:exec-block $b') — the tick is prose again, and prose is what shipped a fixpoint test keyed on a status nothing writes"
    EXTRACTED_ALL=0
    continue
  fi
  if ! grep -q "^[[:space:]]*$b()" "$WORK/$b.sh"; then
    fail "the '$b' block does not define a function named $b — extraction found the wrong text"
    EXTRACTED_ALL=0
    continue
  fi
  if ERR="$(bash -n "$WORK/$b.sh" 2>&1)"; then
    pass "extracted executable block '$b' ($(wc -l < "$WORK/$b.sh" | tr -d ' ') lines) and it parses"
  else
    fail "the '$b' block in task-build.md is not valid shell: $ERR"
    EXTRACTED_ALL=0
  fi
done

if [ "$EXTRACTED_ALL" -ne 1 ]; then
  echo
  echo "epic-tick.test.sh: FAILURES above — could not load the tick, refusing to report a partial run as green"
  exit 1
fi

# Negative control on the extractor: a name that does not exist must come back
# empty, or every "block found" assertion above is vacuous.
if [ -n "$(extract_block qx_no_such_block_exists)" ]; then
  fail "the block extractor returned text for a block that does not exist — every extraction assertion above is meaningless"
else
  pass "extractor negative control: an unknown block name yields nothing"
fi

# shellcheck source=/dev/null
for b in $BLOCKS; do . "$WORK/$b.sh"; done

TASK_ID="E-1"   # qx_actionability quotes it in its messages

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
NOW="2026-08-11T12:00:00.000Z"
ago_iso() {   # ago_iso <minutes>
  node -e 'process.stdout.write(new Date(Date.parse(process.argv[1])-Number(process.argv[2])*60000).toISOString())' "$NOW" "$1"
}

# mk_epic <file> <children-csv> <edges-json> <cap>
#   children-csv: "E-1.1,E-1.2,E-1.3"   edges-json: [["E-1.3","E-1.1"],...]
mk_epic() {
  node -e '
    const fs=require("fs");
    const [f,csv,edges,cap]=process.argv.slice(1);
    const ids=csv.split(",").filter(Boolean);
    fs.writeFileSync(f, JSON.stringify({
      task:"E-1", kind:"epic", branchPrefix:"claude/", baseBranch:"main",
      integrationBranch:"claude/E-1", scopeApprovedAt:"2026-08-11T09:00:00.000Z",
      children: ids.map((id,i)=>({label:"C"+(i+1), title:"child "+(i+1), id,
                                  plan:{ownership:{dev:["src/f"+i+".ts"]}}})),
      edgeIds: JSON.parse(edges),
      childDispatch:{}, concurrencyCap:Number(cap),
      dispatchStaleMinutes:90, maxDispatchAttempts:2
    }, null, 2)+"\n");
  ' "$@"
}

# snap <file> <"id status [liveness] [pr]"> ...
snap() {
  local f="$1"; shift
  : > "$f"
  local row id st lv pr
  for row in "$@"; do
    # shellcheck disable=SC2086
    set -- $row
    id="$1"; st="$2"; lv="${3:-unknown}"; pr="${4:-unknown}"
    printf '%s\t%s\t%s\t%s\n' "$id" "$st" "$lv" "$pr" >> "$f"
  done
}

# Fake a fired routine without touching the network: this is exactly the block
# Step 6B runs after RemoteTrigger returns, so the record under test is the real one.
fire() {   # fire <payload> <child-id> <routine-id> [dispatchedAt]
  qx_record_child_dispatch "$1" "$2" "$3" "quetrex-spec/$2" "basesha0"
  if [ -n "${4:-}" ]; then
    node -e '
      const fs=require("fs"); const [f,cid,at]=process.argv.slice(1);
      const p=JSON.parse(fs.readFileSync(f,"utf8"));
      p.childDispatch[cid].dispatchedAt=at;
      fs.writeFileSync(f, JSON.stringify(p,null,2)+"\n");
    ' "$1" "$2" "$4"
  fi
}

plan()     { qx_epic_tick_plan "$1" "$2" "$NOW"; }
val()      { printf '%s\n' "$1" | grep -E "^$2=" | head -n1 | cut -d= -f2-; }
role_of()  { printf '%s\n' "$1" | awk -v id="$2" -F'\t' '$1=="CHILD" && $2==id {print $3}'; }
launches() { printf '%s\n' "$1" | awk -F'\t' '$1=="LAUNCH"{print $2}' | tr '\n' ' ' | sed 's/ $//'; }

expect() {  # expect <label> <actual> <want>
  if [ "$2" = "$3" ]; then pass "$1 → $3"; else fail "$1 → expected '$3', got '$2'"; fi
}

# ===========================================================================
# GROUP A — wave one: the ready set, the blocked set, and no premature fixpoint
# DAG: C1, C2 independent; C3 depends on BOTH.
# ===========================================================================
EP="$WORK/epic.json"
SN="$WORK/snap.tsv"
mk_epic "$EP" "E-1.1,E-1.2,E-1.3" '[["E-1.3","E-1.1"],["E-1.3","E-1.2"]]' 4
snap "$SN" "E-1.1 backlog" "E-1.2 backlog" "E-1.3 backlog"
P="$(plan "$EP" "$SN")" || fail "A: the planner failed on a fresh epic: $P"

expect "A1: two independent children are READY"        "$(val "$P" READY)"    2
expect "A2: the dependent child is BLOCKED"            "$(role_of "$P" E-1.3)" BLOCKED
expect "A3: nothing is in flight before anything fires" "$(val "$P" IN_FLIGHT)" 0
expect "A4: wave one is launched"                      "$(launches "$P")"     "E-1.1 E-1.2"
expect "A5: a fresh epic is NOT at a fixpoint"         "$(val "$P" FIXPOINT)" no
expect "A6: nothing is settled yet"                    "$(val "$P" ALL_SETTLED_DONE)" no

# ===========================================================================
# GROUP B — THE REGRESSION. Wave one has been fired. Nothing wrote a child
# status, because nothing in the system can. This is the exact board state that
# used to print EPIC FIXPOINT REACHED with two builds running.
# ===========================================================================
fire "$EP" E-1.1 rt_a "$(ago_iso 5)"
fire "$EP" E-1.2 rt_b "$(ago_iso 5)"
snap "$SN" "E-1.1 backlog" "E-1.2 backlog" "E-1.3 backlog"
P="$(plan "$EP" "$SN")" || fail "B: the planner failed after wave one: $P"

expect "B1: a fired child is IN_FLIGHT on its dispatch RECORD, not on a card status" "$(role_of "$P" E-1.1)" IN_FLIGHT
expect "B2: both fired children count as in flight"    "$(val "$P" IN_FLIGHT)" 2
expect "B3: nothing is ready while the wave runs"      "$(val "$P" READY)"     0
expect "B4: THE DEFECT — mid-build is NOT a fixpoint"  "$(val "$P" FIXPOINT)"  no
expect "B5: the cap is live: headroom is cap minus in-flight" "$(val "$P" HEADROOM)" 2
expect "B6: an in-flight child is never re-launched"   "$(launches "$P")"      ""

# The legacy rule, executed on the SAME fixture, so this group can never go
# vacuous: if the old arithmetic did not declare a fixpoint here, the state above
# would not be reproducing the defect at all.
LEGACY="$(node -e '
  const fs=require("fs");
  const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
  const snap=new Map();
  for(const l of fs.readFileSync(process.argv[2],"utf8").split("\n")){
    if(!l.trim()) continue; const f=l.split("\t"); snap.set(f[0],f[1]);
  }
  const DONE=new Set(["merged","deployed","complete"]);
  const ids=p.children.map(c=>c.id);
  // THE OLD RULE, verbatim: in-flight = children whose card reads in_progress.
  const inflight=ids.filter(i=>snap.get(i)==="in_progress").length;
  const deps=new Map(ids.map(i=>[i,[]]));
  for(const [a,b] of p.edgeIds) deps.get(a).push(b);
  const started=new Set(ids.filter(i=>(p.childDispatch||{})[i]));
  const ready=ids.filter(i=>!started.has(i) && deps.get(i).every(d=>DONE.has(snap.get(d))));
  process.stdout.write((inflight===0 && ready.length===0) ? "FIXPOINT" : "WORKING");
' "$EP" "$SN")"
expect "B7: control — the legacy in_progress rule DOES declare a fixpoint on this state" "$LEGACY" FIXPOINT

# ===========================================================================
# GROUP C — the concurrency cap actually caps
# ===========================================================================
EPC="$WORK/epic-cap.json"; SNC="$WORK/snap-cap.tsv"
mk_epic "$EPC" "E-2.1,E-2.2,E-2.3,E-2.4,E-2.5" '[]' 3
snap "$SNC" "E-2.1 backlog" "E-2.2 backlog" "E-2.3 backlog" "E-2.4 backlog" "E-2.5 backlog"
P="$(plan "$EPC" "$SNC")" || fail "C: planner failed: $P"
expect "C1: five ready children, cap 3 → three launched" "$(val "$P" LAUNCHING)" 3
expect "C2: the ready count is not truncated by the cap" "$(val "$P" READY)"     5

fire "$EPC" E-2.1 rt_c1 "$(ago_iso 3)"
fire "$EPC" E-2.2 rt_c2 "$(ago_iso 3)"
P="$(plan "$EPC" "$SNC")" || fail "C: planner failed after two fires: $P"
expect "C3: with 2 in flight and cap 3, exactly one more launches" "$(val "$P" LAUNCHING)" 1
expect "C4: headroom is cap − in-flight"                          "$(val "$P" HEADROOM)"  1

fire "$EPC" E-2.3 rt_c3 "$(ago_iso 3)"
P="$(plan "$EPC" "$SNC")" || fail "C: planner failed at the cap: $P"
expect "C5: at the cap nothing launches"        "$(val "$P" LAUNCHING)" 0
expect "C6: a full cap is not a fixpoint"       "$(val "$P" FIXPOINT)"  no

# ===========================================================================
# GROUP D — MULTI-WAVE DRAIN. Wave two must become eligible only after wave one
# is reaped, and the loop must terminate. This is driven as a real loop over the
# planner, so a rule that never terminates hangs the assertion instead of
# passing it.
# ===========================================================================
EPD="$WORK/epic-drain.json"; SND="$WORK/snap-drain.tsv"
mk_epic "$EPD" "E-3.1,E-3.2,E-3.3" '[["E-3.3","E-3.1"],["E-3.3","E-3.2"]]' 4
declare -a ST=(backlog backlog backlog)
IDS=(E-3.1 E-3.2 E-3.3)
write_snap() {
  : > "$SND"
  local i
  for i in 0 1 2; do printf '%s\t%s\tunknown\tnone\n' "${IDS[$i]}" "${ST[$i]}" >> "$SND"; done
}
idx_of() { case "$1" in E-3.1) echo 0;; E-3.2) echo 1;; E-3.3) echo 2;; esac; }

WAVE2_FIRED=0
TICKS=0
DRAIN_FIXPOINT=no
while [ "$TICKS" -lt 25 ]; do
  TICKS=$((TICKS + 1))
  write_snap
  P="$(plan "$EPD" "$SND")" || { fail "D: planner failed on tick $TICKS: $P"; break; }
  if [ "$(val "$P" FIXPOINT)" = "yes" ]; then DRAIN_FIXPOINT=yes; break; fi

  # Reap: /quetrex:merge <child-id> is what sets a child `merged`.
  for id in $(printf '%s\n' "$P" | awk -F'\t' '$1=="REAP"{print $2}'); do
    ST[$(idx_of "$id")]=merged
  done
  # Launch: fire each LAUNCH line, exactly as Step 6B does.
  for id in $(launches "$P"); do
    [ "$id" = "E-3.3" ] && WAVE2_FIRED=1
    fire "$EPD" "$id" "rt_$id" "$(ago_iso 1)"
    ST[$(idx_of "$id")]=in_progress   # the display-only write Step 6B makes
  done
  # The cloud routine finishes: its terminus is an OPEN PR, and it cannot write
  # the board at all — so the ONLY signal the next tick gets is the PR. Model
  # that by flipping each in-flight child to pr_ready-equivalent on the tick
  # after it was fired.
  for i in 0 1 2; do
    if [ "${ST[$i]}" = "in_progress" ] && [ -n "$(node -e '
        const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
        const d=(p.childDispatch||{})[process.argv[2]];
        process.stdout.write(d?"y":"");' "$EPD" "${IDS[$i]}")" ]; then
      ST[$i]=pr_ready
    fi
  done
done

expect "D1: the drain loop reaches a fixpoint"                 "$DRAIN_FIXPOINT" yes
expect "D2: WAVE TWO was dispatched — the dependent child ran" "$WAVE2_FIRED"    1
expect "D3: every child ended merged"                          "${ST[0]}/${ST[1]}/${ST[2]}" "merged/merged/merged"
write_snap
P="$(plan "$EPD" "$SND")"
expect "D4: at the fixpoint the epic reports ALL_SETTLED_DONE" "$(val "$P" ALL_SETTLED_DONE)" yes
if [ "$TICKS" -lt 25 ]; then
  pass "D5: the DAG drained in $TICKS ticks (bounded, so the tick terminates)"
else
  fail "D5: the drain loop hit its 25-tick bound without a fixpoint — the tick does not terminate"
fi

# ===========================================================================
# GROUP E — liveness and staleness INSIDE the tick (per-child form of gap 2)
# ===========================================================================
EPE="$WORK/epic-live.json"; SNE="$WORK/snap-live.tsv"

mk_epic "$EPE" "E-4.1" '[]' 4
fire "$EPE" E-4.1 rt_e1 "$(ago_iso 10)"
snap "$SNE" "E-4.1 backlog"
P="$(plan "$EPE" "$SNE")"
expect "E1: a fresh dispatch is IN_FLIGHT" "$(role_of "$P" E-4.1)" IN_FLIGHT

mk_epic "$EPE" "E-4.1" '[]' 4
fire "$EPE" E-4.1 rt_e1 "$(ago_iso 500)"
snap "$SNE" "E-4.1 backlog"
P="$(plan "$EPE" "$SNE")"
expect "E2: past the staleness horizon the child is PROBE, NOT re-fired" "$(role_of "$P" E-4.1)" PROBE
expect "E3: a stale-but-unprobed child launches nothing (a clock never re-fires a build)" "$(launches "$P")" ""
expect "E4: a child awaiting a probe still occupies a slot" "$(val "$P" HEADROOM)" 3
if printf '%s\n' "$P" | grep -q "^PROBE	E-4.1	rt_e1$"; then
  pass "E5: the plan names the routine id to probe, so the next step is mechanical"
else
  fail "E5: no 'PROBE<TAB>E-4.1<TAB>rt_e1' line — the operator/tick has nothing to call RemoteTrigger get with: $(printf '%s' "$P" | tr '\n' '|')"
fi

snap "$SNE" "E-4.1 backlog running"
P="$(plan "$EPE" "$SNE")"
expect "E6: probed running → still IN_FLIGHT however old it is" "$(role_of "$P" E-4.1)" IN_FLIGHT
expect "E7: a running routine is never re-fired"               "$(launches "$P")"      ""

snap "$SNE" "E-4.1 backlog dead"
P="$(plan "$EPE" "$SNE")"
expect "E8: probed dead with attempts left → RECOVER"  "$(role_of "$P" E-4.1)" RECOVER
expect "E9: a recovered child is launched exactly once" "$(launches "$P")"     "E-4.1"

snap "$SNE" "E-4.1 backlog gone"
P="$(plan "$EPE" "$SNE")"
expect "E10: a 404'd routine id counts as dead" "$(role_of "$P" E-4.1)" RECOVER

# Second fire consumes the last attempt: maxDispatchAttempts=2.
fire "$EPE" E-4.1 rt_e2 "$(ago_iso 500)"
snap "$SNE" "E-4.1 backlog dead"
P="$(plan "$EPE" "$SNE")"
expect "E11: out of attempts → EXHAUSTED, never a third fire" "$(role_of "$P" E-4.1)" EXHAUSTED
expect "E12: an exhausted child launches nothing"             "$(launches "$P")"      ""
expect "E13: an exhausted child is a fixpoint, not an infinite loop" "$(val "$P" FIXPOINT)" yes
ATT="$(node -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String(p.childDispatch["E-4.1"].attempts))' "$EPE")"
expect "E14: the child attempt counter is cumulative across recoveries" "$ATT" 2
BS="$(node -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String(p.childDispatch["E-4.1"].baseSha))' "$EPE")"
expect "E15: a refire REUSES the pinned base sha (never re-resolves the moving integration branch)" "$BS" basesha0

# Terminus evidence beats a dead probe: a routine that died AFTER opening its PR
# must be reaped, never rebuilt. This is the duplicate-build guard.
mk_epic "$EPE" "E-4.1" '[]' 4
fire "$EPE" E-4.1 rt_e1 "$(ago_iso 500)"
snap "$SNE" "E-4.1 backlog dead open"
P="$(plan "$EPE" "$SNE")"
expect "E16: a dead routine that already opened its PR is REAPed, not re-dispatched" "$(role_of "$P" E-4.1)" REAP
expect "E17: nothing is launched for it"                                             "$(launches "$P")"      ""

# pr_ready alone is also a reap trigger (for the day the board write lands).
snap "$SNE" "E-4.1 pr_ready"
P="$(plan "$EPE" "$SNE")"
expect "E18: pr_ready is a reap trigger"        "$(role_of "$P" E-4.1)" REAP
expect "E19: an unreaped child is not a fixpoint" "$(val "$P" FIXPOINT)" no

# needs_clarity: the child stops, its dependents wait, nothing cascades.
EPF="$WORK/epic-fail.json"; SNF="$WORK/snap-fail.tsv"
mk_epic "$EPF" "E-5.1,E-5.2,E-5.3" '[["E-5.3","E-5.1"]]' 4
fire "$EPF" E-5.1 rt_f1 "$(ago_iso 5)"
snap "$SNF" "E-5.1 needs_clarity" "E-5.2 merged" "E-5.3 backlog"
P="$(plan "$EPF" "$SNF")"
expect "E20: a failed child is FAILED"                         "$(role_of "$P" E-5.1)" FAILED
expect "E21: its dependent WAITS rather than being cascaded"   "$(role_of "$P" E-5.3)" BLOCKED
expect "E22: a permanently blocked DAG is a fixpoint, not a spin" "$(val "$P" FIXPOINT)" yes
expect "E23: a failed epic does not report ALL_SETTLED_DONE"   "$(val "$P" ALL_SETTLED_DONE)" no

# ===========================================================================
# GROUP F — gap 2 at the single-unit guard: qx_actionability liveness
# ===========================================================================
mk_unit() {   # mk_unit <file> <dispatchedAt|-> <attempts> <maxAttempts>
  node -e '
    const fs=require("fs");
    const [f,disp,att,max]=process.argv.slice(1);
    fs.writeFileSync(f, JSON.stringify({
      task:"E-1", kind:"single", branchPrefix:"claude/", baseBranch:"main",
      scopeApprovedAt:"2026-08-11T09:00:00.000Z",
      dispatchStaleMinutes:90, maxDispatchAttempts:Number(max),
      dispatchAttempts:Number(att),
      dispatch: disp==="-" ? null : { routineId:"rt_u1",
        monitorUrl:"https://claude.ai/code/routines/rt_u1",
        specBranch:"quetrex-spec/E-1", baseSha:"deadbeef",
        dispatchedAt:disp, attempts:Number(att) }
    }, null, 2)+"\n");
  ' "$@"
}
verdict_of() {  # verdict_of <payload> <mode> [liveness]
  QX_NOW="$NOW" qx_actionability in_progress single "$2" "$1" "${3:-unknown}" 2>&1
}
rc_of() { QX_NOW="$NOW" qx_actionability in_progress single "$2" "$1" "${3:-unknown}" >/dev/null 2>&1; echo $?; }

U="$WORK/unit.json"

mk_unit "$U" "$(ago_iso 10)" 1 2
expect "F1: a fresh dispatch, unprobed → REFUSE"      "$(verdict_of "$U" build | cut -d' ' -f1)" REFUSE
expect "F2: ...and it stops the command (rc 1)"       "$(rc_of "$U" build)" 1

mk_unit "$U" "$(ago_iso 500)" 1 2
OUT="$(verdict_of "$U" build)"
expect "F3: a STALE dispatch, unprobed → still REFUSE (age alone never re-fires)" "${OUT%% *}" REFUSE
case "$OUT" in
  *"rt_u1"*) pass "F4: the stale refusal names the routine id to probe" ;;
  *) fail "F4: the stale refusal does not name dispatch.routineId, so there is nothing to probe: $OUT" ;;
esac
case "$OUT" in
  *RemoteTrigger*) pass "F5: the stale refusal names the probe as the next step — it is no longer a dead end" ;;
  *) fail "F5: the stale refusal offers no recovery step at all, which is the permanent wedge: $OUT" ;;
esac
case "$OUT" in
  *"staleness horizon"*) pass "F6: the stale refusal says WHY it is suspect" ;;
  *) fail "F6: the stale refusal reads identically to a healthy in-flight one: $OUT" ;;
esac

expect "F7: probed running on a stale dispatch → REFUSE" "$(verdict_of "$U" build running | cut -d' ' -f1)" REFUSE
expect "F8: ...rc 1"                                     "$(rc_of "$U" build running)" 1

expect "F9: probed dead with attempts left → RECOVERABLE" "$(verdict_of "$U" build dead | cut -d' ' -f1)" RECOVERABLE
expect "F10: ...and it lets the build proceed (rc 0)"     "$(rc_of "$U" build dead)" 0
expect "F11: a 404'd routine (gone) recovers too"         "$(verdict_of "$U" build gone | cut -d' ' -f1)" RECOVERABLE
expect "F12: recovery works in --tick mode as well"       "$(verdict_of "$U" tick dead | cut -d' ' -f1)" RECOVERABLE
expect "F13: recovery works in full mode as well"         "$(verdict_of "$U" full dead | cut -d' ' -f1)" RECOVERABLE

mk_unit "$U" "$(ago_iso 500)" 2 2
OUT="$(verdict_of "$U" build dead)"
expect "F14: out of attempts → REFUSE, not a third fire" "${OUT%% *}" REFUSE
case "$OUT" in
  *maxDispatchAttempts*|*"needs a human"*) pass "F15: the exhausted refusal says a human is the next move" ;;
  *) fail "F15: the exhausted refusal does not explain itself: $OUT" ;;
esac

# The attempt counter has to SURVIVE the clear, or maxDispatchAttempts can never
# bind and RECOVERABLE is an unbounded re-dispatch loop. Drive the real blocks.
mk_unit "$U" - 0 2
node -e '
  const fs=require("fs"); const f=process.argv[1];
  const p=JSON.parse(fs.readFileSync(f,"utf8")); p.dispatchAttempts=0;
  fs.writeFileSync(f, JSON.stringify(p,null,2)+"\n");' "$U"
qx_record_dispatch "$U" rt_1 quetrex-spec/E-1 sha1
A1="$(quetrex-api json-get "$U" dispatch.attempts)"
qx_clear_dead_dispatch "$U"
qx_record_dispatch "$U" rt_2 quetrex-spec/E-1 sha1
A2="$(quetrex-api json-get "$U" dispatch.attempts)"
expect "F16: the first dispatch records attempt 1"                       "$A1" 1
expect "F17: after a clear, the NEXT dispatch records attempt 2 (cumulative)" "$A2" 2
expect "F18: and that second dispatch is then exhausted when probed dead" \
  "$(QX_NOW="$NOW" qx_actionability in_progress single build "$U" dead 2>&1 | cut -d' ' -f1)" REFUSE
KEPT="$(node -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String((p.recoveredDispatches||[]).length))' "$U")"
expect "F19: the dead dispatch is kept as evidence, not silently dropped" "$KEPT" 1

# Regressions on the untouched verdicts — a liveness argument must not have
# changed what the guard already got right.
expect "F20: an unapproved payload is still not 'in flight'" \
  "$(QX_NOW="$NOW" qx_actionability in_progress single full "$WORK/does-not-exist.json" 2>&1 | cut -d' ' -f1)" RESUMABLE
expect "F21: merged still refuses even with a dead probe" \
  "$(QX_NOW="$NOW" qx_actionability merged single build "$U" dead 2>&1 | cut -d' ' -f1)" REFUSE
expect "F22: an epic in_progress still RESUMEs" \
  "$(QX_NOW="$NOW" qx_actionability in_progress epic tick "$U" dead 2>&1 | cut -d' ' -f1)" RESUME

# ===========================================================================
# GROUP G — the planner refuses to guess
# ===========================================================================
EPG="$WORK/epic-bad.json"; SNG="$WORK/snap-bad.tsv"
mk_epic "$EPG" "E-6.1,E-6.2" '[]' 4
snap "$SNG" "E-6.1 backlog"            # E-6.2 deliberately missing
if OUT="$(qx_epic_tick_plan "$EPG" "$SNG" "$NOW" 2>&1)"; then
  fail "G1: a partial board snapshot was planned anyway — a child with no status read was treated as launchable: $OUT"
else
  pass "G1: a child missing from the board snapshot stops the tick instead of being guessed"
fi

snap "$SNG" "E-6.1 backlog" "E-6.2 wat"
if OUT="$(qx_epic_tick_plan "$EPG" "$SNG" "$NOW" 2>&1)"; then
  fail "G2: an unmodelled status was planned around: $OUT"
else
  pass "G2: an unmodelled child status stops the tick"
fi

node -e '
  const fs=require("fs"); const f=process.argv[1];
  const p=JSON.parse(fs.readFileSync(f,"utf8")); p.children[1].id=null;
  fs.writeFileSync(f, JSON.stringify(p,null,2)+"\n");' "$EPG"
snap "$SNG" "E-6.1 backlog" "E-6.2 backlog"
if OUT="$(qx_epic_tick_plan "$EPG" "$SNG" "$NOW" 2>&1)"; then
  fail "G3: a child whose create-child identifier was never written back was planned anyway: $OUT"
else
  pass "G3: a child with no id stops the tick (Step 4c never wrote the identifier back)"
fi

mk_epic "$EPG" "E-6.1,E-6.2" '[["E-6.1","E-6.99"]]' 4
snap "$SNG" "E-6.1 backlog" "E-6.2 backlog"
if OUT="$(qx_epic_tick_plan "$EPG" "$SNG" "$NOW" 2>&1)"; then
  fail "G4: an edge naming a child outside children[] was silently ignored, so a real dependency was not enforced: $OUT"
else
  pass "G4: an edge naming an unknown child stops the tick"
fi

# Purity: same inputs, same output — the tick is stateless by construction and a
# hidden clock read would break the drain loop above in production only.
mk_epic "$EPG" "E-6.1,E-6.2" '[]' 4
snap "$SNG" "E-6.1 backlog" "E-6.2 backlog"
O1="$(plan "$EPG" "$SNG")"; O2="$(plan "$EPG" "$SNG")"
if [ "$O1" = "$O2" ]; then
  pass "G5: the planner is deterministic for identical inputs"
else
  fail "G5: two identical plans differed — the tick is not a pure function of (payload, snapshot, clock)"
fi

# ===========================================================================
# GROUP H — the section still says what the executable parts cannot (text)
# ===========================================================================
awk '/^### B\) Epic/{inb=1} /^## Step 7/{inb=0} inb{print}' "$COMMAND" > "$WORK/step6b.md"
if [ -s "$WORK/step6b.md" ]; then
  pass "H0: located Step 6B ($(wc -l < "$WORK/step6b.md" | tr -d ' ') lines)"
else
  fail "H0: cannot locate Step 6B — the assertions below would pass vacuously"
fi
if grep -q 'qx_epic_tick_plan' "$WORK/step6b.md"; then
  pass "H1: the tick's decisions come from the executable planner, not from prose arithmetic"
else
  fail "H1: Step 6B does not call qx_epic_tick_plan — the cap and the fixpoint are prose again"
fi
if grep -qi 'never read by the tick\|No decision in this tick reads it' "$WORK/step6b.md"; then
  pass "H2: Step 6B states that the child in_progress write is for the human only"
else
  fail "H2: nothing warns that a child's in_progress status must not be decided from — that is exactly how this broke"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "epic-tick.test.sh: all checks passed"
  exit 0
else
  echo "epic-tick.test.sh: FAILURES above"
  exit 1
fi
