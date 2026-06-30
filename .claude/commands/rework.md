---
description: Discuss why a failed Quetrex task didn't pass, agree a fix plan, then re-queue and re-run the shared dev pipeline (off the epic integration branch for a child). Usage: /rework SMA-1
argument-hint: <TASK-ID like SMA-1>
---

# Rework

Take a task that came back from the pipeline (typically `needs_clarity`), understand **why it
failed**, **discuss the fix with the user until you are confident it will work**, write the agreed
plan to the kanban, re-queue the task, and re-run **THE DEV PIPELINE** — the **same shared engine**
`/que-task` uses, defined once in `.claude/lib/dev-pipeline.md` and **not restated here**.

This command is the intake + discussion + re-dispatch front end; the heavy work runs in a
background Workflow-tool run so the terminal stays free.

All kanban I/O goes through the token-safe helpers in `.claude/lib/quetrex-api.sh`
(`qapi` + the `qx_*` wrappers): never echo the token, never `set -x` / `curl -v` around `qapi`,
always build JSON with `node` / `JSON.stringify`.

Argument: `$ARGUMENTS` is a single human task identifier, e.g. `SMA-1`. Works on **any** task —
standalone or epic child.

---

## Step 1 — Parse, resolve, fetch context

```bash
TASK_ID="$(echo "$ARGUMENTS" | tr -d '[:space:]')"
```

If `TASK_ID` is empty, print usage and stop:

> Usage: `/rework SMA-1`

Source the helper and resolve context in one bash block — the helper owns all auth/access
messaging; do not reinvent it:

```bash
source ~/.claude/lib/quetrex-api.sh
resolve_auth    || exit 1      # prints "Run /quetrex-login" on failure
resolve_project || exit 1      # prints "Run /quetrex-init" on failure
qapi GET "/api/projects/$QX_PROJECT_CODE" >/dev/null || exit 1   # validate access
TASK="$(qapi GET "/api/tasks/$TASK_ID")"            || exit 1
COMMENTS="$(qapi GET "/api/tasks/$TASK_ID/comments")" || exit 1
echo "Project: $QX_PROJECT_CODE @ $QX_KANBAN_URL"
```

If any resolver or `qapi` call exits non-zero, the helper already printed the correct message
(401 → `Run /quetrex-login`; 403/404 → `No access — contact your administrator`; other →
`Quetrex API error (HTTP <code>)`). Just stop.

Read the fields from `$TASK` — including the **AI-notes** the engine left on failure:

```bash
node -e '
  let o; try{o=JSON.parse(process.argv[1])}catch{process.exit(1)}
  const g=k=>o[k]==null?"":String(o[k]);
  console.log(["status="+g("status"),"type="+g("type"),"title="+g("title"),
               "parentTaskId="+g("parentTaskId"),
               "---AI-NOTES---",g("aiNotes")].join("\n"));
' "$TASK"
```

Read the recent discussion (`$COMMENTS`) the same way — the engine posts the failure reason as a
comment too:

```bash
node -e '
  let a; try{a=JSON.parse(process.argv[1])}catch{a=[]}
  const list=Array.isArray(a)?a:(a.comments||a.data||[]);
  for(const c of list.slice(-15))
    console.log("• ["+(c.createdAt||"")+"] "+String(c.body||c.text||"").trim());
' "$COMMENTS"
```

**Discover the failed branch / PR** by the task-merge convention. The engine names the unit branch
`feature/<TASK_ID>-<slug>`, so match the **whole token** — `SMA-1` must not match `SMA-12`:

```bash
# Whole-token match: branch is exactly feature/SMA-1 or starts with feature/SMA-1-<slug>.
gh pr list --state all --json number,headRefName,state,url \
  --jq ".[] | select(.headRefName == \"feature/$TASK_ID\" or (.headRefName | startswith(\"feature/$TASK_ID-\")))" \
  2>/dev/null || true
```

If a PR is found, read its diff for grounding (`gh pr diff <number>`); if only a branch exists,
inspect it with `git diff main...feature/$TASK_ID-<slug>`. Then **read the relevant repo code**
(Glob / Grep / Read) around the changed surface so your explanation and fix plan are grounded in
reality, not just the notes.

**State warning (non-blocking).** `/rework` expects a task in a rework-expecting state —
canonically `needs_clarity`. If `status` is something else (e.g. `pr_ready`, `merged`, `deployed`,
`complete`, `backlog`, `queued`, or already `in_progress`), **warn clearly**:

> ⚠️ `SMA-1` is in `<status>`, not `needs_clarity` — `/rework` is meant for tasks the pipeline sent
> back. Re-running may duplicate in-flight or finished work. Do you want to continue anyway?

and **wait for the user to confirm** before proceeding. Do not auto-continue.

---

## Step 2 — Explain WHY it failed, then DISCUSS

- **Explain to the user why it failed**, grounded in the AI-notes, the comments, the PR/branch
  diff, and the code you read. Be concrete: which acceptance criterion went unmet, which QA exit
  code was non-zero, which reviewer/security finding blocked, or what ambiguity stalled it.
- **Discuss the fix interactively.** Propose a fix plan, then iterate with the user — ask sharp
  questions on any genuine gap, fold in their answers, and refine — until **you are confident the
  fix will actually work**. Do **not** jump straight to re-running the pipeline. This discussion is
  the whole point of `/rework`; a re-run without a corrected, agreed plan will just fail again.

---

## Step 3 — Persist the agreed plan + re-queue

Once you and the user agree on the fix, record it on the kanban and move the task to `queued` so
the engine picks it up cleanly:

```bash
qx_task_comment "$TASK_ID" "REWORK PLAN (agreed):
<the concrete, agreed fix plan — what changes, why it addresses the failure, and the acceptance
criteria it must now satisfy>"
# Optional: also append an AI-note so the failure→fix trail lives on the record.
qx_task_ainote "$TASK_ID" "Rework re-queued: <one-line summary of the agreed fix>"
qx_task_status "$TASK_ID" queued
```

---

## Step 4 — Re-run THE DEV PIPELINE (same shared engine)

Determine the base branch from `parentTaskId`:

- **Standalone task** (`parentTaskId` empty) → `BASE_BRANCH=main`; the PR targets `main`. The human
  merges later with `/task-merge $TASK_ID`.
- **Epic child** (`parentTaskId` set, e.g. `SMA-1.2`) → `BASE_BRANCH=feature/<EPIC-ID>` (the
  per-epic integration branch); the PR targets the integration branch. This **re-enters the epic
  DAG** — on pass it auto-merges into the integration branch and unblocks dependents, exactly like a
  first run.

Then:

> Run THE DEV PIPELINE exactly as defined in `.claude/lib/dev-pipeline.md`, with these inputs:
> `TASK_ID`, `TASK_TITLE`, `BASE_BRANCH`, `WORKFLOW_TITLE`, and the resolved kanban context
> (`QX_KANBAN_URL`, `QX_PROJECT_CODE`). Do not restate the steps here.

with:

- `TASK_ID` = `$TASK_ID`
- `TASK_TITLE` = the task title
- `BASE_BRANCH` = `main` (standalone) or `feature/<EPIC-ID>` (epic child), as decided above
- `WORKFLOW_TITLE` = `"$TASK_ID · <title> (rework)"`

Dispatch the workflow in the **background**. The engine drives `queued/in_progress → pr_ready`
(or back to `needs_clarity` on bounded-loop exhaustion). Then go to **Step 5**.

---

## Step 5 — Report (do not block the terminal)

Report what was launched: the workflow title, the base branch (and, for an epic child, that it
re-entered the epic DAG and will auto-merge into `feature/<EPIC-ID>` on pass), and that it is
building toward `pr_ready`. Point the user to `/workflows` and the board for live progress. Do
**not** parse workflow output inline or block the terminal.

---

## Error-handling rules

- Any `qapi` or resolver non-zero exit → the helper already printed the correct user-facing
  message. Just stop; do not add your own auth/access explanation.
- Not in a rework-expecting state → warn and wait for explicit confirmation (Step 1); never
  silently re-run a `pr_ready` / `merged` / finished task.
- Always discuss to confidence before re-queuing — a re-run without a corrected, agreed plan just
  reproduces the failure.
- Reference the shared engine in `.claude/lib/dev-pipeline.md`; do **not** restate its steps here.
- Never print or echo the bearer token. Never run `set -x` / `curl -v` around `qapi`. Build every
  JSON payload with `node` / `JSON.stringify`, never `echo`.
</content>
</invoke>
