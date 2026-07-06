---
description: Vet, classify, and build one Quetrex task end to end — a single-unit dev pipeline for a feature/bug, or one-level epic decomposition with a human-approved DAG of child workflows that auto-merge into a per-epic integration branch. Usage: /quetrex-task-build SMA-1
argument-hint: <TASK-ID like SMA-1>
---

# Que Task

Take one kanban task from intake to open PR(s). Vet it against the repo, **classify** it
(Project / Feature / Bug), then either:

- **Feature / Bug → single unit:** run THE DEV PIPELINE once, PR into `main`; or
- **Project / Epic → decompose ONE LEVEL** into child cards + a dependency graph, get
  **explicit human approval**, materialize the children + dependencies, open a **per-epic
  integration branch**, then **DAG-dispatch** the eligible children as parallel background
  workflows that auto-merge into the integration branch — finishing with **one human merge** of
  the integration branch into `main`.

THE DEV PIPELINE itself is defined **once** in `.claude/lib/dev-pipeline.md` and is **not**
restated here. This command is the lean intake + dispatcher; the heavy work runs in background
Workflow-tool runs so the terminal stays free.

All kanban I/O goes through the token-safe helpers in `.claude/lib/quetrex-api.sh`
(`qapi` + the `qx_*` wrappers): never echo the token, never `set -x` / `curl -v` around `qapi`,
always build JSON with `node` / `JSON.stringify`.

Argument: `$ARGUMENTS` is a single human task identifier, e.g. `SMA-1`.

---

## Step 1 — Parse, resolve, fetch

```bash
TASK_ID="$(echo "$ARGUMENTS" | tr -d '[:space:]')"
```

If `TASK_ID` is empty, print usage and stop:

> Usage: `/quetrex-task-build SMA-1`

Source the helper and resolve context in one bash block — the helper owns all auth/access
messaging; do not reinvent it:

```bash
source ~/.claude/lib/quetrex-api.sh
resolve_auth    || exit 1      # prints "Run /quetrex-login" on failure
resolve_project || exit 1      # prints "Run /quetrex-init" on failure
qapi GET "/api/projects/$QX_PROJECT_CODE" >/dev/null || exit 1   # validate access
TASK="$(qapi GET "/api/tasks/$TASK_ID")" || exit 1
echo "Project: $QX_PROJECT_CODE @ $QX_KANBAN_URL"
```

If any resolver or `qapi` call exits non-zero, the helper already printed the correct message
(401 → `Run /quetrex-login`; 403/404 → `No access — contact your administrator`; other →
`Quetrex API error (HTTP <code>)`). Just stop.

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

- Actionable starting statuses: `backlog`, `queued`. A `needs_clarity` task should go through
  `/quetrex-task-rework` instead — say so and stop.
- If the task is already `pr_ready` / `merged` / `deployed` / `complete`, say so and **stop**
  (avoid duplicate work).
- If the task is already `in_progress`:
  - **a single unit** (no children) → say so and **stop** (its pipeline is already running).
  - **an epic that already has children** (its persisted `type` is `project`/epic and `$TASK`
    exposes child tasks) → this is a **RESUME**, not duplicate work. Skip decomposition +
    approval (those are one-time, already done) and go straight to **DAG dispatch** (Step 3 B.4)
    over the existing children. This is the supported path for draining dependents that a
    `/quetrex-task-rework` of a failed child has since unblocked.
- If the task is an **epic child** (`parentTaskId` is set), say: "this is a child of
  `<EPIC-ID>`; run `/quetrex-task-build` on the epic, or `/quetrex-task-rework` on the child" and **stop**. `/quetrex-task-build`
  operates on standalone tasks and epics, not lone children.

---

## Step 2 — Vet + classify

- Read the task **and the repo code** (Glob / Grep / Read) to ground your understanding of what
  the change actually touches.
- If the description is unclear or underspecified, **ask the user** sharp clarifying questions
  (or suggest `/quetrex-task-refine SMA-1`) and wait. Do **not** guess on genuine gaps.
- **Classify** the task as **Project / Feature / Bug** and persist the label:

```bash
qx_task_type "$TASK_ID" "<project|feature|bug>"
```

---

## Step 3 — Decide single vs epic

### A) FEATURE / BUG → single unit

Run **THE DEV PIPELINE once**, exactly as defined in `.claude/lib/dev-pipeline.md`, with these
inputs (do not restate the steps):

- `TASK_ID` = `$TASK_ID`
- `TASK_TITLE` = the task title
- `BASE_BRANCH` = `main`
- `WORKFLOW_TITLE` = `"$TASK_ID · <title>"`
- the resolved kanban context (`QX_KANBAN_URL`, `QX_PROJECT_CODE`)

The PR targets `main`. Dispatch the workflow in the **background**. The engine drives
`in_progress → pr_ready` (or `needs_clarity` on bounded-loop exhaustion). The human merges later
with `/quetrex-task-merge $TASK_ID`. Then go to **Step 4**.

### B) PROJECT / EPIC → decompose

**0. Resume short-circuit.** If you arrived here via the Step 1 **resume** path (the epic already
has children), do **not** re-decompose and do **not** re-ask for approval — those are one-time.
The integration branch `feature/<EPIC-ID>` already exists. Jump straight to **B.4 (DAG dispatch)**
over the existing children. A resume is idempotent: it skips children already `in_progress` /
`merged` / `needs_clarity` and only launches newly-eligible ones.

**1. Decompose — ONE LEVEL ONLY.** Plan the epic into a set of **child units** — no
grandchildren (this keeps child identifiers `CODE-N.C` collision-free) — with a **dependency
graph** (edges between children). Ground the decomposition in an architect-grade read of the
repo: each child must be an independently buildable, file-disjoint slice.

**2. Present the plan + get EXPLICIT human approval.** Show:
- the proposed child cards — title + one-line scope each, and
- the dependency edges in plain language (e.g. "C3 depends on C1, C2").

**Validate the proposed graph is a DAG (no cycles) before asking.** Build the edge list and
check it with `node` (topological sort / cycle detection) — do not write anything to the kanban
until this passes and the user **explicitly approves**:

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

Iterate on the plan with the user if they tweak it (re-validate after each change). **Create
nothing** until they explicitly approve.

**3. On approval — materialize.** In order:

```bash
# a) Create each child; collect its returned identifier (CODE-N.C).
CHILD_ID="$(qx_create_child "$TASK_ID" "<child title>" "<child desc>")" || exit 1
# ...repeat per child, mapping your plan label (C1, C2, …) -> CHILD_ID.

# b) Add each dependency edge (graph already DAG-validated; server is also cycle-safe).
qx_add_dep "<child-id>" "<dependsOn-id>" || exit 1
# ...repeat per edge.
```

Then create the **per-epic integration branch** `feature/<EPIC-ID>` off `main` via the
`worktree-workflow` skill (use `git -C` so the enforce-branch hook sees the branch). Finally,
set the **epic** itself to `in_progress` and post a summary comment:

```bash
qx_task_status "$TASK_ID" in_progress
qx_task_comment "$TASK_ID" "Epic decomposed into N children with M dependency edges; integration branch feature/$TASK_ID created. Dispatching ready children."
```

**4. DAG dispatch (concurrency cap ≈ 3–5).** This command is the lean dispatcher — it does
**not** run any pipeline inline; the heavy work is the background child workflows. Use a
continuous in-session dispatcher pattern: the **kanban is the state of truth** (status +
dependencies + `isBlocked`), polled between ticks.

Loop:

- **Compute the ready set** — children not yet started whose dependencies are all
  `DONE_FOR_UNBLOCKING = {merged, deployed, complete}`. Use the readiness predicate:

  ```bash
  qx_is_unblocked "<child-id>"   # exit 0 = ready, 1 = still blocked
  ```

  Prefer the server's `isBlocked` flag; the helper falls back to checking dependency statuses.

- **Launch up to the cap.** Count children currently `in_progress` (in-flight) and launch ready
  children only up to `cap − in_flight` (cap ≈ 3–5 running at once). For each, launch **its own
  named Workflow-tool run** titled `"<EPIC-ID> · <unit name>"`, running
  THE DEV PIPELINE (`.claude/lib/dev-pipeline.md`) with:
  - `TASK_ID` = the child id,
  - `TASK_TITLE` = the child title,
  - `BASE_BRANCH` = `feature/<EPIC-ID>` (the integration branch),
  - `WORKFLOW_TITLE` = `"<EPIC-ID> · <unit name>"`.

  The child PR targets the **integration branch**, not `main`. Dispatch in the background; the
  engine marks the child `in_progress` as its first action.

- **Auto-merge on pass.** When a child's pipeline reaches **review-approved + green**, its PR is
  **squash-auto-merged into the integration branch** — this is the one place auto-merge is
  allowed, because it merges into the integration branch, **never** `main`. On merge, set the
  child to `merged` (`qx_task_status "<child-id>" merged`). Auto-merge **unblocks dependents** →
  re-poll `isBlocked` / `qx_is_unblocked` and refill the ready set.

- **Failed child → `needs_clarity`.** The engine already wrote the AI-note and set the child to
  `needs_clarity` on exhaustion. Its **independent siblings keep running**; its **dependents
  WAIT** (they stay blocked — never auto-`needs_clarity` a dependent by association).

- **Repeat** the dispatch tick — re-poll the kanban, refill the ready set, launch newly-eligible
  children — until the DAG reaches a **fixpoint**: **no child is in-flight (`in_progress`)** AND
  **the ready set is empty**. This is the bounded terminus and it **always** terminates: each tick
  a child either advances toward `merged` / `needs_clarity` or there is simply nothing left to
  launch. **Do not spin** on children that can never become ready — a child whose dependency is
  `needs_clarity` is **permanently blocked until the human reworks that dependency**, so it is part
  of the fixpoint, not a reason to keep polling. (This dispatcher polls **in this session**;
  the heavy work is the background child workflows, so the session stays light.)

**Epic terminus (fixpoint reached).** Partition the children:

- **All children `merged`** → the epic is ready for **ONE human merge**. Open the single
  **integration → main PR** (`feature/<EPIC-ID>` → `main`) now — via the `git-workflow` agent or
  `gh pr create --base main --head feature/<EPIC-ID>` — so the human merge gate has a PR to act on.
  Then point the user at **`/quetrex-task-merge <EPIC-ID>`**, which reviews + squash-merges that PR and
  sets the epic `merged`. Leave the epic `in_progress` until that PR merges. (Every child branch was
  already deleted on its auto-merge, so `feature/<EPIC-ID>` is the only branch carrying the epic id
  — no `/quetrex-task-merge` ambiguity.)

- **Any child `needs_clarity` (or blocked-waiting on one)** → do **NOT** open the integration PR.
  Report exactly which children **failed** (`needs_clarity`) and which are **blocked-waiting** on a
  failed dependency. The user runs **`/quetrex-task-rework <child>`** on each failure; on pass it auto-merges
  into the integration branch and **unblocks** its dependents. Then re-running **`/quetrex-task-build
  <EPIC-ID>`** **resumes** the dispatcher (Step 1 resume path) and drains the now-eligible
  dependents. Only when every child is `merged` is the integration → main PR opened. The epic stays
  `in_progress` throughout.

---

## Step 4 — Report

The heavy work — every unit's DEV PIPELINE — runs in **background** Workflow-tool runs; you never
parse their stdout. Report:

- **Single unit:** fire-and-forget — the one workflow title and that it is building toward
  `pr_ready`; remind the user to `/quetrex-task-merge $TASK_ID` when the PR is green + approved. Then exit;
  the terminal stays free.
- **Epic:** the **DAG dispatcher itself runs in this session** (it polls the kanban between ticks)
  until the fixpoint in Step 3 B.4. While it runs, report the integration branch,
  the N children + M dependency edges, and which children **started** vs **waiting** (and on what).
  At the fixpoint, report the terminus partition (all `merged` → integration PR opened, hand off to
  `/quetrex-task-merge <EPIC-ID>`; else which children are `needs_clarity` / blocked-waiting and the
  `/quetrex-task-rework <child>` → `/quetrex-task-build <EPIC-ID>` resume path), then exit.

Point the user to `/workflows` and the board for live progress. Do **not** parse workflow output
inline.

---

## Error-handling rules

- Any `qapi` or resolver non-zero exit → the helper already printed the correct user-facing
  message. Just stop; do not add your own auth/access explanation.
- Non-actionable status, or an epic-child argument → report and stop (per Step 1).
- Underspecified task → ask sharp questions or suggest `/quetrex-task-refine`; do not guess.
- Epic: create **nothing** until the graph is DAG-validated **and** the user explicitly
  approves. One-level decomposition only.
- A failed child must never cascade: independent siblings keep running, dependents wait, the
  dispatcher never thrashes.
- Never print or echo the bearer token. Never run `set -x` / `curl -v` around `qapi`. Build every
  JSON payload with `node` / `JSON.stringify`, never `echo`.
