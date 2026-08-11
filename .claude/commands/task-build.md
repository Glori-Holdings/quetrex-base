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
  payload is missing or unapproved, **and it runs the same actionability guard the full mode
  runs** (Step 1) — a task that is already `merged`/`deployed`/`complete`, or that has a
  cloud routine in flight right now, must never be re-dispatched from a stale payload.
- `/quetrex:task-build SMA-1 --tick` — run exactly **one** epic dispatch tick and exit. Used by
  `/loop` (step 6B); harmless to run by hand.

THE DEV PIPELINE itself is defined **once** in `.claude/lib/dev-pipeline.md` and is **not**
restated here. This command is the lean intake + gate + dispatcher; **all** heavy work runs
unattended on Anthropic's servers as a fired cloud Routine
(`.claude/lib/cloud-build-routine.md`) — a standalone task as one routine (Step 6A), and
**each epic child as its own routine of exactly the same shape** (Step 6B). Nothing this
command dispatches needs the operator's session, terminal, or laptop to stay alive.

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

### 1a. Resolve the cloud environment — fail here, not after the human has approved

Every dispatch this command makes (Step 6A for a single unit, Step 6B for each epic child)
fires into a **Claude Code cloud environment**, and that environment belongs to the operator's
own account. It is therefore **data, exactly like `branchPrefix`** — read from the repo
binding, never a literal in this file. A hardcoded id silently dispatches one account's build
into another account's environment: no board change, no PR, no notification, and a card that
sits in `in_progress` forever with nothing to diagnose from. Resolve it **now**, before the
plan half spends the operator's time, so a missing binding is a one-line fix and not a wasted
approval.

```bash
# ── quetrex:exec-block qx_cloud_env_id ─────────────────────────────────────────
# Executable, and executed: test/task-build-guards.test.sh sources this exact
# block and drives the function. Pure function of (repo root, environment) —
# no network, no kanban call.
qx_cloud_env_id() {            # qx_cloud_env_id <repo-root>
  local root="$1" id=""
  id="$(quetrex-api json-get "$root/.quetrex/project.json" cloudEnvironmentId 2>/dev/null || true)"
  [ -n "$id" ] || id="${QUETREX_CLOUD_ENVIRONMENT_ID:-}"
  if [ -z "$id" ]; then
    echo "No cloud environment is bound to this repo, so there is nowhere to run the build." >&2
    echo "Open https://claude.ai/code, pick (or create) the environment this repo should build in," >&2
    echo "copy its id from the URL (it looks like env_0123ABC…), and record it in the binding:" >&2
    echo "    node -e 'const f=\"$root/.quetrex/project.json\",fs=require(\"fs\");const o=JSON.parse(fs.readFileSync(f,\"utf8\"));o.cloudEnvironmentId=process.argv[1];fs.writeFileSync(f,JSON.stringify(o,null,2)+\"\\n\")' env_YOURID" >&2
    echo "(or export QUETREX_CLOUD_ENVIRONMENT_ID for a one-off run). Then re-run this command." >&2
    return 1
  fi
  case "$id" in
    env_*[!A-Za-z0-9_]* | env_) echo "cloudEnvironmentId is not a well-formed environment id: $id" >&2; return 1 ;;
    env_*) ;;
    *) echo "cloudEnvironmentId must be a Claude Code environment id starting with 'env_' — got: $id" >&2; return 1 ;;
  esac
  printf '%s\n' "$id"
}
# ── end quetrex:exec-block qx_cloud_env_id ────────────────────────────────────

QX_CLOUD_ENV_ID="$(qx_cloud_env_id "$REPO_ROOT")" || exit 1
```

Do **not** invent a provisioning call to create the environment: there is no verified API for
that, and guessing one turns a clear "bind it once" message into a silent failure. Recording
the id is a one-time per-repo act, exactly like `branchPrefix`.

### 1b. Read the task and run the actionability guard — in EVERY mode

Read the fields from `$TASK` **into shell variables** — the guard below is code, so its
inputs have to be values, not something recalled from the conversation:

```bash
PAYLOAD="$REPO_ROOT/.quetrex/build/$TASK_ID.json"

# One field per call — no `eval`, so a title containing a quote can never become
# shell syntax. `|| true`: an absent field is empty, not an error.
qx_task_field() {              # qx_task_field <task-json> <field>
  node -e '
    let o; try{o=JSON.parse(process.argv[1])}catch{process.exit(1)}
    const v=o[process.argv[2]];
    process.stdout.write(v==null?"":String(v));
  ' "$1" "$2"
}
STATUS="$(qx_task_field "$TASK" status)"          || exit 1
TASK_TITLE="$(qx_task_field "$TASK" title)"       || exit 1
PARENT_TASK_ID="$(qx_task_field "$TASK" parentTaskId)" || true
# KIND is "epic" ONLY for a persisted project/epic that already exposes children;
# an undecomposed project is still planned as one, at Step 3B.
KIND="$(node -e '
  let o; try{o=JSON.parse(process.argv[1])}catch{process.exit(1)}
  const n = Array.isArray(o.children) ? o.children.length
          : Array.isArray(o.childTasks) ? o.childTasks.length : 0;
  process.stdout.write(((o.type==="project"||o.type==="epic") && n>0) ? "epic" : "single");
' "$TASK")" || exit 1
echo "Task $TASK_ID: status=$STATUS kind=$KIND mode=$MODE"
```

**Actionability guard — it runs in `full`, `build` AND `tick` mode.**

`--build-only` used to skip Step 1 entirely and enter at Step 5, whose only gate is the
payload's `scopeApprovedAt`. Since **nothing ever deletes** `.quetrex/build/<TASK>.json`, that
made "re-fire a task that was merged last week" a single keystroke — a second PR for landed
work, or two runs racing on one branch namespace (`quetrex-spec/<TASK>`, the unit branch and
`<prefix><TASK>-gates` are all single-named, and the gates branch's last writer wins, after
which `/quetrex:merge` reports STALE EVIDENCE for a PR that was in fact built correctly).
**The board is the state of truth and it is cheap to ask**, so every mode asks.

The verdict is computed, not remembered:

```bash
# ── quetrex:exec-block qx_actionability ────────────────────────────────────────
# Executable, and executed: test/task-build-guards.test.sh sources this exact
# block and drives the function across every status × mode. Pure function of
# (status, kind, mode, payload file) — no network.
#
# Prints "<VERDICT> — <reason>". Returns 0 to go on, 1 to stop.
#   PROCEED    plan/build normally
#   RESUME     epic already decomposed+approved: skip the plan half, go to Step 5
#   RESUMABLE  single unit sitting in_progress with NOTHING in flight — the scope
#              gate was declined, abandoned, or the session died. Re-enter the
#              plan half (Step 2 if there is no payload, Step 4b if there is an
#              unapproved one). This is NOT "already running".
#   REDISPATCH pr_ready + build/tick: the documented repair path when the gates
#              are stale (see .claude/commands/merge.md) — allowed, and loud.
#   REFUSE     stop.
qx_actionability() {           # qx_actionability <status> <single|epic> <full|build|tick> <payload-file>
  local status="$1" kind="$2" mode="$3" payload="$4"
  local approved="" dispatched="" monitor=""
  if [ -f "$payload" ]; then
    approved="$(quetrex-api json-get "$payload" scopeApprovedAt 2>/dev/null || true)"
    dispatched="$(quetrex-api json-get "$payload" dispatch.dispatchedAt 2>/dev/null || true)"
    monitor="$(quetrex-api json-get "$payload" dispatch.monitorUrl 2>/dev/null || true)"
  fi
  case "$status" in
    backlog|queued)
      echo "PROCEED — $status is an actionable starting status"; return 0 ;;
    needs_clarity)
      echo "REFUSE — needs_clarity: run /quetrex:task-rework on it, not /quetrex:task-build"; return 1 ;;
    merged|deployed|complete)
      echo "REFUSE — already $status: this work has landed. Re-dispatching would open a SECOND PR for it. If the change needs more work, create a new task; if this payload is stale, it is safe to delete $payload"; return 1 ;;
    pr_ready)
      if [ "$mode" = "full" ]; then
        echo "REFUSE — already pr_ready: its PR is open and waiting on /quetrex:merge $TASK_ID (or /quetrex:task-rework if the reviewer sent it back)"; return 1
      fi
      echo "REDISPATCH — pr_ready + --$mode: re-publishing the build so the gate evidence is re-pinned to the current head (merge.md's documented stale-evidence repair). The existing PR is reused, not duplicated"; return 0 ;;
    in_progress)
      if [ "$kind" = "epic" ]; then
        echo "RESUME — epic already decomposed and approved: skipping the plan half and draining the DAG"; return 0
      fi
      if [ -n "$approved" ] && [ -n "$dispatched" ]; then
        echo "REFUSE — a cloud routine for $TASK_ID is in flight (dispatched $dispatched)${monitor:+ — watch it at $monitor}. Wait for it to reach pr_ready, or rework it; do not fire a second run at the same branch namespace"; return 1
      fi
      echo "RESUMABLE — in_progress but NOTHING is in flight (no dispatch recorded in the payload): the scope gate was declined or abandoned. Re-entering the plan half"; return 0 ;;
    *)
      echo "REFUSE — unrecognised status '$status': refusing to act on a state this command does not model"; return 1 ;;
  esac
}
# ── end quetrex:exec-block qx_actionability ───────────────────────────────────

# KIND: "epic" iff the persisted type is project/epic AND $TASK exposes children.
qx_actionability "$STATUS" "$KIND" "$MODE" "$PAYLOAD" || exit 1
```

Then, whatever the mode:

- **`RESUMABLE`** — say plainly that nothing was running, and continue. In `full` mode that
  means: no payload → go to Step 2 and plan; a payload with `scopeApprovedAt: null` → skip
  straight to **Step 4b** and re-present the scope for approval (the plan is already written;
  do not re-run the architect). In `build`/`tick` mode the unapproved payload still cannot
  build, and Step 5 refuses it — with the accurate reason.
- **`REFUSE`** — print the verdict line verbatim and stop. It already names the way forward.
- **`RESUME`** (epic) or **`REDISPATCH`** — continue.

**If `MODE` is `build` or `tick`, go to Step 5 now** — with the guard above already run.
Those modes read the payload artifact and must never re-plan or re-ask for approval.

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

The pipeline marks the task `in_progress` as its first action — **before** the human has
approved anything. That is fine, and it is deliberately not fought here, precisely because
Step 1's guard now reads `in_progress` + "no dispatch recorded" as `RESUMABLE`: an operator
who declines the gate, closes the laptop, or loses the session can simply run
`/quetrex:task-build <TASK>` again. Never tell such an operator their pipeline is "already
running" — nothing is running until Step 6 records a dispatch.

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

**Every child gets a full architect plan here, not just a title.** Step 6B dispatches each
child to the cloud with the same machinery Step 6A uses for a standalone unit, and a cloud
routine's very first act is to fetch a plan and refuse to build unless it "parses as JSON and
names a non-empty `ownership` map" (`.claude/lib/cloud-build-routine.md`, step 2). A child
carrying only a title would therefore die as a `transport_failure` before writing a line of
code. So run the architect over the decomposition and produce, **per child**, the same
artifact shape `.quetrex/plan/<TASK>.json` has — acceptance criteria with numeric `measure`s,
the strict `ownership` map, `security_surface`, `security_review_required`, and the verify
chain — and carry it in the payload at `children[].plan`. The file-ownership maps of any two
children must be disjoint; that is what makes them safe to run **concurrently in separate
cloud sessions**, which is what Step 6B does.

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

# CHILDREN_JSON (epic only): [{"label":"C1","title":"…","desc":"…","id":null,
#                              "plan":{…the child's full architect plan, Step 3B…}}, …]
#   `plan` is NOT optional: Step 6B publishes it as that child's spec branch and the cloud
#   routine refuses to build without a non-empty `ownership` map.
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
    approvedBaseSha: null,                   // pinned at the FIRST dispatch (6A) and never
                                             // re-resolved — see "the approved base is a
                                             // constant" there. This is what makes a
                                             // re-dispatch survive main moving on.
    dispatch: null,                          // {routineId,monitorUrl,specBranch,baseSha,
                                             //  dispatchedAt} — written by 6A/6B AFTER the
                                             // routine is actually fired. The Step 1 guard
                                             // reads it to tell "in flight" from "wedged".
    children: JSON.parse(children || "[]"),  // [{label,title,desc,id,plan}] — id filled in 4c
    edges: JSON.parse(edges || "[]"),        // label pairs [child, dependsOn]
    edgeIds: [],                             // resolved id pairs, filled in 4c
    childDispatch: {},                       // child-id -> the same dispatch record, from 6B
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
- the proposed child cards — title + one-line scope each, **and the paths each child owns**
  (this is the same file-ownership approval a single unit gets; it is what each child's cloud
  routine is bound to, so it is not a detail to skip),
- the dependency edges in plain language ("C3 depends on C1, C2"),
- the integration branch (`${BRANCH_PREFIX}<EPIC-ID>`) and that children PR into it, not
  `main`.

Then ask for explicit approval of **scope**. This is the tap on Approve. Do not ask about
implementation choices, ordering, or style — those are the pipeline's business.

**Re-entering here.** If Step 1's guard returned `RESUMABLE` with a payload already on disk,
this subsection is where you land — read the plan out of the existing payload, present it,
and ask. Do not re-run the architect, do not re-write the payload, and do not treat the
earlier decline as an error: an unapproved payload is a paused gate, and pausing is allowed.

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

# ── quetrex:exec-block qx_approved_base_sha ────────────────────────────────────
# Executable, and executed: test/task-build-guards.test.sh drives this function
# against a real origin+clone across a moving base branch.
#
# THE APPROVED BASE IS A CONSTANT, NOT A LOOKUP. It is resolved from
# origin/<base> exactly ONCE — at the first dispatch — and then pinned into the
# payload. Every later dispatch of the same task REUSES it.
#
# WHY. `quetrex-cloud-prep sync` resumes the unit branch if it already exists on
# origin (dispatch #1 always leaves one) and then asserts the approved base is an
# ANCESTOR of that resume point. Re-resolving origin/<base> on a re-dispatch
# stamps whatever main has advanced to since — a sha the existing branch cannot
# possibly contain — so sync exits 3 `transport_failure` and does so FOREVER.
# That dead end sits directly under two documented recovery paths: merge.md tells
# the operator to re-run `--build-only` when the gates are stale, and the routine
# promises to "resume from committed work on transport death". Both are unusable
# on any repo where another task merged in the meantime — i.e. any active repo.
# Reusing the approved sha is also the CORRECT semantics: the human approved a
# scope against a specific snapshot, and a resume must not silently re-target.
qx_approved_base_sha() {       # qx_approved_base_sha <payload> <repo-root> <base-branch>
  local payload="$1" root="$2" base="$3" sha=""
  sha="$(quetrex-api json-get "$payload" approvedBaseSha 2>/dev/null || true)"
  if [ -n "$sha" ]; then
    # RE-DISPATCH. Make sure the object is present locally (a prune or a fresh
    # clone can drop it), but never re-resolve the ref.
    if ! git -C "$root" cat-file -e "$sha^{commit}" 2>/dev/null; then
      git -C "$root" fetch --quiet origin "$base" 2>/dev/null || true
      git -C "$root" cat-file -e "$sha^{commit}" 2>/dev/null || \
        git -C "$root" fetch --quiet origin "$sha" 2>/dev/null || true
    fi
    if ! git -C "$root" cat-file -e "$sha^{commit}" 2>/dev/null; then
      echo "The approved base commit $sha is no longer in this repo (force-push, or a fresh clone)." >&2
      echo "The scope was approved against a snapshot that no longer exists, so resuming would silently re-target it." >&2
      echo "Re-run the plan half: /quetrex:task-build $TASK_ID" >&2
      return 1
    fi
    printf '%s\n' "$sha"
    return 0
  fi
  # FIRST DISPATCH. Resolve once, pin it.
  git -C "$root" fetch --quiet origin "$base" || { echo "cannot fetch origin/$base" >&2; return 1; }
  sha="$(git -C "$root" rev-parse --verify --quiet "refs/remotes/origin/$base^{commit}" 2>/dev/null)" || sha=""
  [ -n "$sha" ] || { echo "cannot resolve refs/remotes/origin/$base — refusing to dispatch against an unknown base" >&2; return 1; }
  node -e '
    const fs=require("fs"); const [f,s]=process.argv.slice(1);
    const p=JSON.parse(fs.readFileSync(f,"utf8"));
    p.approvedBaseSha=s;
    fs.writeFileSync(f, JSON.stringify(p,null,2)+"\n");
  ' "$payload" "$sha" || return 1
  printf '%s\n' "$sha"
}
# ── end quetrex:exec-block qx_approved_base_sha ───────────────────────────────

APPROVED_BASE_SHA="$(qx_approved_base_sha "$PAYLOAD" "$REPO_ROOT" "$BASE_BRANCH_FOR_SPEC")" || exit 1

TMP_WT="$(mktemp -d)"
# Detached at the APPROVED SHA, never at whatever origin/<base> is right now, so
# the spec commit's parent IS the snapshot the human approved — on the first
# dispatch and on the tenth.
git -C "$REPO_ROOT" worktree add --detach --quiet "$TMP_WT" "$APPROVED_BASE_SHA"
mkdir -p "$TMP_WT/.quetrex/plan"
printf '%s\n' "$PLAN_JSON" > "$TMP_WT/.quetrex/plan/$TASK_ID.json"
# Stamp the APPROVED base sha into the plan the cloud session will read. WHY IT
# MATTERS: a routine gets no ref parameter (the platform clones "the default
# branch" and reuses a filesystem SNAPSHOT of the environment), so a run can
# silently start BEHIND the approved base — #318/#319/#321 were all parented on
# Aug-4 `main` and spent the run opening housekeeping PRs to unblock themselves.
# With the sha recorded, the run can tell a stale environment (base behind ⇒
# transport_failure) from a base that legitimately moved ahead (⇒ proceed and
# record what it used). WHY AN EXECUTABLE: prose in a command file is model-
# instructions, not guaranteed execution, and a stamp that silently does not
# happen leaves the routine trusting the handed checkout — the exact root cause.
# It fails loudly instead.
#
# `quetrex-plan-stamp` resolves origin/<base> itself, which is right only while
# that ref still IS the approved sha (the first dispatch). On a re-dispatch after
# the base moved it would stamp the new tip and re-create the dead end above, so
# the approved sha is written directly instead. (If the stamp tool grows a
# `--sha <SHA>` flag, collapse this into one unconditional call to it.)
if [ "$(git -C "$REPO_ROOT" rev-parse --verify --quiet "refs/remotes/origin/$BASE_BRANCH_FOR_SPEC^{commit}" 2>/dev/null)" = "$APPROVED_BASE_SHA" ]; then
  quetrex-plan-stamp "$TMP_WT/.quetrex/plan/$TASK_ID.json" "$REPO_ROOT" "$BASE_BRANCH_FOR_SPEC" || exit 1
else
  node -e '
    const fs=require("fs"); const [f,s]=process.argv.slice(1);
    const o=JSON.parse(fs.readFileSync(f,"utf8"));
    o.base_sha=s;
    fs.writeFileSync(f, JSON.stringify(o,null,2)+"\n");
  ' "$TMP_WT/.quetrex/plan/$TASK_ID.json" "$APPROVED_BASE_SHA" || exit 1
  echo "Re-dispatch: reusing the APPROVED base $APPROVED_BASE_SHA (origin/$BASE_BRANCH_FOR_SPEC has moved on since approval)."
fi
# Whichever branch ran, the plan and the spec commit's parent must agree with the
# approved sha. A mismatch here means the base moved between the fetch and the
# stamp — fail loudly rather than ship a spec nobody approved.
STAMPED_BASE="$(quetrex-api json-get "$TMP_WT/.quetrex/plan/$TASK_ID.json" base_sha 2>/dev/null || true)"
[ "$STAMPED_BASE" = "$APPROVED_BASE_SHA" ] || { echo "plan base_sha ($STAMPED_BASE) != approved base ($APPROVED_BASE_SHA) — refusing to publish this spec" >&2; exit 1; }
[ "$(git -C "$TMP_WT" rev-parse HEAD)" = "$APPROVED_BASE_SHA" ] || { echo "spec worktree is not at the approved base — refusing to publish" >&2; exit 1; }
# Stamp Contract A `required_env[]` (see .claude/lib/dev-pipeline.md — "The two
# env shape contracts") into the same plan, deterministically, right here. The
# architect already tried to fill this field, but its frontmatter grants no
# Bash, so it cannot run the shared discovery tool itself — this call is the
# backstop that repairs a miss. WHY IT MATTERS: on QDM-1 the plan shipped with
# no `required_env` at all, `quetrex-cloud-prep hydrate` exported nothing, and
# the cloud build would have died on an unset DEMO_DATABASE_URL; a human hand-
# patched the published spec branch mid-run to rescue it. Union-only: it never
# removes an architect-authored entry, only adds names the architect missed.
quetrex-env-derive plan "$TMP_WT/.quetrex/plan/$TASK_ID.json" "$REPO_ROOT" || exit 1
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

`name` is what the operator sees in the routine list on claude.ai and on the phone — the ONLY
place this run is identified there, so it must be scannable at a glance: `<TASK_ID> <title>`,
plain space, no `·` separator, no `(cloud build)` suffix (a wall of characters nobody recognizes
is worse than useless on a phone-width list). If `<title>` alone would push `name` past ~60
characters, truncate `<title>` to fit (cut to ~50 chars plus a trailing `…`) — never truncate or
drop `<TASK_ID>`, since that is the one token the operator actually keys off.

```json
{
  "name": "<TASK_ID> <title>",
  "run_once_at": "<RUN_AT>",
  "enabled": true,
  "job_config": {
    "ccr": {
      "environment_id": "<QX_CLOUD_ENV_ID>",
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

`environment_id` is `$QX_CLOUD_ENV_ID`, resolved at **Step 1a** from this repo's binding
(`.quetrex/project.json`'s `cloudEnvironmentId`, or `QUETREX_CLOUD_ENVIRONMENT_ID`). It is
**never** a literal in this file: an id baked in here belongs to exactly one account, and for
everyone else it dispatches the build into an environment that is not theirs — a failure with
no board change, no PR and no notification to diagnose from.

`allowed_tools` is intentionally the minimum the pipeline needs — do not widen it. Never
place a bearer token or any other secret in `name`, `message.content`, or anywhere else in
this body: the CCR authenticates to GitHub with its own credentials, never one this session
hands it.

**3. Record the dispatch, then return immediately.** The routine id the tool returns is the
only proof that something is actually running. Write it into the payload **before** reporting
— that record is exactly what Step 1's guard reads to tell a build in flight (refuse a second
one) from a task wedged at a declined scope gate (resume it):

```bash
node -e '
  const fs=require("fs");
  const [file,id,spec,sha]=process.argv.slice(1);
  const p=JSON.parse(fs.readFileSync(file,"utf8"));
  p.dispatch={ routineId:id, monitorUrl:"https://claude.ai/code/routines/"+id,
               specBranch:spec, baseSha:sha, dispatchedAt:new Date().toISOString() };
  fs.writeFileSync(file, JSON.stringify(p,null,2)+"\n");
' "$PAYLOAD" "$ROUTINE_ID" "$SPEC_BRANCH" "$APPROVED_BASE_SHA"
```

Then report the **monitor URL** — `https://claude.ai/code/routines/{id}` — to the user, along
with the spec branch and that the routine is building toward `pr_ready`. Do not wait for it,
do not poll it, do not parse its output. Then go to **Step 7**.

### B) Epic — every child is a cloud Routine; the tick only decides WHO runs next

**Each child is dispatched exactly the way Step 6A dispatches a standalone unit**: its own
spec branch, its own `RemoteTrigger` cloud Routine, its own PR. It is **not** a local
Workflow-tool run. That is not a stylistic preference — an epic is the biggest unit of work
this product supports, and the child compute is the part that must not depend on a laptop
staying open. A `/loop`-driven local Workflow means approving an epic from a phone starts
nothing, and closing the lid strands children half-built with no reaper. Once a child's
routine is fired it runs to its PR whatever happens to this session.

The dispatcher is **stateless by construction**: the kanban is the state of truth (status
+ dependencies + `isBlocked`) and readiness is recomputed from the API every tick, so
nothing has to survive between ticks.

Run **one tick inline** first (so work starts now, not one interval from now), then arm the
loop at the payload's `tickIntervalMinutes` — **2–5 minutes**. Children are multi-minute
units; anything faster is pure API noise, and anything slower wastes the DAG's parallelism.

```
/loop 3m /quetrex:task-build <EPIC-ID> --tick
```

That is a slash command, not shell. Stop the loop at the fixpoint (step 4 below).

**The loop is an accelerator, not a dependency.** Every tick is a pure function of the board
plus the payload, and no compute lives inside it. If it dies — session ended, laptop closed,
phone put down — the fired children keep building in the cloud and nothing is lost or
orphaned; the DAG simply stops *advancing* until someone runs
`/quetrex:task-build <EPIC-ID>` again (Step 1 → `RESUME` → Step 5 → here) or fires one
`--tick` by hand. Say that in the report, so an operator who closes the laptop knows exactly
what did and did not stop.

**One tick** (this is all `--tick` does — do exactly this, then exit):

1. **Compute the ready set** — children not yet started whose dependencies are all
   `DONE_FOR_UNBLOCKING = {merged, deployed, complete}`:

   ```bash
   quetrex-api is-unblocked "<child-id>"   # exit 0 = ready, 1 = still blocked
   ```

   Prefer the server's `isBlocked` flag; the helper falls back to checking dependency
   statuses. Read the child ids from the payload's `children[].id` — never from memory.

2. **Launch up to the cap — as cloud Routines.** Count children currently `in_progress`
   (in-flight) and launch ready children only up to `cap − in_flight` (`concurrencyCap`,
   3–5). For each ready child, derive its dispatch parameters from the payload — never from
   memory, and never from the epic's own values:

   ```bash
   # ── quetrex:exec-block qx_child_dispatch_params ──────────────────────────────
   # Executable, and executed: test/task-build-guards.test.sh drives this function
   # against a fixture payload. Prints one KEY=value line per parameter, so the
   # child dispatch below is fed by the payload rather than by recollection.
   qx_child_dispatch_params() {   # qx_child_dispatch_params <payload> <child-id>
     node -e '
       const fs=require("fs");
       const [file,childId]=process.argv.slice(1);
       const p=JSON.parse(fs.readFileSync(file,"utf8"));
       const c=(p.children||[]).find(c=>c.id===childId);
       if(!c){ console.error("no child "+childId+" in "+file); process.exit(1); }
       const base=p.integrationBranch;
       if(!base){ console.error("epic payload has no integrationBranch — children must never target main"); process.exit(1); }
       if(!c.plan || typeof c.plan!=="object" || !c.plan.ownership || Object.keys(c.plan.ownership).length===0){
         console.error("child "+childId+" has no plan with a non-empty ownership map — its cloud routine would abort as transport_failure. Re-run the plan half (Step 3B) for this epic.");
         process.exit(1);
       }
       console.log("CHILD_ID="+childId);
       console.log("CHILD_TITLE="+(c.title||""));
       console.log("CHILD_SPEC_BRANCH=quetrex-spec/"+childId);
       console.log("CHILD_BASE_BRANCH="+base);
       console.log("CHILD_BRANCH_PREFIX="+p.branchPrefix);
     ' "$1" "$2"
   }
   # ── end quetrex:exec-block qx_child_dispatch_params ─────────────────────────
   ```

   Then run **Step 6A verbatim for that child**, substituting:
   - `TASK_ID` → `CHILD_ID`, `TASK_TITLE` → `CHILD_TITLE`,
   - the plan published to the spec branch → the child's `children[].plan` from the payload
     (that is the child's `planSnapshot`; there is no separate plan file),
   - `SPEC_BRANCH` → `CHILD_SPEC_BRANCH`, `BASE_BRANCH_FOR_SPEC` → `CHILD_BASE_BRANCH`
     (the **integration branch** — a child PR targets it, never `main`),
   - `environment_id` → the same `$QX_CLOUD_ENV_ID` resolved at Step 1a,
   - routine `name` → `<CHILD_ID> <child title>`, same phone-scannable rule as 6A.

   The approved-base rule applies per child too: pin each child's base sha on its first
   dispatch (into `childDispatch[<child-id>].baseSha`) and reuse it on any re-dispatch — the
   integration branch moves every time a sibling merges, so re-resolving it is the same
   permanent `transport_failure` dead end 6A documents. Record each fired routine into the
   payload's `childDispatch[<child-id>]` with the same `{routineId,monitorUrl,specBranch,
   baseSha,dispatchedAt}` shape, and **never fire a child that already has a live record and
   is still `in_progress`** — that is the per-child form of Step 1's in-flight refusal.

3. **Reap.** A child's routine terminates at an **open PR into the integration branch** and
   publishes its gate evidence to `<branchPrefix><CHILD-ID>-gates`, exactly like a standalone
   unit. Reaping is therefore `/quetrex:merge <child-id>`: it brings that evidence home,
   proves it is pinned to the PR head, merges through `merge-gate.sh`, sets the child
   `merged` and tears its branch down. Merging into the **integration branch** is the one
   place this pipeline auto-merges — never into `main`. A merged child unblocks its
   dependents, which the next tick picks up. A child the engine sent to `needs_clarity` stays
   there: its **independent siblings keep running**, its **dependents WAIT** — never
   auto-`needs_clarity` a dependent by association.

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

The heavy work — every unit's DEV PIPELINE — runs unattended, out of this session, on
Anthropic's servers: a standalone task's BUILD half as a **fired cloud Routine** (Step 6A),
and **each epic child as its own fired cloud Routine** of the same shape (Step 6B). You never
parse either's stdout inline, and neither one needs this session to stay alive.

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

  **Then publish the epic's own gate evidence — without it the PR can never merge.**
  `merge-gate.sh` requires `review-verdict.json`'s `.sha` to equal the PR head, and every
  child's verdict is pinned to its own commit, so the children's artifacts are **not** a
  substitute and must never be re-pinned or aggregated to look like one. The integration
  head is a commit no child gate ever saw: it is the merge of all of them, and nothing has
  verified *that* tree.

  So dispatch one more cloud routine, against the integration branch, exactly as Step 6A
  dispatches a unit — same `RemoteTrigger` shape, same `create` → `run` →
  `update{enabled:false}` order — with `{{TASK}}` = `<EPIC-ID>` and the base branch
  `${BRANCH_PREFIX}<EPIC-ID>`. It runs QA → reviewer → security-reviewer against the
  integration head (there is no developer stage; the code is already written and merged),
  and publishes `${BRANCH_PREFIX}<EPIC-ID>-gates` with the same seven artifacts and the same
  `gates-head` pin a unit publishes. `/quetrex:merge <EPIC-ID>` then works on the epic with
  no special case.

  If that routine reports `REWORK` or `ESCALATE_HUMAN`, the epic is **not** mergeable even
  though every child passed — the integration tree is where cross-child breakage shows up,
  which is the entire reason this stage exists rather than trusting the children's verdicts.

- **Any child `needs_clarity`, or blocked-waiting on one** → do **NOT** open the
  integration PR. Report exactly which children **failed** and which are
  **blocked-waiting** on a failed dependency. The user runs **`/quetrex:task-rework <child>`** on
  each failure; on pass it auto-merges into the integration branch and **unblocks** its
  dependents. Re-running **`/quetrex:task-build <EPIC-ID>`** then resumes the dispatcher (Step 1
  resume path → Step 5) and drains the now-eligible dependents. Only when every child is
  `merged` is the integration → main PR opened. The epic stays `in_progress` throughout.

Point the user to the **board** and to the routine list on claude.ai (`childDispatch[].monitorUrl`
per child — the same links work on the phone) for live progress. Do **not** parse routine
output inline.

---

## Error-handling rules

- Any `quetrex-api` or resolver non-zero exit → the helper already printed the correct
  user-facing message. Just stop; do not add your own auth/access explanation.
- Non-actionable status, or an epic-child argument → report and stop (per Step 1). The
  actionability guard runs in **every** mode, `--build-only` and `--tick` included: a stale
  approved payload must never re-fire work that has already landed.
- Never re-dispatch a task whose routine is in flight (`dispatch.dispatchedAt` set and the
  card still `in_progress`) — two runs collide on one spec branch, one unit branch and one
  gates branch, and the loser's evidence silently overwrites the winner's.
- `in_progress` with no recorded dispatch means **wedged, not running**. Resume it; never
  tell the operator a pipeline is running when nothing is.
- Never hardcode the cloud `environment_id`. It comes from the repo binding
  (`cloudEnvironmentId`) or `QUETREX_CLOUD_ENVIRONMENT_ID`; absent → stop with the bind-it
  instruction from Step 1a, and never guess a provisioning API.
- Never re-resolve the base branch on a re-dispatch. The approved base sha is pinned in the
  payload at the first dispatch and reused verbatim thereafter.
- Every unit of compute — standalone task **and** every epic child — is dispatched as a
  cloud Routine. Nothing this command starts may require the operator's session to stay
  alive.
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
