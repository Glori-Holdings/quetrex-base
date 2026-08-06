# THE DEV PIPELINE — shared engine

This is the single canonical definition of the development pipeline that drives one **unit of
work** from kanban intake to an open PR. It is the source of truth for the *order of stages and
the gates between them*: `/quetrex:task-build` and `/quetrex:task-rework` both reference it and **neither
restates the steps**. `/quetrex:task-build` runs it once per standalone task and once per epic child;
`/quetrex:task-rework` runs the identical engine on re-queue.

**What this file is not.** Each stage's own behaviour is defined by its agent file under
`.claude/agents/`, and those files are authoritative. Where this document and an agent file ever
disagree, the agent file wins and this document is the bug. This file describes the sequence, the
inputs, and the artifacts that pass between stages — nothing about how a stage does its job.

This is the proven **double-loop** pipeline: an inner developer ⇄ QA loop and an outer review
loop, both bounded.

---

## How a caller invokes it

A command that wants to run a unit of work says, verbatim:

> Run THE DEV PIPELINE exactly as defined in `.claude/lib/dev-pipeline.md`, with these inputs:
> `TASK_ID`, `TASK_TITLE`, `BASE_BRANCH`, `BRANCH_PREFIX`, `WORKFLOW_TITLE`, and the resolved
> kanban context (`QX_KANBAN_URL`, `QX_PROJECT_CODE`). Do not restate the steps here.

…plus, when the caller is running only one half of the engine across the human scope gate,
`PIPELINE_STOP_AFTER` / `PIPELINE_RESUME_FROM` / `PLAN_ARTIFACT` (see Inputs).

It does **not** copy the steps below into its own file.

---

## Inputs (passed by the caller)

- `TASK_ID` — kanban identifier of the unit (`SMA-1`, or an epic child `SMA-1.2`).
- `TASK_TITLE` — used for the workflow title and the branch slug.
- `BRANCH_PREFIX` — the prefix every branch this run creates is built from, read by the caller
  from `.quetrex/project.json` (`branchPrefix`). Defaults to `claude/` when the caller does not
  pass it — the only prefix a cloud routine can push to without repo-admin setup. **Never
  hardcode a prefix** — a team may set anything else and every branch below must follow.
  Wherever this document writes
  `${BRANCH_PREFIX}`, it means that value, not the literal string.
- `BASE_BRANCH` — branch to fork from: `main` for a standalone task; the per-epic integration
  branch `${BRANCH_PREFIX}<EPIC-ID>` for an epic child.
- `WORKFLOW_TITLE` — the run title: `"<TASK-ID> · <unit name>"`.
- Kanban context — `QX_KANBAN_URL`, `QX_PROJECT_CODE`, already exported by
  `resolve_auth` / `resolve_project`; the token-safe helpers in `.claude/lib/quetrex-api.sh`
  (`qx_task_status`, `qx_task_ainote`, `qx_task_comment`, …) are sourced and ready.

### Optional inputs — running one half of the engine across the human scope gate

`/quetrex:task-build` splits at a human scope-approval gate: an interactive PLAN half, then an
unattended BUILD half a routine can run from the approved payload. Both halves run **this**
engine; these three inputs are how one engine serves both. They are optional — omit all three
and the engine runs end to end exactly as it always has.

- `PIPELINE_STOP_AFTER` — the last stage to run. The only supported value is `architect`.
  When set, the engine runs steps 1–3 and then **stops cleanly**: it does not launch a
  developer, it does not tear the worktree down, and it does **not** treat stopping as a
  failure (no AI-note, no `needs_clarity`; the task stays `in_progress`). It reports the
  worktree path, the unit branch name, and the plan artifact path so the caller can put them
  in its payload.
- `PIPELINE_RESUME_FROM` — the first stage to run. The only supported value is `developers`.
  When set, the engine **skips step 3 entirely** — the architect does not run again — and
  requires `PLAN_ARTIFACT`. If the worktree and branch from the plan half still exist it
  reuses them; otherwise it re-creates them from `BASE_BRANCH` at step 1 and re-provisions.
  Step 2 is idempotent (`in_progress` → `in_progress`), so re-running it is harmless.
- `PLAN_ARTIFACT` — path to the plan the architect already wrote, normally
  `.quetrex/plan/<TASK_ID>.json`. It is **already human-approved**: read it, do not re-plan
  from it, and do not widen its ownership map or its acceptance criteria. If it is missing or
  does not parse, that is a hard stop (step 7) — never silently re-plan, because the scope a
  human approved would be replaced by a scope nobody approved.

A caller that passes `PIPELINE_RESUME_FROM` without `PLAN_ARTIFACT`, or `PLAN_ARTIFACT`
pointing at a file that does not exist, is a caller bug: stop at step 7 and say so.

All kanban writes go through those helpers (which route through `qapi`): never echo the token,
never `set -x` / `curl -v` around `qapi`, always build JSON with `node` / `JSON.stringify`.

---

## Where the engine runs (execution substrate — be precise about this)

The stages are **subagents**. The dispatch mechanism around them depends on the context:

- **From a main session** (a slash command the operator or a routine invoked), the caller
  dispatches the engine as **one Workflow-tool run** titled `WORKFLOW_TITLE`, in the background,
  so the terminal stays free.
- **Inside a subagent context the Workflow tool is not available.** No stage of this engine may
  dispatch a Workflow run of its own, and no engine stage may assume one wraps it. Nested
  orchestration — epic decomposition, fan-out across children — belongs to the main session that
  called in, never to a stage.
- **Where the Workflow tool is unavailable altogether**, the engine still runs: the caller
  executes the same stages, in the same order, as a sequence of subagent invocations. The
  Workflow tool is a dispatch and visibility convenience; **the stage order and the gates are the
  contract**, and they do not change with the substrate.

Every stage carries a `maxTurns` cap in its agent frontmatter. That is a runtime bound the
harness enforces out-of-band, independent of the on-disk loop counters described below — the two
bound different failure modes (a single runaway invocation vs. a repair loop that never
converges) and neither substitutes for the other.

---

## Engine steps

1. **Isolate.** Per the `worktree-workflow` skill, create branch
   `UNIT_BRANCH=${BRANCH_PREFIX}<TASK_ID>-<slug>` and a git worktree `WT` off `BASE_BRANCH`
   (later steps refer to those two names). Use `git -C "$WT"` so the enforce-branch hook sees the
   branch instead of blocking on main. A worktree carries only tracked files, so **provision it**
   (dependencies and env, per `.worktreeinclude` / the project's install command) before any stage
   runs — an unprovisioned worktree is the single most common cause of a stage burning its
   self-heal budget on a failure that was never in the code. For a standalone task the PR targets
   `main`; for an epic child it targets `BASE_BRANCH` (the integration branch).

2. **Kanban: `in_progress`, and seed `.quetrex/state.json`.** First action of the pipeline:
   `qx_task_status "$TASK_ID" in_progress`, then post a "pipeline started — architect planning"
   comment with `qx_task_comment`.

   Then **seed the control-plane state file in the worktree** — this is the only place it is
   created, and four consumers depend on it existing:

   ```bash
   mkdir -p "$WT/.quetrex"
   TMP="$(mktemp)"
   jq -n --arg task "$TASK_ID" --arg base "$BASE_BRANCH" --arg branch "$UNIT_BRANCH" \
     '{task:$task, base_branch:$base, branch:$branch, review_iter:0}' > "$TMP" \
     && mv "$TMP" "$WT/.quetrex/state.json"
   ```

   `.task` is what lets `merge-gate.sh` resolve **which** plan's ownership map governs this diff
   (GATE 5), what the reviewer and git-workflow read to find `plan/<TASK>.json`, and what
   `session-state.sh` re-injects after a compaction. Without it, a repo with more than one plan
   artifact on disk cannot merge at all — the gate refuses to guess and escalates to a human,
   correctly, forever. Seed it here; **later stages only ever merge fields into it** (reviewer:
   `.review_iter`; git-workflow: a refusal reason), never rewrite it. If it already exists —
   a resumed run, or `PIPELINE_RESUME_FROM` — merge `.task` in rather than clobbering the file.

3. **ARCHITECT** (`architect`, opus) — produce the implementation plan, a **strict file-ownership
   map**, and **testable acceptance criteria**, written as one machine-readable artifact to
   **`.quetrex/plan/<TASK_ID>.json`**. That artifact is the plan; there is no markdown plan file.
   Decompose the unit into **disjoint developer workstreams** when it warrants parallelism (zero
   file overlap; overlapping files become a dependency, not parallel work). For sensitive
   surfaces, set `security_review_required`. If the spec cannot be made measurable, the architect
   takes its `needs_clarity` exit and the pipeline goes to step 7.

   **Skipped entirely when `PIPELINE_RESUME_FROM=developers`** — the plan at `PLAN_ARTIFACT` was
   already produced by this stage and approved by a human, and re-running the architect would
   replace an approved scope with an unapproved one. Read it, validate that it parses and names
   an ownership map, and go to step 4.

   **When `PIPELINE_STOP_AFTER=architect`, the engine stops here** — cleanly, not as a failure.
   Leave the worktree and branch in place, report the worktree path, the branch name and the plan
   path, and do not touch the kanban status (it stays `in_progress`).

4. **DEVELOPER(s)** (`developer`, sonnet, `isolation: worktree`) — implement with tests, writing
   only the files their workstream owns. When the architect decomposed the unit, developers run in
   **parallel** on disjoint files (sub-branches `${BRANCH_PREFIX}<TASK_ID>-<area>`), then merge into the
   unit branch. When the plan sets `db_migration:true`, the schema workstream runs as
   `database-architect` (opus) instead. **Each developer commits its own owned files** on its
   sub-branch, explicit paths only. A stage that finds the worktree unprovisioned reports
   `needs_setup` and stops rather than self-healing against a missing environment (step 7).

5. **INNER LOOP — developer ⇄ QA, bounded ≈ 3 iterations.** QA (`qa`, sonnet) owns test adequacy:
   it authors/strengthens tests **independently of the developer**, runs the verify chain from
   `.quetrex/verify.json` reporting **actual exit codes** into `.quetrex/verify-ledger.jsonl`,
   asserts **every acceptance criterion**, enforces changed-file coverage and the vacuous-suite
   guard, and runs a **runtime / E2E smoke on the changed surface** (not just unit tests). Any
   non-zero exit or unmet criterion → back to the developer with the exact output. Repeat until
   green **and** all criteria satisfied, or the bound is hit.

   QA closes the loop by **committing the tests it authored**, then **re-running the full chain at
   that commit** so every ledger line is pinned to the HEAD that will ship, and finally writing
   **`.quetrex/qa-report.json`** — its verdict, the rungs with their real exit codes, the
   acceptance results, and, critically, `not_verified[]`: the coverage gaps it is declaring. That
   artifact is how QA's negative space reaches the reviewer, which is instructed to ignore QA's
   chat narrative and is right to.

6. **OUTER LOOP — REVIEW-GATE, bounded at 3.** `reviewer` (opus) runs in **fresh context**,
   explicitly told to **REFUTE** the change. It reads the full diff (`git diff <BASE_BRANCH>...HEAD`)
   for logic errors, security, architecture violations and cross-file consistency; runs the native
   `/security-review` (and `/review` when a PR exists) as independent evidence; re-proves the
   verify chain itself; and reads `qa-report.json`, `security-findings.json`, `state.json` and
   `ESCALATION` from disk. When the architect set `security_review_required` (auth / authz / input
   handling / secrets / external calls / data access), `security-reviewer` (opus) also runs and an
   open CONFIRMED **Critical** blocks.

   The reviewer emits a **3-way verdict** to `.quetrex/review-verdict.json`, pinned by sha to the
   commit it read:

   - **`AUTO_MERGE`** — clean; the merge may proceed with no human in the loop.
   - **`REWORK`** — a concrete, developer-fixable defect; back to the inner loop. This is the only
     verdict that increments `review_iter`; at 3 the next pass must escalate.
   - **`ESCALATE_HUMAN`** — uncertain, risky, or loop-exhausted; writes `.quetrex/ESCALATION` at
     the cap and goes to step 7.

   There is no separate "REJECT" outcome and no inner approve/reject cycle — the three verdicts
   above are the whole contract, and `merge-gate.sh` string-matches them.

7. **ON EXHAUSTION or a hard stop** → do **not** thrash. Write an **AI-note** explaining precisely
   why it failed — last QA output, reviewer findings, blocking ambiguity, or the missing
   provisioning behind a `needs_setup` — (`qx_task_ainote "$TASK_ID" "<why>"`), post a comment
   (`qx_task_comment`), and set the kanban to **`needs_clarity`**
   (`qx_task_status "$TASK_ID" needs_clarity`). Exit the pipeline. This is the **only** failure
   terminus. Make the note say which kind of failure it was: a `needs_setup` wants provisioning
   fixed, not the task re-planned.

8. **GIT-WORKFLOW** (`git-workflow`, sonnet) — re-read every `.quetrex/` gate artifact from disk
   (no ESCALATION; ledger green; no open Critical; verdict `AUTO_MERGE` pinned to HEAD with a
   completed native security pass), re-prove the full chain at HEAD to re-pin the ledger in this
   worktree, then push and open the **PR** into `BASE_BRANCH` (`main` for a standalone task; the
   integration branch for an epic child). Capture the PR number / URL.

   **This stage adds no commit.** Everything is already committed by step 4 and step 5, so HEAD is
   the exact commit the verdict is pinned to. If it finds uncommitted work, it refuses rather than
   committing — a commit here would move HEAD past the reviewed sha and the merge gate would
   correctly refuse the merge. Any gate red → REFUSED, recorded in `state.json`, no PR.

9. **Kanban: `pr_ready`.** On PR open, `qx_task_status "$TASK_ID" pr_ready`; post a comment with
   the PR URL via `qx_task_comment`.

10. **Teardown** per `worktree-workflow`: the pipeline leaves **no dangling worktree or sub-branch
    of its own**. The unit branch and its PR remain.

---

## The merge, which is outside this engine

Merging the PR is a later step and is **gated mechanically, not by a command and not by a prompt**.
The `merge-gate.sh` PreToolUse hook allows `gh pr merge` (or a direct merge/push to the default
branch) only when, **for the exact commit being merged**: `ESCALATION` is absent, the review
verdict is `AUTO_MERGE` with `.sha == HEAD`, every command in the verify chain has a most-recent
ledger line that is `exit 0` and pinned to HEAD, and no security finding is open + Critical. There
is no human-approval override and no separate merge command — the gate is the whole mechanism. For
an epic child, the epic DAG merges into the integration branch under the same gate.

Only **production deploy** remains a manual human step.

---

## Status transitions owned by the engine

- `*` → `in_progress` — first pipeline action (step 2).
- `in_progress` → `pr_ready` — PR opened (happy path, step 9).
- `in_progress` → `needs_clarity` — bounded-loop exhaustion, missing provisioning, hard blocker, or
  unanswerable ambiguity (step 7), always with an AI-note.

The engine **never** sets `merged` / `deployed` / `complete` — `merged` follows the gated merge
above, and `deployed` / `complete` are the manual deploy and its confirmation, all outside this
engine.

---

## Artifacts the stages exchange (all under `.quetrex/`, all read from disk, never from chat)

| Artifact | Written by | Read by |
|---|---|---|
| `plan/<TASK_ID>.json` | architect | developer, database-architect, qa, reviewer, security-reviewer, merge-gate |
| `verify.json` | `/quetrex:init` (project config) | every stage, verify-gate, merge-gate |
| `verify-ledger.jsonl` | qa, git-workflow, verify-gate | reviewer, git-workflow, merge-gate |
| `qa-report.json` | qa | reviewer |
| `security-findings.json` | security-reviewer | reviewer, git-workflow, merge-gate |
| `review-verdict.json` | reviewer **only** | git-workflow, merge-gate |
| `state.json` | **created by the engine at step 2** (`.task`, `.base_branch`, `.branch`, `.review_iter: 0`); then merged into by reviewer (`.review_iter` only) and git-workflow (refusal reason) | reviewer, git-workflow, merge-gate (GATE 5 plan resolution), session-state.sh |
| `ESCALATION` | verify-gate, reviewer | reviewer, git-workflow, merge-gate |

Two rules hold across the whole table: **every artifact that authorizes a ship is pinned to a
commit sha**, and **no stage re-points another stage's pin**. Re-proving the ledger by re-running
the commands is legitimate (the evidence is regenerated); editing a verdict's sha is not (the
judgment would be relabelled without being re-made).

---

## The two env shape contracts

Two artifacts carry environment-variable information between stages that cannot see each other's
source. Each has exactly one shape, decided **here** and nowhere else — `.claude/agents/architect.md`
and `bin/quetrex-cloud-prep` both cite this section by name ("Contract A"/"Contract B" in **The two
env shape contracts**) instead of re-specifying the shape, precisely so four files never guess at
it independently and drift.

### Contract A — `required_env` (the plan field)

`required_env` is an **array of OBJECTS**, never of bare strings and never a `{NAME: value}` map.
Each entry carries exactly these four keys and no others:

- `name` — the variable name **alone** (no `$`, no `process.env.` prefix, no value, ever). **The
  only key any consumer projects.**
- `read_at` — `file:line` of the fallback-less read that demands it, repo-root relative.
- `placeholderable` — `true` iff a syntactically valid, credential-less placeholder value satisfies
  that read for the whole `verify` chain.
- `why` — one sentence naming the verify command that needs it.

**Produced by:** the **architect**, from its own fallback-less grep unioned with whatever
`bin/quetrex-env-derive verify-json` already wrote into the committed `.quetrex/verify.json`'s
`requiredEnv` map (it reads that file at plan time — see step 3 above); and then, deterministically,
by the **dispatcher** (`/quetrex:task-build`), which calls `bin/quetrex-env-derive plan
"$TMP_WT/.quetrex/plan/$TASK_ID.json" "$REPO_ROOT"` immediately after `quetrex-plan-stamp`, before
the spec worktree is committed and pushed. The dispatcher call exists because the architect's
frontmatter grants `tools: Read, Grep, Glob, Write` with **no Bash**, so it cannot run the shared
discovery tool itself — the stamp is a union-only backstop that repairs a miss, never a
replacement for the architect's own entries.

**Consumed by:** `bin/quetrex-cloud-prep hydrate`, which projects `.name` **only** —
`(plan.required_env || []).map(e => e && e.name).filter(...)` — and writes one credential-less
placeholder `export` per name into a sourceable env file. The measured defect this shape closes: an
earlier, wrong projection (`.join("\n")` over the object array) collapsed to the literal string
`"[object Object]"`, hydrated nothing, and the run still exited 0 — the whole feature silently
inert while every gate stayed green.

### Contract B — `env_placeholdered` (the provenance field)

Written by `bin/quetrex-cloud-prep hydrate` into `.quetrex/env-provenance.json`, alongside
`required_env` (a verbatim mirror of the plan's array — informational only, read by no consumer)
and `hydrated_at`. `env_placeholdered` is a **flat array of NAMES ONLY, never values** — exactly
the names hydrate actually placeholdered, nothing more. The measured defect this shape closes: a
producer/consumer key-name mismatch (`env_placeholdered` written, `.placeholdered` read) silently
degraded a positive claim ("this chain ran against real placeholders") into an empty list — which
reads as "this chain proved itself against the real environment," **inverting** the evidence rather
than merely losing it.

### The shared discovery tool

Both projections come from **one** static discovery pass, `bin/quetrex-env-derive`, so the
candidate-selection rule (a committed `.env.example`/`.env.sample` key intersected with a
fallback-less read in tracked source) and the command-attribution rule (scope-filtered through the
chain command's own leaf script, resolved through the repo's own manifest) are never re-specified
in a second place:

- `quetrex-env-derive verify-json <repo-root>` writes the `requiredEnv` map into the COMMITTED
  `.quetrex/verify.json` that `verify-gate.sh`'s declarative env skip reads — called from
  `/quetrex:init` step 4b.
- `quetrex-env-derive plan <plan.json> <repo-root>` stamps Contract A `required_env[]` entries into
  a plan artifact — called from the `/quetrex:task-build` dispatcher, one line after
  `quetrex-plan-stamp`.
- `quetrex-env-derive missing <repo-root>` is report-only, used by `/quetrex:doctor` Check 5.

Both writing subcommands are **union-only and never-narrow**: they add names, never remove or
narrow an existing entry, and neither ever writes a `requiredEnv`/`required_env` key that is not
already a member of the resulting `.verify[]`. Static discovery only — the tool never executes,
evals, or shells out to a string it reads from `verify.json`, a `package.json` script, or a
Makefile recipe.

---

## Background + visibility

The caller does **not** parse engine output inline. Progress is visible on the board (status
column + comments + AI-notes) and, when dispatched via the Workflow tool, through `/workflows`.
The state of truth is the kanban; callers poll it (status + dependencies + `isBlocked`), they do
not read the run's stdout.
