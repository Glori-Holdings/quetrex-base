# THE DEV PIPELINE — shared engine

This is the single canonical definition of the development pipeline that drives one **unit of
work** from kanban intake to an open PR. It is the source of truth: `/quetrex-task-build` and `/quetrex-task-rework`
both reference it and **neither restates the steps**. `/quetrex-task-build` runs it once per standalone
task and once per epic child; `/quetrex-task-rework` runs the identical engine on re-queue.

This is the proven **double-loop** pipeline (inner developer⇄QA loop, outer reviewer loop), run
end to end by the **Workflow tool** in the **background** so the terminal stays free.

---

## How a caller invokes it

A command that wants to run a unit of work says, verbatim:

> Run THE DEV PIPELINE exactly as defined in `.claude/lib/dev-pipeline.md`, with these inputs:
> `TASK_ID`, `TASK_TITLE`, `BASE_BRANCH`, `WORKFLOW_TITLE`, and the resolved kanban context
> (`QX_KANBAN_URL`, `QX_PROJECT_CODE`). Do not restate the steps here.

It does **not** copy the steps below into its own file.

---

## Inputs (passed by the caller)

- `TASK_ID` — kanban identifier of the unit (`SMA-1`, or an epic child `SMA-1.2`).
- `TASK_TITLE` — used for the workflow title and the branch slug.
- `BASE_BRANCH` — branch to fork from: `main` for a standalone task; the per-epic integration
  branch `feature/<EPIC-ID>` for an epic child.
- `WORKFLOW_TITLE` — the Workflow-tool run title: `"<TASK-ID> · <unit name>"`.
- Kanban context — `QX_KANBAN_URL`, `QX_PROJECT_CODE`, already exported by
  `resolve_auth` / `resolve_project`; the token-safe helpers in `.claude/lib/quetrex-api.sh`
  (`qx_task_status`, `qx_task_ainote`, `qx_task_comment`, …) are sourced and ready.

All kanban writes go through those helpers (which route through `qapi`): never echo the token,
never `set -x` / `curl -v` around `qapi`, always build JSON with `node` / `JSON.stringify`.

---

## Engine steps (one Workflow-tool run, in the background)

The whole engine is **one Workflow-tool run** titled `WORKFLOW_TITLE`, dispatched in the
background. Its internal stages are the shipped agents in order.

1. **Isolate.** Per the `worktree-workflow` skill, create branch `feature/<TASK_ID>-<slug>` and a
   git worktree off `BASE_BRANCH`. Use `git -C <wt>` so the enforce-branch hook sees the branch
   instead of blocking on main. For a standalone task the PR will target `main`; for an epic
   child the PR will target `BASE_BRANCH` (the integration branch).

2. **Kanban: `in_progress`.** First action of the pipeline:
   `qx_task_status "$TASK_ID" in_progress`. Post a "pipeline started — architect planning"
   comment with `qx_task_comment`.

3. **ARCHITECT** (opus) — produce the implementation plan, a **strict file-ownership map**, and
   **testable acceptance criteria**, written to `.issue/architecture-decision.md` on the branch.
   Decompose the unit into **disjoint developer workstreams** when it warrants parallelism (zero
   file overlap; overlapping files become a dependency, not parallel work). For
   sensitive surfaces, flag `security_review_required`.

4. **DEVELOPER(s)** (sonnet, `isolation: worktree`) — implement with tests. When the architect
   decomposed the unit, developers run in **parallel** on disjoint files (sub-branches
   `feature/<TASK_ID>-<area>`), then merge into the unit branch.

5. **INNER LOOP — developer ⇄ QA, bounded ≈ 3 iterations.** QA owns test adequacy: it
   authors/strengthens tests **independently of the developer**, runs the project verification
   chain (compile/types/lint/unit) reporting **actual exit codes**, asserts **every acceptance
   criterion** is met, and runs a **runtime / E2E smoke on the changed surface** (not just unit
   tests). Any non-zero exit or unmet criterion → back to the developer with the exact output.
   Repeat until green **and** all criteria satisfied, or the bound is hit.

6. **OUTER LOOP — REVIEWER, bounded ≈ 3 iterations.** Adversarial review in **fresh context**,
   explicitly told to **REFUTE** the change. Reads the full diff (`git diff <BASE_BRANCH>...HEAD`)
   for logic errors, security, architecture violations, and cross-file consistency. When the
   architect set `security_review_required` (auth / authz / input handling / secrets / external
   calls / data access), also run `security-reviewer`; a **Critical** finding blocks. REJECT →
   back to the inner loop (the reject counts against the outer bound).

7. **ON EXHAUSTION of either loop** → do **not** thrash. Write an **AI-note** explaining
   precisely why it failed — last QA output / reviewer findings / blocking ambiguity —
   (`qx_task_ainote "$TASK_ID" "<why>"`), post a comment (`qx_task_comment`), and set the kanban
   to **`needs_clarity`** (`qx_task_status "$TASK_ID" needs_clarity`). Exit the workflow. This is
   the **only** failure terminus.

8. **GIT-WORKFLOW** (haiku) — commit (conventional message), push, and open the **PR** into
   `BASE_BRANCH` (`main` for a standalone task; the integration branch for an epic child).
   Capture the PR number / URL.

9. **Kanban: `pr_ready`.** On PR open, `qx_task_status "$TASK_ID" pr_ready`; post a comment with
   the PR URL via `qx_task_comment`.

10. **Teardown** per `worktree-workflow`: the pipeline leaves **no dangling worktree or sub-branch
    of its own**. The unit branch and its PR remain — merging the PR is a later gate
    (`/quetrex-task-merge` for a standalone task; the epic DAG's auto-merge into the integration branch
    for an epic child).

---

## Status transitions owned by the engine

- `*` → `in_progress` — first pipeline action (step 2).
- `in_progress` → `pr_ready` — PR opened (happy path, step 9).
- `in_progress` → `needs_clarity` — bounded-loop exhaustion, hard blocker, or unanswerable
  ambiguity (step 7), always with an AI-note.

The engine **never** sets `merged` / `deployed` / `complete` — those are human / `/quetrex-task-merge` /
epic-DAG gates outside this engine.

---

## Background + visibility

The caller does **not** parse engine output inline. Progress is visible on the board (status
column + comments + AI-notes) and via `/workflows`. The state of truth is the kanban; callers
poll it (status + dependencies + `isBlocked`), they do not read the workflow's stdout.
