---
description: Vet, classify, and build one Quetrex task end to end. Splits at the human scope gate — a PLAN half that produces the architect's plan and asks for approval, and a BUILD half that a routine can run unattended from the approved payload. Single unit for a feature/bug, or one-level epic decomposition with a DAG of child workflows that auto-merge into a per-epic integration branch. Usage: /quetrex:task-build SMA-1 [--build-only|--tick]
argument-hint: <TASK-ID like SMA-1> [--build-only | --tick]
---

# quetrex:task-build

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

- `/quetrex:task-build SMA-1` — plan half → scope gate → build half on approval.
- `/quetrex:task-build SMA-1 --build-only` — build half **only**, against an already-approved
  payload. This is the entry point an automated trigger uses; it refuses to run if the
  payload is missing or unapproved.
- `/quetrex:task-build SMA-1 --tick` — run exactly **one** epic dispatch tick and exit. Used by
  `/loop` (step 6B); harmless to run by hand.

THE DEV PIPELINE itself is defined **once** in `.claude/lib/dev-pipeline.md` and is **not**
restated here. This command is the lean intake + gate + dispatcher; the heavy work runs
unattended — a standalone task's BUILD half as a fired cloud Routine
(`.claude/lib/cloud-build-routine.md`), an epic child's as a background Workflow-tool run —
so the terminal stays free either way.

All kanban I/O goes through the token-safe `quetrex-api` tool (shipped on the plugin's PATH —
raw `quetrex-api <METHOD> <path> [body]` calls plus the `quetrex-api task-*` / `create-child` /
`add-dep` / `is-unblocked` subcommands): never echo the token, never `set -x` / `curl -v` around
`quetrex-api`, always build JSON with `node` / `JSON.stringify`.

Argument: `$ARGUMENTS` is a task identifier (`SMA-1`) plus an optional mode flag.

---

## Step 1 — Parse, resolve, fetch

```bash
TASK_ID="$(echo "$ARGUMENTS" | tr -d '[:space:]' | sed 's/--.*$//')"
MODE="full"
case "$ARGUMENTS" in *--build-only*) MODE="build" ;; *--tick*) MODE="tick" ;; esac
```

If `TASK_ID` is empty, print usage and stop:

> Usage: `/quetrex:task-build SMA-1 [--build-only | --tick]`

Resolve context in one bash block — the `quetrex-api` tool (shipped on the plugin's PATH) owns
all auth/access messaging; do not reinvent it. Resolve the **branch prefix** here too: every
branch this command constructs uses it.

```bash
QX_KANBAN_URL="$(quetrex-api kanban-url)"     || exit 1   # prints "Run /quetrex:login" on failure
QX_PROJECT_CODE="$(quetrex-api project-code)" || exit 1   # prints "Run /quetrex:init" on failure
quetrex-api GET "/api/projects/$QX_PROJECT_CODE" >/dev/null || exit 1   # validate access
TASK="$(quetrex-api GET "/api/tasks/$TASK_ID")" || exit 1

REPO_ROOT="$(git rev-parse --show-toplevel)"
# Branch prefix: NEVER hardcode one. It is data, read from .quetrex/project.json.
# The default is "claude/" — the only prefix an Anthropic cloud routine can push to
# without a repo admin loosening the branch restriction first.
BRANCH_PREFIX="$(quetrex-api json-get "$REPO_ROOT/.quetrex/project.json" branchPrefix 2>/dev/null || echo 'claude/')"
[ -n "$BRANCH_PREFIX" ] || BRANCH_PREFIX="claude/"

echo "Project: $QX_PROJECT_CODE @ $QX_KANBAN_URL   branchPrefix=$BRANCH_PREFIX"
```

If any context fetch or `quetrex-api` call exits non-zero, the tool already printed the correct
message (401 → `Run /quetrex:login`; 403/404 → `No access — contact your administrator`; other →
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
  through `/quetrex:task-rework` instead — say so and stop.
- If the task is already `pr_ready` / `merged` / `deployed` / `complete`, say so and
  **stop** (avoid duplicate work).
- If the task is already `in_progress`:
  - **a single unit** (no children) → say so and **stop** (its pipeline is already
    running).
  - **an epic that already has children** (persisted `type` is `project`/epic and `$TASK`
    exposes child tasks) → this is a **RESUME**, not duplicate work. Skip the plan half
    entirely (decomposition and approval are one-time and already done) and go to
    **Step 5** in build mode over the existing children. This is the supported path for
    draining dependents that a `/quetrex:task-rework` of a failed child has since unblocked.
- If the task is an **epic child** (`parentTaskId` is set), say: "this is a child of
  `<EPIC-ID>`; run `/quetrex:task-build` on the epic, or `/quetrex:task-rework` on the child" and
  **stop**. `/quetrex:task-build` operates on standalone tasks and epics, not lone children.

---

## Step 2 — Vet + classify

- Read the task **and the repo code** (Glob / Grep / Read) to ground your understanding of
  what the change actually touches.
- If the description is unclear or underspecified, **ask the user** sharp clarifying
  questions (or suggest `/quetrex:task-refine SMA-1`) and wait. Do **not** guess on genuine gaps.
- **Classify** the task as **Project / Feature / Bug** and persist the label:

```bash
quetrex-api task-type "$TASK_ID" "<project|feature|bug>"
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
worktree path into `$UNIT_WT`; Step 4a reads the plan artifact out of it and embeds the
full JSON directly in the payload, so nothing downstream ever depends on that worktree
still being around.

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
  const [file,task,title,kind,prefix,base,children,edges,session,wt] = process.argv.slice(1);
  const planPath = ".quetrex/plan/" + task + ".json";
  // Embed the architect'"'"'s plan artifact directly in the payload (single unit only —
  // an epic has no single plan file at this point). This is what lets Step 6A publish the
  // spec to the cloud routine without ever depending on $UNIT_WT still existing: a
  // compaction, a resumed session, or a --build-only run days later reads planSnapshot
  // straight out of this file, never off a worktree that may be long gone.
  let planSnapshot = null;
  if (wt) {
    try { planSnapshot = JSON.parse(fs.readFileSync(require("path").join(wt, planPath), "utf8")); }
    catch (e) { /* left null; Step 6A refuses to dispatch without it rather than guessing */ }
  }
  const out = {
    task, title, kind,                       // kind: "single" | "epic"
    branchPrefix: prefix,
    baseBranch: base,
    integrationBranch: kind === "epic" ? prefix + task : null,
    planPath,
    worktreePath: wt || null,                // where the plan half worked; reference only
    planSnapshot,                            // full plan JSON, embedded — see note above
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
  "${CHILDREN_JSON:-[]}" "${EDGES_JSON:-[]}" "${CLAUDE_CODE_SESSION_ID:-}" "${UNIT_WT:-}"
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
CHILD_ID="$(quetrex-api create-child "$TASK_ID" "<child title>" "<child desc>")" || exit 1
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
  quetrex-api add-dep "$CH" "$DEP" || exit 1
done
```

Then create the **per-epic integration branch** `${BRANCH_PREFIX}<EPIC-ID>` off `main` via
the `worktree-workflow` skill (use `git -C` so the enforce-branch hook sees the branch).
Finally set the **epic** itself to `in_progress` and post a summary comment:

```bash
quetrex-api task-status "$TASK_ID" in_progress
quetrex-api task-comment "$TASK_ID" "Scope approved. Epic decomposed into N children with M dependency edges; integration branch ${BRANCH_PREFIX}$TASK_ID created. Dispatching ready children."
```

---

# ── SPLIT ── everything below runs unattended

## Step 5 — BUILD HALF entry (and the automated entry point)

Reached three ways: straight on from Step 4c, via `--build-only`, or via the Step 1 resume
path. **Read the payload; carry nothing in from conversation.**

```bash
PAYLOAD="$REPO_ROOT/.quetrex/build/$TASK_ID.json"
[ -f "$PAYLOAD" ] || { echo "No build payload for $TASK_ID — run /quetrex:task-build $TASK_ID to plan and approve scope first." >&2; exit 1; }
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

The BUILD half does not run in this process. Two moves, then this session returns
**immediately** — the terminal stays free and there is nothing left here to poll.

**1. Publish the approved spec to a helper branch.** The plan artifact is already embedded
in the payload (`planSnapshot`, written at 4a) so this step never depends on the plan-half
worktree still existing. Materialize it into a disposable, detached worktree and push it as
its own throwaway branch — never onto the unit branch, never onto `main`:

```bash
SPEC_BRANCH="quetrex-spec/$TASK_ID"
PLAN_JSON="$(node -e '
  const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  if(!p.planSnapshot){ console.error("No embedded plan snapshot in the payload — run the plan half again."); process.exit(1); }
  process.stdout.write(JSON.stringify(p.planSnapshot));
' "$PAYLOAD")" || exit 1
BASE_BRANCH_FOR_SPEC="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).baseBranch)' "$PAYLOAD")"

TMP_WT="$(mktemp -d)"
git -C "$REPO_ROOT" fetch origin "$BASE_BRANCH_FOR_SPEC" --quiet
git -C "$REPO_ROOT" worktree add --detach --quiet "$TMP_WT" "origin/$BASE_BRANCH_FOR_SPEC"
mkdir -p "$TMP_WT/.quetrex/plan"
printf '%s\n' "$PLAN_JSON" > "$TMP_WT/.quetrex/plan/$TASK_ID.json"
# Stamp the APPROVED base sha into the plan the cloud session will read. This
# worktree is detached at `origin/$BASE_BRANCH_FOR_SPEC` (fetched two lines up), so
# the spec commit's parent IS the sha the human approved — quetrex-plan-stamp
# resolves that same ref and records it as `base_sha`. WHY IT MATTERS: a routine
# gets no ref parameter (the platform clones "the default branch" and reuses a
# filesystem SNAPSHOT of the environment), so a run can silently start BEHIND the
# approved base — #318/#319/#321 were all parented on Aug-4 `main` and spent the run
# opening housekeeping PRs to unblock themselves. With the sha recorded, the run can
# tell a stale environment (base behind ⇒ transport_failure) from a base that
# legitimately moved ahead (⇒ proceed and record what it used). WHY AN EXECUTABLE:
# prose in a command file is model-instructions, not guaranteed execution, and a
# stamp that silently does not happen leaves the routine trusting the handed
# checkout — the exact root cause. It fails loudly instead.
quetrex-plan-stamp "$TMP_WT/.quetrex/plan/$TASK_ID.json" "$REPO_ROOT" "$BASE_BRANCH_FOR_SPEC" || exit 1
git -C "$TMP_WT" checkout -q -b "$SPEC_BRANCH"
git -C "$TMP_WT" add -f ".quetrex/plan/$TASK_ID.json"
git -C "$TMP_WT" -c user.name='quetrex-bot' -c user.email='quetrex-bot@users.noreply.github.com' \
  commit -q -m "chore(spec): $TASK_ID build payload for cloud routine"
git -C "$TMP_WT" push -f origin "$SPEC_BRANCH"
git -C "$REPO_ROOT" worktree remove "$TMP_WT" --force
```

The spec branch carries **only** `.quetrex/plan/<TASK_ID>.json` — that file is git-ignored
everywhere else (`.quetrex/*` minus `project.json`/`verify.json`), which is exactly why a
normal push never carries it and this dedicated branch is the only way the zero-context
cloud session receives the human-approved spec.

**2. Fire the cloud Routine via the `RemoteTrigger` tool.** `RemoteTrigger` is a **tool**,
not a CLI — this file is read as model-instructions, and this step is an instruction to
invoke that tool directly, not a shell command. Build its body exactly as
`.claude/lib/cloud-build-routine.md` documents:

```bash
EVENT_UUID="$(uuidgen | tr 'A-Z' 'a-z')"
RUN_AT="$(date -u -v+2M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+2 minutes' +%Y-%m-%dT%H:%M:%SZ)"
REPO_URL="$(git -C "$REPO_ROOT" remote get-url origin | sed -E 's#^git@([^:]+):#https://\1/#; s#\.git$##')"
TASK_TITLE="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).title)' "$PAYLOAD")"
```

The five-name substitution list in the next paragraph is the **single authority** for what
gets filled, and it is a **checked contract** with the placeholder table at the top of
`.claude/lib/cloud-build-routine.md` (:13-22), not documentation: `test/placeholder-substitution.test.sh`
asserts every placeholder appearing anywhere in that template is named here, and that the
table names exactly this set — because a template placeholder this list forgot once shipped
to the cloud unfilled, the run pushed its gate evidence to a branch named after the literal
unsubstituted text, and `/quetrex:merge` found nothing on every single run.

Load `.claude/lib/cloud-build-routine.md`, substitute its `{{TASK}}`, `{{REPO_URL}}`,
`{{SPEC_BRANCH}}`, `{{BASE_BRANCH}}`, `{{BRANCH_PREFIX}}` placeholders with `$TASK_ID`,
`$REPO_URL`, `$SPEC_BRANCH`, `$BASE_BRANCH_FOR_SPEC`, and the payload's `branchPrefix`, and
use the filled text verbatim as the event's `message.content`. Then call the tool,
`action:"create"` then `action:"run"`, with a body of this exact shape:

```json
{
  "name": "<TASK_ID> · <title> (cloud build)",
  "run_once_at": "<RUN_AT>",
  "enabled": true,
  "job_config": {
    "ccr": {
      "environment_id": "env_011CUpkAEM4fzsAD6dx1zW3r",
      "session_context": {
        "model": "claude-sonnet-5",
        "sources": [{ "git_repository": { "url": "<REPO_URL>" } }],
        "allowed_tools": ["Bash", "Read", "Write", "Edit", "Glob", "Grep", "Task"]
      },
      "events": [{
        "data": {
          "uuid": "<EVENT_UUID>",
          "session_id": "",
          "type": "user",
          "parent_tool_use_id": null,
          "message": { "role": "user", "content": "<the filled cloud-build-routine.md prompt>" }
        }
      }]
    }
  }
}
```

`allowed_tools` is intentionally the minimum the pipeline needs — do not widen it. Never
place a bearer token or any other secret in `name`, `message.content`, or anywhere else in
this body: the CCR authenticates to GitHub with its own credentials, never one this session
hands it.

**3. Return immediately.** Take the routine id the tool returns and report the **monitor
URL** — `https://claude.ai/code/routines/{id}` — to the user, along with the spec branch and
that the routine is building toward `pr_ready`. Do not wait for it, do not poll it, do not
parse its output. Then go to **Step 7**.

### B) Epic — DAG dispatch as a `/loop` tick

The dispatcher is **stateless by construction**: the kanban is the state of truth (status
+ dependencies + `isBlocked`) and readiness is recomputed from the API every tick, so
nothing has to survive between ticks. That is what makes it safe to run as an interval
loop instead of an in-session poll that quietly depends on the session staying alive.

Run **one tick inline** first (so work starts now, not one interval from now), then arm the
loop at the payload's `tickIntervalMinutes` — **2–5 minutes**. Children are multi-minute
units; anything faster is pure API noise, and anything slower wastes the DAG's parallelism.

```
/loop 3m /quetrex:task-build <EPIC-ID> --tick
```

That is a slash command, not shell. Stop the loop at the fixpoint (step 4 below).

**One tick** (this is all `--tick` does — do exactly this, then exit):

1. **Compute the ready set** — children not yet started whose dependencies are all
   `DONE_FOR_UNBLOCKING = {merged, deployed, complete}`:

   ```bash
   quetrex-api is-unblocked "<child-id>"   # exit 0 = ready, 1 = still blocked
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
   (`quetrex-api task-status "<child-id>" merged`); that unblocks its dependents, which the next
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

The heavy work — every unit's DEV PIPELINE — runs unattended, out of this session: a
standalone task's BUILD half as a **fired cloud Routine** (Step 6A), an epic child's as a
**background Workflow-tool run** (Step 6B). You never parse either's stdout inline.

**Single unit.** Fire-and-forget: already reported in Step 6A — the monitor URL
(`https://claude.ai/code/routines/{id}`), the spec branch, and that the routine is building
toward `pr_ready`. The pipeline's terminus is an open PR. Whether it then merges
is decided by the reviewer's verdict and enforced by `merge-gate.sh` — `AUTO_MERGE` pinned
to HEAD with a green ledger permits the squash merge; `REWORK` / `ESCALATE_HUMAN` sends the
task to `needs_clarity` for `/quetrex:task-rework`. The merge itself is **`/quetrex:merge <TASK-ID>`**, and you should tell the user to run
it. It is not a bypass: the cloud build publishes its gate artifacts to
`<branchPrefix><TASK>-gates` (see `.claude/lib/cloud-build-routine.md` step 5b), and
`/quetrex:merge` fetches them, proves they are pinned to the PR head, and then merges
through the same `merge-gate.sh` that has always run. Without that transport step the gate
finds no verdict on the operator machine and denies every merge — which is why merging used
to happen by hand on GitHub, and why the post-merge bookkeeping (status -> `merged`, branch
and worktree teardown) never ran.

**Epic, at the fixpoint.** Partition the children:

- **All children `merged`** → open the single **integration → main PR**
  (`${BRANCH_PREFIX}<EPIC-ID>` → `main`) via the `git-workflow` agent or
  `gh pr create --base main --head "${BRANCH_PREFIX}<EPIC-ID>"`, so the merge gate has a
  PR to act on. That PR is the epic's terminus; it merges under the same `merge-gate.sh`
  rules as any other. Leave the epic `in_progress` until it merges, then
  `quetrex-api task-status <EPIC-ID> merged`. (Every child branch was deleted on its auto-merge, so
  the integration branch is the only one carrying the epic id.)

- **Any child `needs_clarity`, or blocked-waiting on one** → do **NOT** open the
  integration PR. Report exactly which children **failed** and which are
  **blocked-waiting** on a failed dependency. The user runs **`/quetrex:task-rework <child>`** on
  each failure; on pass it auto-merges into the integration branch and **unblocks** its
  dependents. Re-running **`/quetrex:task-build <EPIC-ID>`** then resumes the dispatcher (Step 1
  resume path → Step 5) and drains the now-eligible dependents. Only when every child is
  `merged` is the integration → main PR opened. The epic stays `in_progress` throughout.

Point the user to `/workflows` and the board for live progress. Do **not** parse workflow
output inline.

---

## Error-handling rules

- Any `quetrex-api` or resolver non-zero exit → the helper already printed the correct
  user-facing message. Just stop; do not add your own auth/access explanation.
- Non-actionable status, or an epic-child argument → report and stop (per Step 1).
- Underspecified task → ask sharp questions or suggest `/quetrex:task-refine`; do not guess.
- **Never build an unapproved payload.** No `scopeApprovedAt`, no build — for a single
  unit as much as for an epic.
- Epic: create **nothing** until the graph is DAG-validated **and** the user explicitly
  approves. One-level decomposition only.
- A failed child must never cascade: independent siblings keep running, dependents wait,
  the dispatcher never thrashes. Stop the `/loop` at the fixpoint.
- Never hardcode a branch prefix — construct every branch from `branchPrefix`.
- Never print or echo the bearer token. Never run `set -x` / `curl -v` around `quetrex-api`.
  Build every JSON payload with `node` / `JSON.stringify`, never `echo`.
- Never place a bearer token, API key, or any other secret in the `RemoteTrigger` body
  (Step 6A) — not in `name`, not in `message.content`, nowhere. The CCR authenticates to
  GitHub with its own credentials, never one this session hands it. The spec branch it
  reads (`quetrex-spec/<TASK_ID>`) carries only the plan JSON — never a credential.
