---
description: Vet, classify, and build one Quetrex task end to end. Splits at the human scope gate — a PLAN half that produces the architect's plan and asks for approval, and a BUILD half that a routine can run unattended from the approved payload. Single unit for a feature/bug, or one-level epic decomposition with a DAG of child workflows that auto-merge into a per-epic integration branch. Usage: /q-task-build SMA-1 [--build-only|--tick]
argument-hint: <TASK-ID like SMA-1> [--build-only | --tick]
---

# q-task-build

Take one kanban task from intake to open PR(s), in **two halves split at the human scope gate**:

| Half | Steps | Runs where | Needs a human? |
|---|---|---|---|
| **PLAN** | 1–4 | wherever a person can answer | yes — one tap on Approve |
| **BUILD** | 5–7 | unattended, from the approved payload | no |

That split is the product. The plan half ends by writing a **build payload artifact** and
asking for approval. The build half reads only that artifact, so it can be re-entered from
a fresh process — a routine, a resumed session, or a later terminal — with nothing carried
in conversation.

**Modes**

- `/q-task-build SMA-1` — plan half → scope gate → build half on approval.
- `/q-task-build SMA-1 --build-only` — build half **only**, against an already-approved
  payload. This is the entry point an automated trigger uses; it refuses to run if the
  payload is missing or unapproved.
- `/q-task-build SMA-1 --tick` — run exactly **one** epic dispatch tick and exit. Used by
  `/loop` (step 6B); harmless to run by hand.

THE DEV PIPELINE itself is defined **once** in `.claude/lib/dev-pipeline.md` and is **not**
restated here. This command is the lean intake + gate + dispatcher; the heavy work runs in
background Workflow-tool runs so the terminal stays free.

All kanban I/O goes through the token-safe helpers in `.claude/lib/quetrex-api.sh`
(`qapi` + the `qx_*` wrappers): never echo the token, never `set -x` / `curl -v` around
`qapi`, always build JSON with `node` / `JSON.stringify`.

Argument: `$ARGUMENTS` is a task identifier (`SMA-1`) plus an optional mode flag.

---

## Step 1 — Parse, resolve, fetch

```bash
TASK_ID="$(echo "$ARGUMENTS" | tr -d '[:space:]' | sed 's/--.*$//')"
MODE="full"
case "$ARGUMENTS" in *--build-only*) MODE="build" ;; *--tick*) MODE="tick" ;; esac
```

If `TASK_ID` is empty, print usage and stop:

> Usage: `/q-task-build SMA-1 [--build-only | --tick]`

Source the helper and resolve context in one bash block — the helper owns all auth/access
messaging; do not reinvent it. Resolve the **branch prefix** here too: every branch this
command constructs uses it.

```bash
source ~/.claude/lib/quetrex-api.sh
resolve_auth    || exit 1      # prints "Run /q-login" on failure
resolve_project || exit 1      # prints "Run /q-init" on failure
qapi GET "/api/projects/$QX_PROJECT_CODE" >/dev/null || exit 1   # validate access
TASK="$(qapi GET "/api/tasks/$TASK_ID")" || exit 1

REPO_ROOT="$(git rev-parse --show-toplevel)"
# Branch prefix: NEVER hardcode "feature/". A repo whose push rules cannot be loosened
# sets "branchPrefix": "claude/" in .quetrex/project.json, and every branch below follows.
BRANCH_PREFIX="$(_qx_json_get "$REPO_ROOT/.quetrex/project.json" branchPrefix 2>/dev/null || echo 'feature/')"
[ -n "$BRANCH_PREFIX" ] || BRANCH_PREFIX="feature/"

echo "Project: $QX_PROJECT_CODE @ $QX_KANBAN_URL   branchPrefix=$BRANCH_PREFIX"
```

If any resolver or `qapi` call exits non-zero, the helper already printed the correct
message (401 → `Run /q-login`; 403/404 → `No access — contact your administrator`; other →
`Quetrex API error (HTTP <code>)`). Just stop.

**If `MODE` is `build` or `tick`, skip straight to Step 5.** Those modes read the payload
artifact and must never re-plan or re-ask for approval.

Read the fields from `$TASK`:

```bash
node -e '
  let o; try{o=JSON.parse(process.argv[1])}catch{process.exit(1)}
  const g=k=>o[k]==null?"":String(o[k]);
  console.log(["status="+g("status"),"type="+g("type"),"title="+g("title"),
               "parentTaskId="+g("parentTaskId")].join("\n"));
' "$TASK"
```

**Actionability guard.**

- Actionable starting statuses: `backlog`, `queued`. A `needs_clarity` task should go
  through `/q-task-rework` instead — say so and stop.
- If the task is already `pr_ready` / `merged` / `deployed` / `complete`, say so and
  **stop** (avoid duplicate work).
- If the task is already `in_progress`:
  - **a single unit** (no children) → say so and **stop** (its pipeline is already
    running).
  - **an epic that already has children** (persisted `type` is `project`/epic and `$TASK`
    exposes child tasks) → this is a **RESUME**, not duplicate work. Skip the plan half
    entirely (decomposition and approval are one-time and already done) and go to
    **Step 5** in build mode over the existing children. This is the supported path for
    draining dependents that a `/q-task-rework` of a failed child has since unblocked.
- If the task is an **epic child** (`parentTaskId` is set), say: "this is a child of
  `<EPIC-ID>`; run `/q-task-build` on the epic, or `/q-task-rework` on the child" and
  **stop**. `/q-task-build` operates on standalone tasks and epics, not lone children.

---

## Step 2 — Vet + classify

- Read the task **and the repo code** (Glob / Grep / Read) to ground your understanding of
  what the change actually touches.
- If the description is unclear or underspecified, **ask the user** sharp clarifying
  questions (or suggest `/q-task-refine SMA-1`) and wait. Do **not** guess on genuine gaps.
- **Classify** the task as **Project / Feature / Bug** and persist the label:

```bash
qx_task_type "$TASK_ID" "<project|feature|bug>"
```

---

## Step 3 — Plan (still the interactive half — nothing is built yet)

### A) FEATURE / BUG → one unit

Run THE DEV PIPELINE as defined in `.claude/lib/dev-pipeline.md`, **stopping after the
architect stage**, with these inputs:

- `TASK_ID` = `$TASK_ID`
- `TASK_TITLE` = the task title
- `BASE_BRANCH` = `main`
- `BRANCH_PREFIX` = `$BRANCH_PREFIX`
- `WORKFLOW_TITLE` = `"$TASK_ID · <title> (plan)"`
- `PIPELINE_STOP_AFTER` = `architect`
- the resolved kanban context (`QX_KANBAN_URL`, `QX_PROJECT_CODE`)

This isolates the worktree, sets the task `in_progress`, and produces
`.quetrex/plan/<TASK_ID>.json` — the acceptance criteria, the **strict file-ownership
map**, the `security_surface`, and the verify chain. **No developer runs yet.** Record the
worktree path and the unit branch name; they go into the payload.

### B) PROJECT / EPIC → decompose, ONE LEVEL ONLY

Plan the epic into a set of **child units** — no grandchildren (this keeps child
identifiers `CODE-N.C` collision-free) — with a **dependency graph** (edges between
children). Ground the decomposition in an architect-grade read of the repo: each child
must be an independently buildable, file-disjoint slice.

**Validate the proposed graph is a DAG (no cycles) before asking.** Build the edge list
and check it with `node` — write nothing to the kanban until this passes:

```bash
# EDGES_JSON = JSON like [["C3","C1"],["C3","C2"]] meaning "child -> dependsOn".
node -e '
  const edges=JSON.parse(process.argv[1]);          // [child, dependsOn] pairs
  const adj=new Map(), indeg=new Map(), nodes=new Set();
  for(const [a,b] of edges){ nodes.add(a); nodes.add(b);
    (adj.get(b)||adj.set(b,[]).get(b)).push(a);
    indeg.set(a,(indeg.get(a)||0)+1); if(!indeg.has(b)) indeg.set(b,indeg.get(b)||0); }
  for(const n of nodes) if(!indeg.has(n)) indeg.set(n,0);
  const q=[...nodes].filter(n=>indeg.get(n)===0); let seen=0;
  while(q.length){ const n=q.shift(); seen++;
    for(const m of (adj.get(n)||[])){ indeg.set(m,indeg.get(m)-1); if(indeg.get(m)===0) q.push(m); } }
  if(seen!==nodes.size){ console.error("CYCLE — not a DAG; revise the plan"); process.exit(1); }
  console.log("DAG OK");
' "$EDGES_JSON" || { echo "Dependency graph is not a DAG — revise before approval." >&2; exit 1; }
```

Iterate on the plan with the user if they tweak it (re-validate after each change).

---

## Step 4 — THE SCOPE GATE (the one human tap)

**Both paths gate here.** The epic path has always had a scope gate; the single-unit path
now has the same one. Without it, a standalone task sends `bypassPermissions` developers
at the repo with nobody having agreed what they may touch — which is exactly the model
this product replaces.

> **This does not weaken Pipeline Mode.** Pipeline Mode governs behaviour *once the
> pipeline starts*: no confirmations, no "does this look right?", no plan reviews between
> stages, run every stage to completion. This gate fires **before** the pipeline starts —
> it is the boundary Pipeline Mode begins at, not an interruption of it. Once approval is
> given, ask nothing further.

### 4a. Write the build payload artifact — BEFORE asking

Write the payload first so the approval has something durable to attach to, and so a
compaction between here and the build half loses nothing. **The child-label → child-ID map
lives in this file, never only in the conversation.**

```bash
mkdir -p "$REPO_ROOT/.quetrex/build"
PAYLOAD="$REPO_ROOT/.quetrex/build/$TASK_ID.json"

# CHILDREN_JSON (epic only): [{"label":"C1","title":"…","desc":"…","id":null}, …]
# EDGES_JSON    (epic only): [["C3","C1"], …]  — plan LABELS, resolved to ids in 4c.
node -e '
  const fs=require("fs");
  const [file,task,title,kind,prefix,base,children,edges,session] = process.argv.slice(1);
  const out = {
    task, title, kind,                       // kind: "single" | "epic"
    branchPrefix: prefix,
    baseBranch: base,
    integrationBranch: kind === "epic" ? prefix + task : null,
    planPath: ".quetrex/plan/" + task + ".json",
    sessionId: session || null,              // the plan-half session, for --resume
    scopeApprovedAt: null,                   // set in 4c, on approval
    children: JSON.parse(children || "[]"),  // [{label,title,desc,id}] — id filled in 4c
    edges: JSON.parse(edges || "[]"),        // label pairs [child, dependsOn]
    edgeIds: [],                             // resolved id pairs, filled in 4c
    concurrencyCap: 4,                       // 3–5
    tickIntervalMinutes: 3                   // 2–5; children are multi-minute
  };
  fs.mkdirSync(require("path").dirname(file), {recursive:true});
  fs.writeFileSync(file, JSON.stringify(out, null, 2) + "\n");
' "$PAYLOAD" "$TASK_ID" "$TASK_TITLE" "<single|epic>" "$BRANCH_PREFIX" "main" \
  "${CHILDREN_JSON:-[]}" "${EDGES_JSON:-[]}" "${CLAUDE_CODE_SESSION_ID:-}"
echo "Wrote build payload: $PAYLOAD"
```

`sessionId` is the plan half's session. The build half prefers to resume it
(`claude --resume "$sessionId"`) so the architect's reasoning is still in context. **The
documented fallback is a fresh run seeded from the plan artifact** — `planPath` plus the
payload is a complete brief on its own, and a fresh run is never a failure state. Say
which of the two was used in the report.

### 4b. Present the scope and ask — nothing is created until they approve

**Single unit.** Show, from `.quetrex/plan/<TASK_ID>.json`:
- the **acceptance criteria** (each Given/When/Then + its numeric `measure`),
- the **file-ownership map** — every path the developers may write, per workstream,
- the `security_surface` and whether `security_review_required` is set,
- the unit branch (`${BRANCH_PREFIX}<TASK_ID>-<slug>`) and the PR target (`main`).

**Epic.** Show:
- the proposed child cards — title + one-line scope each,
- the dependency edges in plain language ("C3 depends on C1, C2"),
- the integration branch (`${BRANCH_PREFIX}<EPIC-ID>`) and that children PR into it, not
  `main`.

Then ask for explicit approval of **scope**. This is the tap on Approve. Do not ask about
implementation choices, ordering, or style — those are the pipeline's business.

### 4c. On approval — materialize

```bash
node -e '
  const fs=require("fs");
  const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
  p.scopeApprovedAt=new Date().toISOString();
  fs.writeFileSync(process.argv[1], JSON.stringify(p,null,2)+"\n");
' "$PAYLOAD"
```

**Epic only**, in order:

```bash
# a) Create each child; write its returned identifier back into the payload immediately.
#    The label -> id map is persisted per child, not batched at the end, so an interruption
#    mid-materialization leaves a payload that still describes exactly what exists.
CHILD_ID="$(qx_create_child "$TASK_ID" "<child title>" "<child desc>")" || exit 1
node -e '
  const fs=require("fs");
  const [file,label,id]=process.argv.slice(1);
  const p=JSON.parse(fs.readFileSync(file,"utf8"));
  const c=p.children.find(c=>c.label===label); if(c) c.id=id;
  fs.writeFileSync(file, JSON.stringify(p,null,2)+"\n");
' "$PAYLOAD" "<C1>" "$CHILD_ID"
# ...repeat per child.

# b) Resolve the label edges to id edges, then add each dependency edge.
node -e '
  const fs=require("fs");
  const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
  const byLabel=Object.fromEntries(p.children.map(c=>[c.label,c.id]));
  p.edgeIds=p.edges.map(([a,b])=>[byLabel[a],byLabel[b]]).filter(([a,b])=>a&&b);
  fs.writeFileSync(process.argv[1], JSON.stringify(p,null,2)+"\n");
  for(const [a,b] of p.edgeIds) console.log(a+"\t"+b);
' "$PAYLOAD" | while IFS=$'\t' read -r CH DEP; do
  qx_add_dep "$CH" "$DEP" || exit 1
done
```

Then create the **per-epic integration branch** `${BRANCH_PREFIX}<EPIC-ID>` off `main` via
the `worktree-workflow` skill (use `git -C` so the enforce-branch hook sees the branch).
Finally set the **epic** itself to `in_progress` and post a summary comment:

```bash
qx_task_status "$TASK_ID" in_progress
qx_task_comment "$TASK_ID" "Scope approved. Epic decomposed into N children with M dependency edges; integration branch ${BRANCH_PREFIX}$TASK_ID created. Dispatching ready children."
```

---

# ── SPLIT ── everything below runs unattended

## Step 5 — BUILD HALF entry (and the automated entry point)

Reached three ways: straight on from Step 4c, via `--build-only`, or via the Step 1 resume
path. **Read the payload; carry nothing in from conversation.**

```bash
PAYLOAD="$REPO_ROOT/.quetrex/build/$TASK_ID.json"
[ -f "$PAYLOAD" ] || { echo "No build payload for $TASK_ID — run /q-task-build $TASK_ID to plan and approve scope first." >&2; exit 1; }
node -e '
  const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  if(!p.scopeApprovedAt){ console.error("Scope for "+p.task+" has NOT been approved — refusing to build."); process.exit(1); }
  console.log(["kind="+p.kind,"base="+p.baseBranch,"prefix="+p.branchPrefix,
               "integration="+(p.integrationBranch||"-"),"plan="+p.planPath,
               "session="+(p.sessionId||"-"),"cap="+p.concurrencyCap,
               "tick="+p.tickIntervalMinutes+"m"].join("\n"));
' "$PAYLOAD" || exit 1
```

**Refusing to build an unapproved payload is a gate, not a convenience check.** Never
synthesize a `scopeApprovedAt` to get moving.

**The one exception, and it is narrow.** An epic that is already `in_progress` **with
children materialized on the board** was approved — the children only exist because a
human approved the decomposition, and the kanban is the state of truth. If such an epic
has no payload (it predates this artifact, or the file was lost), reconstruct one from the
board — `children[].id` and `edgeIds` read back from the API, `integrationBranch` =
`${BRANCH_PREFIX}<EPIC-ID>`, `scopeApprovedAt` = now with a comment recording that it was
reconstructed — and say so in the report. This is **not** a licence to reconstruct a
payload for a `backlog`/`queued` task or for a single unit: no children on the board means
no approval happened, and the answer is to run the plan half.

If `sessionId` is set and resumable, prefer resuming it. If it is absent or the resume
fails, **run fresh, seeded from `planPath` plus this payload** — the documented fallback,
not an error. Report which happened.

## Step 6 — Dispatch

### A) Single unit

Run THE DEV PIPELINE from `.claude/lib/dev-pipeline.md`, **resuming after the architect
stage**, with:

- `TASK_ID`, `TASK_TITLE`, `BASE_BRANCH` = `main`, `BRANCH_PREFIX`,
- `WORKFLOW_TITLE` = `"<TASK_ID> · <title>"`,
- `PIPELINE_RESUME_FROM` = `developers`,
- `PLAN_ARTIFACT` = the payload's `planPath` — **already written and human-approved; do
  not re-plan and do not widen the ownership map.**

The PR targets `main`. Dispatch the workflow in the **background**. The engine drives
`in_progress → pr_ready` (or `needs_clarity` on bounded-loop exhaustion). Then go to
**Step 7**.

### B) Epic — DAG dispatch as a `/loop` tick

The dispatcher is **stateless by construction**: the kanban is the state of truth (status
+ dependencies + `isBlocked`) and readiness is recomputed from the API every tick, so
nothing has to survive between ticks. That is what makes it safe to run as an interval
loop instead of an in-session poll that quietly depends on the session staying alive.

Run **one tick inline** first (so work starts now, not one interval from now), then arm the
loop at the payload's `tickIntervalMinutes` — **2–5 minutes**. Children are multi-minute
units; anything faster is pure API noise, and anything slower wastes the DAG's parallelism.

```
/loop 3m /q-task-build <EPIC-ID> --tick
```

That is a slash command, not shell. Stop the loop at the fixpoint (step 4 below).

**One tick** (this is all `--tick` does — do exactly this, then exit):

1. **Compute the ready set** — children not yet started whose dependencies are all
   `DONE_FOR_UNBLOCKING = {merged, deployed, complete}`:

   ```bash
   qx_is_unblocked "<child-id>"   # exit 0 = ready, 1 = still blocked
   ```

   Prefer the server's `isBlocked` flag; the helper falls back to checking dependency
   statuses. Read the child ids from the payload's `children[].id` — never from memory.

2. **Launch up to the cap.** Count children currently `in_progress` (in-flight) and launch
   ready children only up to `cap − in_flight` (`concurrencyCap`, 3–5). For each, launch
   **its own named Workflow-tool run** titled `"<EPIC-ID> · <unit name>"`, running THE DEV
   PIPELINE with:
   - `TASK_ID` = the child id,
   - `TASK_TITLE` = the child title,
   - `BASE_BRANCH` = the payload's `integrationBranch`,
   - `BRANCH_PREFIX` = the payload's `branchPrefix`,
   - `WORKFLOW_TITLE` = `"<EPIC-ID> · <unit name>"`.

   The child PR targets the **integration branch**, never `main`. Dispatch in the
   background; the engine marks the child `in_progress` as its first action.

3. **Reap.** A child whose pipeline reached review-approved + green has had its PR
   squash-auto-merged into the integration branch — the one place auto-merge is allowed,
   because it merges into the integration branch, **never** `main`. Set it `merged`
   (`qx_task_status "<child-id>" merged`); that unblocks its dependents, which the next
   tick picks up. A child the engine sent to `needs_clarity` stays there: its
   **independent siblings keep running**, its **dependents WAIT** — never auto-`needs_clarity`
   a dependent by association.

4. **Evaluate the terminus and print one line.** The exit condition is unchanged: the DAG
   is at a **fixpoint** when **no child is in-flight (`in_progress`)** AND **the ready set
   is empty**. It always terminates — each tick a child either advances toward `merged` /
   `needs_clarity` or there is nothing left to launch. A child whose dependency is
   `needs_clarity` is **permanently blocked until a human reworks that dependency**, so it
   is part of the fixpoint, not a reason to keep ticking.

   - Not at the fixpoint → print `EPIC TICK: <n> in-flight, <m> ready, <k> blocked` and
     exit the tick. The loop fires again next interval.
   - At the fixpoint → print `EPIC FIXPOINT REACHED`, go to **Step 7**, and **stop the
     loop**. A loop left running past the fixpoint is a defect.

## Step 7 — Terminus + report

The heavy work — every unit's DEV PIPELINE — runs in **background** Workflow-tool runs;
you never parse their stdout.

**Single unit.** Fire-and-forget: report the workflow title, the branch, and that it is
building toward `pr_ready`. The pipeline's terminus is an open PR. Whether it then merges
is decided by the reviewer's verdict and enforced by `merge-gate.sh` — `AUTO_MERGE` pinned
to HEAD with a green ledger permits the squash merge; `REWORK` / `ESCALATE_HUMAN` sends the
task to `needs_clarity` for `/q-task-rework`. There is **no `/q-task-merge` command**; do
not tell the user to run one.

**Epic, at the fixpoint.** Partition the children:

- **All children `merged`** → open the single **integration → main PR**
  (`${BRANCH_PREFIX}<EPIC-ID>` → `main`) via the `git-workflow` agent or
  `gh pr create --base main --head "${BRANCH_PREFIX}<EPIC-ID>"`, so the merge gate has a
  PR to act on. That PR is the epic's terminus; it merges under the same `merge-gate.sh`
  rules as any other. Leave the epic `in_progress` until it merges, then
  `qx_task_status <EPIC-ID> merged`. (Every child branch was deleted on its auto-merge, so
  the integration branch is the only one carrying the epic id.)

- **Any child `needs_clarity`, or blocked-waiting on one** → do **NOT** open the
  integration PR. Report exactly which children **failed** and which are
  **blocked-waiting** on a failed dependency. The user runs **`/q-task-rework <child>`** on
  each failure; on pass it auto-merges into the integration branch and **unblocks** its
  dependents. Re-running **`/q-task-build <EPIC-ID>`** then resumes the dispatcher (Step 1
  resume path → Step 5) and drains the now-eligible dependents. Only when every child is
  `merged` is the integration → main PR opened. The epic stays `in_progress` throughout.

Point the user to `/workflows` and the board for live progress. Do **not** parse workflow
output inline.

---

## Error-handling rules

- Any `qapi` or resolver non-zero exit → the helper already printed the correct
  user-facing message. Just stop; do not add your own auth/access explanation.
- Non-actionable status, or an epic-child argument → report and stop (per Step 1).
- Underspecified task → ask sharp questions or suggest `/q-task-refine`; do not guess.
- **Never build an unapproved payload.** No `scopeApprovedAt`, no build — for a single
  unit as much as for an epic.
- Epic: create **nothing** until the graph is DAG-validated **and** the user explicitly
  approves. One-level decomposition only.
- A failed child must never cascade: independent siblings keep running, dependents wait,
  the dispatcher never thrashes. Stop the `/loop` at the fixpoint.
- Never hardcode `feature/` — construct every branch from `branchPrefix`.
- Never print or echo the bearer token. Never run `set -x` / `curl -v` around `qapi`.
  Build every JSON payload with `node` / `JSON.stringify`, never `echo`.
