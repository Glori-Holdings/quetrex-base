---
description: Discuss why a failed Quetrex task didn't pass, agree a fix plan, apply non-blocking nits with /code-review --fix instead of rebuilding for them, then re-queue and re-run the shared dev pipeline (off the epic integration branch for a child). Usage: /quetrex:task-rework SMA-1
argument-hint: <TASK-ID like SMA-1>
---

# Rework

Take a task that came back from the pipeline (typically `needs_clarity`), understand **why it
failed**, **discuss the fix with the user until you are confident it will work**, write the agreed
plan to the kanban, re-queue the task, and re-run **THE DEV PIPELINE** — the **same shared engine**
`/quetrex:task-build` uses, defined once in `.claude/lib/dev-pipeline.md` and **not restated here**.

This command is the intake + discussion + re-dispatch front end; the heavy work runs in a
background Workflow-tool run so the terminal stays free.

All kanban I/O goes through the token-safe `quetrex-api` tool (shipped on the plugin's PATH —
raw `quetrex-api <METHOD> <path> [body]` calls plus the `quetrex-api task-*` subcommands): never
echo the token, never `set -x` / `curl -v` around `quetrex-api`, always build JSON with
`node` / `JSON.stringify`.

Argument: `$ARGUMENTS` is a single human task identifier, e.g. `SMA-1`. Works on **any** task —
standalone or epic child.

---

## Step 1 — Parse, resolve, fetch context

```bash
TASK_ID="$(echo "$ARGUMENTS" | tr -d '[:space:]')"
```

If `TASK_ID` is empty, print usage and stop:

> Usage: `/quetrex:task-rework SMA-1`

Resolve context in one bash block — the `quetrex-api` tool (shipped on the plugin's PATH) owns
all auth/access messaging; do not reinvent it:

```bash
QX_KANBAN_URL="$(quetrex-api kanban-url)"     || exit 1   # prints "Run /quetrex:login" on failure
QX_PROJECT_CODE="$(quetrex-api project-code)" || exit 1   # prints "Run /quetrex:init" on failure
quetrex-api GET "/api/projects/$QX_PROJECT_CODE" >/dev/null || exit 1   # validate access
TASK="$(quetrex-api GET "/api/tasks/$TASK_ID")"            || exit 1

REPO_ROOT="$(git rev-parse --show-toplevel)"
# Branch prefix: NEVER hardcode "feature/". A repo whose push rules cannot be loosened
# sets "branchPrefix": "claude/" in .quetrex/project.json, and every branch below follows.
BRANCH_PREFIX="$(quetrex-api json-get "$REPO_ROOT/.quetrex/project.json" branchPrefix 2>/dev/null || echo 'feature/')"
[ -n "$BRANCH_PREFIX" ] || BRANCH_PREFIX="feature/"

echo "Project: $QX_PROJECT_CODE @ $QX_KANBAN_URL   branchPrefix=$BRANCH_PREFIX"
```

If any context fetch or `quetrex-api` call exits non-zero, the tool already printed the correct message
(401 → `Run /quetrex:login`; 403/404 → `No access — contact your administrator`; other →
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

Read the recent discussion the same way — comments ship **inside** `$TASK` (the task GET already
embeds them), and the engine posts the failure reason as a comment too:

```bash
node -e '
  let o; try{o=JSON.parse(process.argv[1])}catch{o={}}
  const list=Array.isArray(o.comments)?o.comments:(o.data||[]);
  for(const c of list.slice(-15))
    console.log("• ["+(c.createdAt||"")+"] "+String(c.body||c.text||"").trim());
' "$TASK"
```

**Discover the failed branch / PR.** The engine names the unit branch
`${BRANCH_PREFIX}<TASK_ID>-<slug>`, so match the **whole token** — `SMA-1` must not match
`SMA-12`:

```bash
# Whole-token match: branch is exactly <prefix>SMA-1 or starts with <prefix>SMA-1-<slug>.
gh pr list --state all --json number,headRefName,state,url \
  --jq ".[] | select(.headRefName == \"${BRANCH_PREFIX}$TASK_ID\" or (.headRefName | startswith(\"${BRANCH_PREFIX}$TASK_ID-\")))" \
  2>/dev/null || true
```

If a PR is found, read its diff for grounding (`gh pr diff <number>`); if only a branch exists,
inspect it with `git diff main...${BRANCH_PREFIX}$TASK_ID-<slug>`. Then **read the relevant repo
code** (Glob / Grep / Read) around the changed surface so your explanation and fix plan are
grounded in reality, not just the notes.

**State warning (non-blocking).** `/quetrex:task-rework` expects a task in a rework-expecting state —
canonically `needs_clarity`. If `status` is something else (e.g. `pr_ready`, `merged`, `deployed`,
`complete`, `backlog`, `queued`, or already `in_progress`), **warn clearly**:

> ⚠️ `SMA-1` is in `<status>`, not `needs_clarity` — `/quetrex:task-rework` is meant for tasks the pipeline sent
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
  the whole point of `/quetrex:task-rework`; a re-run without a corrected, agreed plan will just fail again.

---

## Step 2b — Nit fast path (`/code-review --fix`) — before you re-queue anything

Most reworks carry a mix: one real defect plus a handful of naming / minor-style /
opportunistic-cleanup findings. `reviewer.md` calls those **non-blocking quality nits** and
they explicitly do **not** block `AUTO_MERGE`. Spinning the whole pipeline for them — or
letting them consume a `review_iter` on the next pass — is waste. Handle them here.

**1. Triage every finding into two tiers.**

| Tier | What it is |
|---|---|
| **BLOCKING** | correctness, security, an architecture / file-ownership violation, a red verify command, an unmet acceptance criterion |
| **NIT** | naming, minor style, dead code, opportunistic cleanup — anything the reviewer itself would report without blocking |

**When in doubt it is BLOCKING.** Never downgrade a finding to NIT to reach the fast path;
that is the one way this step can do damage.

**2. Apply the nit tier locally** in the failed unit's worktree — a working-tree edit, no
pipeline run:

```bash
/code-review --fix
```

Review what it changed before accepting it; `--fix` is a convenience, not an authority.

**3. Branch on the triage.**

- **Any BLOCKING finding** → continue to **Step 3**. The nit fixes ride into the same
  re-run, so the rebuilt change does not re-surface them and the reviewer spends its
  iteration on the real defect.
- **Zero BLOCKING findings** (the whole rework was trivia) → do **not** spin the pipeline.
  Commit the fixes on the existing unit branch, then re-run **the gates**: the verify chain
  to proven green (the `qa-verify` skill), and a fresh reviewer pass pinned to the new HEAD.
  Skip Steps 3–4.

**This is a gate re-run, not a gate skip.** HEAD moved, so `merge-gate.sh` still requires a
green ledger *and* an `AUTO_MERGE` verdict whose `.sha` equals the new HEAD. Nothing in this
step produces either; it only avoids rebuilding code that was already correct. If the fresh
reviewer pass returns `REWORK` or `ESCALATE_HUMAN`, the fast path was wrong — go to Step 3
and run the full pipeline.

---

## Step 3 — Persist the agreed plan + re-queue

Once you and the user agree on the fix, record it on the kanban and move the task to `queued` so
the engine picks it up cleanly:

```bash
quetrex-api task-comment "$TASK_ID" "REWORK PLAN (agreed):
<the concrete, agreed fix plan — what changes, why it addresses the failure, and the acceptance
criteria it must now satisfy>"
# Optional: also append an AI-note so the failure→fix trail lives on the record.
quetrex-api task-ainote "$TASK_ID" "Rework re-queued: <one-line summary of the agreed fix>"
quetrex-api task-status "$TASK_ID" queued
```

---

## Step 4 — Re-run THE DEV PIPELINE (same shared engine)

Determine the base branch from `parentTaskId`:

- **Standalone task** (`parentTaskId` empty) → `BASE_BRANCH=main`; the PR targets `main`. Its
  terminus is an open PR, and whether that PR merges is decided by the reviewer's verdict and
  enforced by `merge-gate.sh` — `AUTO_MERGE` pinned to HEAD with a green ledger permits the
  squash merge; `REWORK` / `ESCALATE_HUMAN` holds it. There is **no `/quetrex:task-merge` command**;
  do not tell the user to run one.
- **Epic child** (`parentTaskId` set, e.g. `SMA-1.2`) → `BASE_BRANCH=${BRANCH_PREFIX}<EPIC-ID>`
  (the per-epic integration branch); the PR targets the integration branch. On pass it auto-merges
  into the integration branch and **unblocks** its dependents. Unblocking only flips their
  readiness — it does **not** dispatch them; this command rebuilds the **one** child only. To
  actually drain the now-eligible dependents, the user **re-runs `/quetrex:task-build <EPIC-ID>`**, which
  resumes the DAG dispatcher over the existing children (the epic stays `in_progress`). Surface
  this next step in the report.

Then:

> Run THE DEV PIPELINE exactly as defined in `.claude/lib/dev-pipeline.md`, with these inputs:
> `TASK_ID`, `TASK_TITLE`, `BASE_BRANCH`, `WORKFLOW_TITLE`, and the resolved kanban context
> (`QX_KANBAN_URL`, `QX_PROJECT_CODE`). Do not restate the steps here.

with:

- `TASK_ID` = `$TASK_ID`
- `TASK_TITLE` = the task title
- `BASE_BRANCH` = `main` (standalone) or `${BRANCH_PREFIX}<EPIC-ID>` (epic child), as decided above
- `BRANCH_PREFIX` = `$BRANCH_PREFIX`
- `WORKFLOW_TITLE` = `"$TASK_ID · <title> (rework)"`

Dispatch the workflow in the **background**. The engine drives `queued/in_progress → pr_ready`
(or back to `needs_clarity` on bounded-loop exhaustion). Then go to **Step 5**.

---

## Step 5 — Report (do not block the terminal)

Report what was launched: the workflow title, the base branch, and that it is building toward
`pr_ready`. If the **nit fast path** (Step 2b) was taken, report that instead: which findings were
triaged NIT, that `/code-review --fix` applied them with no pipeline run, and the result of the
verify-chain and reviewer gate re-runs — never imply the gates were skipped.

For an **epic child**, also state that on pass it auto-merges into `${BRANCH_PREFIX}<EPIC-ID>` and
unblocks its dependents, and that the user should then **re-run `/quetrex:task-build <EPIC-ID>`** to
resume the dispatcher and drain those dependents. Point the user to `/workflows` and the board for
live progress. Do **not** parse workflow output inline or block the terminal.

---

## Error-handling rules

- Any `quetrex-api` or resolver non-zero exit → the helper already printed the correct user-facing
  message. Just stop; do not add your own auth/access explanation.
- Not in a rework-expecting state → warn and wait for explicit confirmation (Step 1); never
  silently re-run a `pr_ready` / `merged` / finished task.
- Always discuss to confidence before re-queuing — a re-run without a corrected, agreed plan just
  reproduces the failure.
- Never downgrade a finding to NIT to reach the Step 2b fast path, and never let that fast path
  skip the verify chain or the reviewer verdict — it skips the *rebuild*, not the gates.
- Never hardcode `feature/` — construct every branch from `$BRANCH_PREFIX`.
- Reference the shared engine in `.claude/lib/dev-pipeline.md`; do **not** restate its steps here.
- Never print or echo the bearer token. Never run `set -x` / `curl -v` around `quetrex-api`. Build every
  JSON payload with `node` / `JSON.stringify`, never `echo`.
