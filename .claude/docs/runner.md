# Runner — Design Doc

Full design reference for the `/runner` command. Read this alongside the command file
(`.claude/commands/runner.md`), which has the concrete steps and GraphQL snippets. This doc
covers the rationale, the algorithm, the schema, and the edge cases.

See `.claude/docs/linear-states.md` for the canonical state-key definitions and the resolution
pattern every command uses.

---

## 1. What the runner is

One runner = one local CC session = one project = one tab.

The runner is a **continuous queue dispatcher**. It sits in a long-lived session, polls the
project's `queued` column, and fires off up to 3 background worktree agents in parallel, each
running the full Glori Builder pipeline. It runs until you tell it to stop.

Three design decisions set it apart from `/auto-pilot`:

### 1a. Terminus: `ready`, not `complete`

`/auto-pilot` is the deliberate exception to the manual-gate rule: it auto-merges PRs and sets
issues straight to `complete`. The runner is the opposite. It **stops at `ready`** (AI: PR Ready).
Every PR it produces waits for a human `/merge-issue → /deploy → /complete` before the issue is
closed. This is the default pipeline behavior; auto-pilot is the exception.

### 1b. Execution model: background agents, not inline pipelines

`/auto-pilot` runs each pipeline inline, sequentially, in the driving session. A long-lived
dispatcher session cannot do this — running even one pipeline inline would eventually blow the
session's context. The runner instead **spawns each pipeline as a separate background worktree
agent**. The dispatcher session never executes architect/developer/QA steps itself; it only
tracks slots. This is a hard architectural constraint, not a preference.

This is also why the dispatcher can safely run `/compact` at 70% context (see §5): the
in-flight work is in harness-tracked background agents, not in the conversation, so compacting
the dispatcher loses nothing except the in-memory slot table — which is immediately
reconstructed from Linear + the state file via Phase 1 auto-recovery.

### 1c. Readiness rule: `merged = unblocked`

`/auto-pilot` treats a blocker as satisfied only when it reaches `complete` (the last gate). The
runner uses **`merged = unblocked`**: a blocking issue is considered resolved as soon as its PR
is merged to `main`. The code is live; the downstream issue can proceed. The manual
deploy/verify steps that follow should not stall N other issues waiting in the queue.

Concretely: when evaluating whether a queued issue is ready to start, the runner checks each
blocker's Linear state against the `merged` column name (resolved from the map) **and any
column that comes after it** (typically `deployed`, `complete`). All of these count as
"unblocked." This list is built by resolving the canonical keys `merged`, `deployed`, and
`complete` from the map and collecting their state names; never hardcoded.

**Important:** `merged = unblocked` trusts the Linear `merged` column, which `/merge-issue`
sets when it squash-merges the PR. A raw GitHub merge that bypasses `/merge-issue` will not
advance the Linear state, so blockers merged that way will still appear unresolved to the
runner and downstream issues will stall. Always use `/merge-issue` to close the gate.

---

## 2. Dispatcher loop algorithm

```
on every tick (default 120 s):
  1. FREE COMPLETED SLOTS
     for each in_flight slot:
       query the issue's current Linear state
       if state == ready      → move slot to history (outcome: ready),
                                add Linear comment "Reached PR Ready — awaiting manual /merge-issue."
       if state == needs_help → move slot to history (outcome: needs_help)
       if state == in_progress → leave slot occupied
       else (human moved it)  → move slot to history (outcome: human_moved)

  2. REFILL (skip if draining)
     while in_flight_count < concurrency_cap (3):
       query queued column, ordered by sortOrder, include relations
       skip any issue whose UUID is already in the slot table (intra-runner dedup)
       find first issue where all blockers are in merged-or-later:
         blocker = any relation where { type: "blocks", relatedIssue: Y }
                   on the queued issue's own `relations` list
                   (Y is the blocker; "blocks" on issue X means X is blocked by Y)
         satisfied when Y's state name is in { MERGED_STATE_NAME, DEPLOYED_STATE_NAME, COMPLETE_STATE_NAME }
                   (resolved from map, never hardcoded)
       if no ready issue found: break

       # CLAIM
       flip issue queued → in_progress via issueUpdate
       record slot: { identifier, branch, agentRef: pending, status: "in_flight", claimedAt, ... }
       rewrite state file immediately (before spawn — slot is the dedup fence)

       # SPAWN
       background agent, isolation: "worktree"
       update slot.agentRef with returned task reference
       runs full pipeline: architect → [designer] → developer(s) → QA (≤3) → reviewer → git-workflow
       STOPS at ready — never merges, deploys, or completes

  3. IDLE HANDLING
     if in_flight_count == 0 and no ready queued issues:
       log idle heartbeat (at most once per 10 ticks)
       stay alive — runner is continuous

  4. WRITE HEARTBEAT
     update state file: heartbeat = current UTC timestamp
     (the single-runner guard on next launch reads this)

  5. CONTEXT GUARD
     if context usage ≥ 70%: run /compact before next tick
```

---

## 3. State-file schema

One file per project: `.claude/runner-{PROJECT_SHORT_ID}.json`

`PROJECT_SHORT_ID` is the first 8 characters of the Linear project UUID. This keeps filenames
short and unambiguous even if multiple projects are running in separate tabs.

```json
{
  "projectId": "PROJECT_UUID",
  "projectName": "Glori Builder",
  "teamId": "TEAM_UUID",
  "startedAt": "ISO_TIMESTAMP",
  "heartbeat": "ISO_TIMESTAMP",
  "pollIntervalSec": 120,
  "concurrency": 3,
  "draining": false,
  "slots": {
    "<issueUUID>": {
      "identifier": "GLO-57",
      "branch": "feature/glo-57-add-runner-command",
      "agentRef": "<harness background task ref>",
      "status": "in_flight",
      "retries": 0,
      "claimedAt": "ISO_TIMESTAMP",
      "lastCheckedAt": "ISO_TIMESTAMP"
    }
  },
  "history": [
    {
      "identifier": "GLO-55",
      "outcome": "ready",
      "pr": 81,
      "at": "ISO_TIMESTAMP"
    }
  ]
}
```

### Field notes

- `heartbeat`: updated to current UTC on every tick. The single-runner guard on launch reads
  this; a heartbeat newer than 2 × `pollIntervalSec` means a runner is active and refuses to
  start a second one. A stale heartbeat (older than 2 poll intervals) means the runner crashed
  or the tab was closed — Phase 1 auto-recovery takes over.
- `slots`: holds only currently-tracked issues. In-flight count = number of entries with
  `status: "in_flight"`. When a slot finishes, its entry moves to `history` and the slot frees.
  The slot table is also the intra-runner dedup fence: the dispatcher never claims an issue
  whose UUID is already a key here.
- `history`: append-only log of completed/failed issues. Never truncated (grow-only in v1).
- `draining`: when `true`, the refill step is skipped. The loop continues until all in-flight
  slots reach `ready` or `needs_help`, then the runner exits.
- `agentRef`: the harness background task reference returned when the agent was spawned. Set to
  `"pending"` between the claim write and the spawn call; updated to the real task ref once the
  agent starts. On Phase 1 recovery, re-dispatched slots get a new `agentRef` from the
  freshly spawned agent.
- `retries`: not used by the dispatcher directly (the background pipeline tracks its own QA
  retries), but recorded for audit. The pipeline sets `needs_help` on 3 failures; the dispatcher
  reads that from Linear state.
- The file is rewritten after every slot change (claim, free, drain flag, heartbeat). A fresh
  dispatcher always trusts **Linear over the stale file**: Phase 1 reconciliation wins on every
  launch.

---

## 4. Claim-lock protocol

The dispatcher must not start the same issue twice — whether within a single session or across
two independent runner sessions for the same project.

**Why the Linear state flip alone is not a lock.**

Both a claim and a duplicate claim flip the issue to the same target state (`in_progress`). Both
`issueUpdate` mutations succeed. A re-read after the flip returns `in_progress` for both callers
— there is no loser. The idempotent write provides no mutual exclusion. A design that relied on
this would silently double-claim issues and spawn two pipeline agents for each.

**The actual lock is two-layer:**

1. **Single-runner-per-project guard (Phase 0d).** On every launch, the dispatcher checks the
   state file's `heartbeat` timestamp. A heartbeat newer than 2 × `pollIntervalSec` means
   another runner is alive — the new launch refuses to start. The heartbeat is updated every tick
   so an active runner continuously renews its claim to the project. This eliminates the
   two-independent-runners race entirely.

2. **Slot-table dedup (intra-runner).** Within a single dispatcher session, ticks are
   sequential. Before claiming an issue, the dispatcher checks whether its UUID is already in the
   `slots` table. If it is, the issue is skipped. The slot is written to the state file
   **before** the agent is spawned, so even a mid-tick crash (where the agent never starts) is
   recovered by Phase 1 reconciliation: the issue is in `in_progress` in Linear with no live
   branch/PR, so Phase 1 resets it to `queued` and removes the stale slot.

**Running two runners for the same project is unsupported and actively blocked** by the
heartbeat guard. It is not a "wasteful but harmless" configuration — without the guard, it is
the expected failure mode (both runners claim the same issues). The guard makes it a hard error
at launch time.

---

## 5. Context compaction safety

The dispatcher runs a compaction guard at 70% context usage (`/compact` before the next tick).

**Why this is safe:**

All in-flight pipeline work runs as harness-tracked background agents. These agents have their
own execution contexts; they do not live in the dispatcher's conversation. Compacting (or
completely restarting) the dispatcher session does not interrupt or cancel any running agent.

The state file is the source of truth. After compaction or restart, Phase 1 auto-recovery
reconstructs the slot table:
- Issues in `in_progress` with a live branch or open PR: re-dispatch with a fresh agent.
- Issues in `in_progress` with no branch or PR: reset to `queued`.
- Issues already at `ready` or `needs_help`: free the slot, log to history.

The dispatcher can be compacted on any tick boundary without losing work.

---

## 6. Auto-recovery reconciliation

Run on every launch (fresh start, `--resume`, post-compaction restart) before claiming anything.

**Goal:** reconcile Linear reality with the state file. Linear is the authoritative record; the
state file is a local cache and must yield to it.

### Steps

1. Query all issues in the project's `in_progress` column.
2. For each:
   a. Does an open PR exist whose branch name contains the lowercase identifier followed by `-`?
      Use `gh pr list --state open --json number,headRefName` and check for `<identifier>-` in
      the branch name (anchored to prevent `glo-5` matching `glo-51` or `glo-57`).
   b. Does a pushed remote branch exist with an anchored match?
      `git ls-remote --heads origin "*<identifier-lower>-*"` (trailing `-` anchors the prefix).
   - YES to either → live progress exists, but the agent that was driving it is dead. **Re-dispatch:**
     spawn a fresh background worktree agent (isolation: "worktree") that resumes from the
     existing branch and drives the issue to `ready`. Update the slot entry with the new
     `agentRef` and keep `status: "in_flight"`. A recovered slot MUST have a live agent; passive
     "keep" with no agent would stall the slot until the dispatcher is closed.
   - NO to both → no real progress. Reset: `issueUpdate` back to `queued`. Remove from slots.
3. For each slot in `slots` with `status: "in_flight"` that was NOT handled in step 2:
   - Fetch the issue's current Linear state.
   - If it is `ready` or `needs_help` (finished while the dispatcher was down): free the slot,
     add to history.
   - If it is still `in_progress` but has live progress: already handled above.

### Tab-close recovery

Closing the runner tab is a hard stop. No cleanup runs at stop time. The next launch's Phase 1
handles it:

- Any `in_progress` issues that produced a branch/PR before the tab closed: re-dispatched with
  a fresh agent. The new agent resumes from the existing branch.
- Any `in_progress` issues with no branch/PR (claimed but not yet started, or the agent was
  just spawned and hadn't pushed yet): reset to `queued`. They will be re-claimed on the next
  poll tick.

If the original "lost" agent somehow continued running in the harness after the tab closed and
reaches `ready` or `needs_help` independently, the dispatcher will see the state change on the
next tick and free the slot. The re-dispatched agent will find the issue already in `ready` and
exit cleanly. The PR opened by whichever agent finished first stands; the duplicate is harmless
(one will be a no-op or close-without-merging). This overlap scenario is rare and recoverable.

---

## 7. Stop controls

### `/runner stop` — graceful drain

Sets `draining: true` in the state file. The dispatcher loop continues but skips the refill
step. It keeps ticking until all in-flight slots reach `ready` or `needs_help`, then exits with
a summary.

Use this when you need the runner to finish what it has started without picking up new work.
Typical usage: before a maintenance window, before switching branches, before running a large
refactor that would conflict with in-flight branches.

### Tab close — hard stop

Immediate. No drain. Phase 1 on the next launch cleans up. The runner is designed so that tab
close is always recoverable — it is a first-class stop mode, not an error condition.

### `--resume`

Loads the most recent state file, runs Phase 1, and resumes Phase 2. Use this after any
interruption: tab close, session timeout, manual `/compact`, machine sleep, etc.

---

## 8. Divergence from auto-pilot — summary table

| Axis | `/runner` | `/auto-pilot` |
|---|---|---|
| Concurrency | 3 parallel, continuous | 1 sequential, batch |
| Terminus | `ready` (PR open) | `complete` (PR merged + deployed + signed off) |
| Blocker rule | `merged` = unblocked | `complete` = unblocked |
| Pipeline execution | Background worktree agents | Inline in session |
| Continuous | Yes — never exits while queue has issues | No — exits when queue empties |
| Manual gates | `/merge-issue`, `/deploy`, `/complete` remain human | All bypassed |
| Map required | Yes — hard stop if missing | No — type-fallback available |

Both commands resolve states from the `## Linear States` map. Neither hardcodes column names.
`auto-pilot.md` is untouched by the runner's implementation.

---

## 9. What the runner does NOT do

- It does not merge PRs.
- It does not deploy.
- It does not run `/complete`.
- It does not parse agent output inline — it polls Linear state on each tick.
- It does not provide real-time logs from background agents — check the harness task list for
  individual agent progress.
- It does not support multiple projects in a single runner session — one runner, one project,
  one tab.
