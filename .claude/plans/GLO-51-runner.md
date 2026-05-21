# GLO-51 — Background Runner: continuous local-session queue runner

**Branch:** `feature/GLO-51-background-runner-continuous-local-session-q`
**Type:** markdown command/skill authoring (no application code)
**designer_required:** **false** — CLI/markdown feature, no UI surface.

---

## 1. Decision: new `/runner` command (NOT `--watch` flags on `/auto-pilot`)

**Resolved: build a new `/runner` command.**

The runner and auto-pilot diverge on three load-bearing axes that flags cannot reconcile:

1. **Terminus contract.** Auto-pilot is the *deliberate exception* to the manual-gate rule: it
   auto-merges PRs and sets each issue straight to `complete` ("vibe coding on steroids"). The
   runner does the opposite — it **stops at `ready` (AI: PR Ready)** and leaves `/merge`,
   `/deploy`, `/complete` as human gates. Same code path, opposite end-state.
2. **Execution model.** Auto-pilot runs each pipeline **inline and sequentially** in the driving
   session. The runner must run **up to 3 pipelines concurrently in spawned background worktree
   agents** while the dispatcher session stays lean (never runs a pipeline inline — that is a hard
   constraint, the long-lived session would blow its context). This is a different architecture,
   not a flag.
3. **Readiness rule.** Auto-pilot treats a blocker as satisfied only when the blocking issue is
   `complete`. The runner uses **merged = unblocked** so that the manual deploy/verify gates never
   stall downstream work.

A `--watch`/`--concurrency` flag would give auto-pilot two personalities and force a `if mode ==
watch` branch into nearly every step (state transitions, blocker check, terminus, the run loop
itself). A separate `/runner` keeps both commands coherent and lets them evolve independently.
They **share** the state-resolution machinery (already centralized in
`.claude/docs/linear-states.md`) and the 3-strike rule (re-stated, not imported, since command
markdown has no include mechanism). Auto-pilot is left untouched.

---

## 2. Implementation plan

### Deliverables

| File | New/Modify | Purpose |
|---|---|---|
| `.claude/commands/runner.md` | **new** | The `/runner` dispatcher command — the whole feature. |
| `.claude/docs/runner.md` | **new** | Design doc: dispatcher loop, state schema, claim-lock, readiness rule, recovery, controls. Referenced by the command (keeps the command lean, same pattern as `linear-states.md`). |
| `.claude/commands/quetrex-docs.md` | **modify** | Add `/runner` to the command catalog + a "continuous runner" workflow stanza. |
| `.claude/docs/linear-states.md` | **modify** | Add a one-line note that `/runner` is automatic from `queued` and (like the normal pipeline) stops at `ready`; document the `merged = unblocked` readiness rule used by the runner. |

> No `/loop` or `ScheduleWakeup` primitive exists in the repo today — these are harness mechanisms
> the runner *uses*, not files it owns. The command authors the polling cadence against the harness
> `/loop` + `ScheduleWakeup` capability; nothing in `.claude/` defines them, so nothing there is
> modified for them.

---

### `.claude/commands/runner.md` — the dispatcher command

Frontmatter:
```yaml
---
description: Continuous local-session queue runner. Polls a project's Queued column and works up to 3 issues at once through the full pipeline to PR Ready, in spawned background worktree agents. Auto-pilot that never stops — but stops at PR Ready (manual merge/deploy/complete gates). Runs inside one CC session = one project = one tab.
argument-hint: <LINEAR-PROJECT-ID | stop | --resume>
---
```

The command body specifies, in order:

#### Phase 0 — Preflight (reuse auto-pilot's checks)
- `LINEAR_API_KEY` set; `gh auth status` ok; git clean.
- Resolve the project's `## Linear States` map (`queued`, `in_progress`, `ready`, `needs_help`,
  `merged`). **Stop and tell the user to run `/map-states` if no map exists** — the runner must not
  type-fallback for `in_progress`/`merged`/`ready` (all commonly `type: "started"`; ambiguous).
- Subcommand dispatch on `$ARGUMENTS`:
  - `stop` → Phase 4 (graceful drain).
  - `--resume` → load latest state file, run Phase 1 recovery, continue Phase 2.
  - a project id → fresh start.

#### Phase 1 — Launch & auto-recover reconciliation
On every launch (fresh or resume), before claiming anything:
1. Load or create the state file (schema below).
2. Query all issues currently in the project's `in_progress` column.
3. For each `in_progress` issue, reconcile against reality:
   - **Live progress exists** → leave it. "Live progress" = an open PR whose branch matches the
     issue identifier (`gh pr list --state open --json number,headRefName`) **OR** a pushed remote
     branch matching the identifier (`git ls-remote --heads origin "*<identifier>*"`).
   - **No real progress** → reset it: move the issue back to `queued`, drop it from the state
     file's in-flight slots. It becomes reclaimable on the next poll.
4. Reconcile the in-flight slot table: any slot whose issue is no longer `in_progress` in Linear
   (e.g. a human moved it, or it reached `ready`) is freed.

> Closing the tab is a hard stop; the next launch's Phase 1 cleans up any orphaned `in_progress`
> issues that never produced a branch/PR.

#### Phase 2 — Dispatcher loop (LEAN; never runs a pipeline inline)
Repeat on an interval via the harness `/loop` + `ScheduleWakeup` (default poll **120 s**, settable
later). Each tick:

1. **Free completed slots.** For each in-flight slot, check its background agent's status (harness
   task status) and the issue's Linear state:
   - Agent finished and issue is at `ready` → mark slot `done`, free it. Add Linear comment
     "Reached PR Ready — awaiting manual /merge-issue."
   - Agent finished and issue is at `needs_help` → mark slot `needs_help`, free it (the background
     pipeline already moved it on 3-strike / blocker; see below).
   - Agent still running → leave the slot occupied.
2. **Refill up to the cap.** While `in-flight count < 3`:
   - Poll the `queued` column, sorted by `sortOrder`, including `relations` (to evaluate blockers).
   - Pick the first **ready-to-run** queued issue (readiness rule below). If none, break.
   - **Claim it (the lock):** atomically flip the issue `queued → in_progress` via `issueUpdate`,
     and record the slot in the state file in the same tick. **The Linear state transition IS the
     lock** — the runner only ever selects issues still in `queued`, so re-polling and other
     parallel sessions can never double-start the same issue. Re-read the issue's state
     immediately after the flip; if it is not `in_progress` (lost a race), discard and pick the
     next.
   - **Spawn a background worktree agent** for the claimed issue (see "Spawned pipeline agent").
     The dispatcher records `{agentRef, branch, claimedAt}` and moves on — it does **not** wait.
3. **Idle handling.** If no slots are occupied and the queue has no ready issues, the runner stays
   alive and keeps polling (it is a *continuous* runner). It logs an idle heartbeat at most once
   per N ticks so the tab isn't noisy.
4. **Context guard.** If dispatcher context usage ≥ **70%**, run `/compact` before the next tick.
   Compaction is safe: in-flight pipelines run as **harness-tracked background agents**, not
   conversation state, and the state file is the source of truth — a compacted (or fully restarted)
   dispatcher reconstructs every slot from Linear + the state file via Phase 1.

#### Readiness rule (merged = unblocked) — runner-specific
An `queued` issue is **ready to run** iff every issue it is *blocked by* (Linear relation
`type: "blocks"` pointing at it) is in the `merged` column **or any state at/after merged**
(`merged`, `deployed`, `complete`). Resolve those column names from the map. This differs from
auto-pilot (which requires `complete`). Rationale: a blocker's code is on `main` once its PR is
merged; the manual deploy/verify gates that follow must not stall downstream issues. State this
divergence explicitly in `runner.md` and `docs/runner.md`.

#### Spawned pipeline agent (per claimed issue)
Each claim spawns ONE background agent, `isolation: "worktree"`, that runs the **existing pipeline
to `ready` and stops** — identical to `/issue-prd`'s hand-off, minus the intake fetch/branch steps
the dispatcher already performed. The agent:
1. Creates the feature branch `feature/<identifier>-<slug>` from fresh `main` (inside its worktree).
2. Runs: architect → designer (if flagged) → developer(s) in parallel sub-worktrees → merge
   sub-branches → QA (≤3 retries) → reviewer → git-workflow (opens PR, sets `ready`).
3. **3-strike / hard blocker / unanswerable ambiguity → move issue to `needs_help`**, add a Linear
   comment with the failure detail, and exit. (Reuse the auto-pilot / issue-prd fail rule verbatim.)
4. **STOPS AT `ready`.** Never merges, deploys, or completes. git-workflow setting `ready` is the
   terminus.
The dispatcher learns the outcome from the agent's terminal status + the issue's Linear state on
the next tick — it does not parse agent output inline.

#### Phase 4 — Stop controls
- **`/runner stop` = graceful drain.** Set a `draining: true` flag in the state file. The loop
  stops claiming new issues (skip Phase 2 step 2) but keeps ticking until all in-flight slots reach
  `ready` or `needs_help`. When the in-flight count hits 0, write a final summary and exit the loop.
- **Closing the tab = hard stop.** No cleanup runs at stop time; the next launch's Phase 1
  auto-recover reconciles any orphaned `in_progress` issues (reset to `queued` if no branch/PR).

#### Phase 5 — Summary (on drain/exit)
Report counts: reached PR Ready, moved to needs_help, still queued; the state-file path; and the
reminder that `/merge-issue`, `/deploy`, `/complete` are the human gates from here.

---

### State-file schema
`.claude/runner-<projectId-short>.json` (one per project; resumable, source of truth):

```json
{
  "projectId": "PROJECT_UUID",
  "projectName": "Glori Builder",
  "startedAt": "ISO_TIMESTAMP",
  "pollIntervalSec": 120,
  "concurrency": 3,
  "draining": false,
  "slots": {
    "<issueId>": {
      "identifier": "GLO-57",
      "branch": "feature/glo-57-...",
      "agentRef": "<harness background task ref>",
      "status": "in_flight | ready | needs_help | done | reset",
      "retries": 0,
      "claimedAt": "ISO_TIMESTAMP",
      "lastCheckedAt": "ISO_TIMESTAMP"
    }
  },
  "history": [
    { "identifier": "GLO-55", "outcome": "ready", "pr": 81, "at": "ISO" }
  ]
}
```

Notes for the implementer:
- `slots` holds only currently-tracked issues; on completion an entry moves to `history` and the
  slot frees. In-flight count = number of `slots` entries with `status: "in_flight"`.
- The file is rewritten each tick after slot/claim changes. A fresh dispatcher trusts Linear over a
  stale file: Phase 1 reconciliation always wins.
- Use a short, filesystem-safe project id segment in the filename so multiple projects don't collide
  (one runner per project per tab, but the file naming should still be unambiguous).

---

### Conventions to follow (house style)
- Match the prose/structure of `auto-pilot.md`: `## Phase` headings, fenced `bash`/`json` blocks,
  GraphQL via `curl` to `https://api.linear.app/graphql` with `$LINEAR_API_KEY`.
- **Never hardcode a column name** ("Queued", "Done", etc.). Resolve every state through the
  `## Linear States` map; reference `.claude/docs/linear-states.md` for the resolution order.
- Stop with a `/map-states` prompt when the map is missing (no type-fallback for the ambiguous
  `started`-type columns the runner depends on).
- Keep the command lean — push the long explanatory material (loop algorithm narrative, schema
  rationale, recovery edge cases) into `.claude/docs/runner.md` and link to it, mirroring how
  auto-pilot/issue-prd link to `linear-states.md`.

---

## 3. File ownership map (zero overlap)

Two workstreams. **Dependency order: A must merge before B starts** (B edits the catalog/state docs
to describe the command A creates, so A's terminology and filenames must be fixed first). Within A,
the two new files have no overlap but are one authoring unit owned by a single developer.

### Workstream A — Runner command + design doc  *(start first)*
Owns, exclusively:
- `.claude/commands/runner.md`  *(new)*
- `.claude/docs/runner.md`  *(new)*

Scope: author the dispatcher command and its design doc per Section 2. Self-consistent: the command
links to the doc; the doc fully specifies the loop, schema, claim-lock, readiness rule, recovery,
and stop controls.

### Workstream B — Documentation integration  *(after A)*
Owns, exclusively:
- `.claude/commands/quetrex-docs.md`  *(modify)*
- `.claude/docs/linear-states.md`  *(modify)*

Scope:
- `quetrex-docs.md`: add `/runner PROJECT-ID` to the "Pipeline" command table and add a
  "Continuous runner (walk-away, N-wide, stops at PR Ready)" workflow stanza distinct from the
  auto-pilot stanza (make the contrast explicit: runner does NOT auto-merge).
- `linear-states.md`: add a short note that `/runner` is automatic from `queued` and stops at
  `ready` like the normal pipeline (contrast with `/auto-pilot`), and document the runner's
  `merged = unblocked` readiness rule alongside the existing state machine.

**No file is touched by both workstreams.** `auto-pilot.md` is intentionally **not** modified by
anyone.

---

## 4. Acceptance criteria

Structural / content checks (this repo's deliverables are markdown; verification is structural):

**Workstream A — `runner.md` + `docs/runner.md`**
1. `.claude/commands/runner.md` exists with valid frontmatter (`description`, `argument-hint`) in
   the same style as `auto-pilot.md`.
2. Command documents all four mechanisms explicitly:
   - dispatcher loop: poll → free slots → claim → spawn background worktree agent → refill;
   - claim-lock via the `queued → in_progress` state flip, with the post-flip re-read race guard;
   - `merged = unblocked` readiness rule, explicitly noting it differs from auto-pilot's `complete`;
   - auto-recover reconciliation on launch (live PR/branch ⇒ keep; no progress ⇒ reset to `queued`).
3. Spawned-pipeline section states the agent runs `isolation: "worktree"` and **stops at `ready`** —
   never merges/deploys/completes.
4. Concurrency cap of **3** in flight, with refill as slots free.
5. 3-strike QA failure ⇒ `needs_help` + free slot + continue (matches auto-pilot's rule).
6. Both stop controls present: `/runner stop` = graceful drain (stop claiming, finish in-flight to
   PR Ready, exit); tab close = hard stop recovered on next launch.
7. State-file schema documented and matches Section 2 (slots, in-flight count, draining flag,
   history, resumable).
8. 70% context-compaction guard documented, with the rationale that background agents are
   harness-tracked so compaction is safe.
9. **No hardcoded Linear column names** anywhere in either file — every state resolved through the
   map; missing-map path stops with a `/map-states` prompt.
   Verify: `grep -nE '"(Queued|In Progress|PR Ready|Merged|Done|Complete)"' .claude/commands/runner.md .claude/docs/runner.md` returns nothing in a hardcoding context.
10. The dispatcher is explicitly described as **lean** — it never runs a pipeline inline; heavy
    context lives in spawned agents.
11. `runner.md` links to `.claude/docs/runner.md` and to `.claude/docs/linear-states.md`; both link
    targets exist.

**Workstream B — docs integration**
12. `/runner` appears in the `quetrex-docs.md` command catalog with an accurate one-line summary.
13. `quetrex-docs.md` has a runner workflow stanza that explicitly contrasts with auto-pilot
    (runner stops at PR Ready / does not auto-merge).
14. `linear-states.md` documents the runner as `queued → ready` automatic and the `merged =
    unblocked` readiness rule; no contradiction with the existing state machine.

**Global**
15. All internal doc links resolve (no dangling `.claude/...` paths).
16. `auto-pilot.md` is unchanged (`git diff --name-only` does not list it).

---

## 5. designer_required

**false** — the runner is a CLI/markdown orchestration command with no UI surface. No design spec
needed.
