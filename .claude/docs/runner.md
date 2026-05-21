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

---

## 2. Dispatcher loop algorithm

```
on every tick (default 120 s):
  1. FREE COMPLETED SLOTS
     for each in_flight slot:
       query the issue's current Linear state
       if state == ready     → move slot to history (outcome: ready),
                               add Linear comment "Reached PR Ready — awaiting manual /merge-issue."
       if state == needs_help → move slot to history (outcome: needs_help)
       if state == in_progress → leave slot occupied
       else (human moved it) → move slot to history (outcome: human_moved)

  2. REFILL (skip if draining)
     while in_flight_count < concurrency_cap (3):
       query queued column, ordered by sortOrder, include relations
       find first issue where all blockers are in merged-or-later (readiness rule)
       if no ready issue found: break

       # CLAIM (the lock)
       flip issue queued → in_progress via issueUpdate
       re-read the issue state immediately
       if state != in_progress: lost the race → discard, try next candidate
       record slot: { identifier, branch, agentRef, status: "in_flight", claimedAt, ... }
       rewrite state file

       # SPAWN
       background agent, isolation: "worktree"
       runs full pipeline: architect → [designer] → developer(s) → QA (≤3) → reviewer → git-workflow
       STOPS at ready — never merges, deploys, or completes

  3. IDLE HANDLING
     if in_flight_count == 0 and no ready queued issues:
       log idle heartbeat (at most once per 10 ticks)
       stay alive — runner is continuous

  4. CONTEXT GUARD
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

- `slots`: holds only currently-tracked issues. In-flight count = number of entries with
  `status: "in_flight"`. When a slot finishes, its entry moves to `history` and the slot frees.
- `history`: append-only log of completed/failed issues. Never truncated (grow-only in v1).
- `draining`: when `true`, the refill step is skipped. The loop continues until all in-flight
  slots reach `ready` or `needs_help`, then the runner exits.
- `agentRef`: the harness background task reference returned when the agent was spawned. Used to
  check agent completion status. On recovery, set to `"recovered"` for slots reconstructed from
  Linear state without a live agent reference.
- `retries`: not used by the dispatcher directly (the background pipeline tracks its own QA
  retries), but recorded for audit. The pipeline sets `needs_help` on 3 failures; the dispatcher
  reads that from Linear state.
- The file is rewritten after every slot change (claim, free, drain flag). A fresh dispatcher
  always trusts **Linear over the stale file**: Phase 1 reconciliation wins on every launch.

---

## 4. Claim-lock protocol

The dispatcher must not start the same issue twice — whether from a re-poll within the same
session or from two runners running in parallel tabs for the same project.

**The Linear `queued → in_progress` state transition IS the lock.** Here is why it works:

1. The dispatcher queries issues in the `queued` column.
2. It calls `issueUpdate` to flip the chosen issue to `in_progress`.
3. It immediately re-reads the issue's state from Linear.
4. If the state is not `in_progress` (because another session won the race), the dispatcher
   discards the issue and picks the next candidate.

Because Linear processes `issueUpdate` mutations serially, exactly one caller wins. The loser
sees a state that is not `queued` anymore (it is `in_progress` from the winner's flip) and moves
on. No external lock or distributed coordination is needed — the source-of-truth board state
provides the lock for free.

**Implication for parallel runners:** Running two runners for the same project is harmless but
wasteful. Each will race for the same queued issues; one will always win and the other will
silently skip. The concurrency cap (3) applies per-runner, not globally — two runners on the
same project could in theory start 6 issues. This is not a recommended configuration; document
it in the command's notes section.

---

## 5. Context compaction safety

The dispatcher runs a compaction guard at 70% context usage (`/compact` before the next tick).

**Why this is safe:**

All in-flight pipeline work runs as harness-tracked background agents. These agents have their
own execution contexts; they do not live in the dispatcher's conversation. Compacting (or
completely restarting) the dispatcher session does not interrupt or cancel any running agent.

The state file is the source of truth. After compaction or restart, Phase 1 auto-recovery
reconstructs the slot table:
- Issues in `in_progress` with a live branch or open PR: reconstruct as `in_flight`.
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
   a. Does an open PR exist whose branch name contains the lowercase issue identifier?
      (`gh pr list --state open --json number,headRefName`)
   b. Does a pushed remote branch exist matching the identifier?
      (`git ls-remote --heads origin "*<identifier-lower>*"`)
   - YES to either → live progress. Leave `in_progress`. Ensure slot entry exists.
   - NO to both → no real progress. Reset: `issueUpdate` back to `queued`. Remove from slots.
3. For each slot in `slots` with `status: "in_flight"`:
   - Fetch the issue's current Linear state.
   - If it is `ready` or `needs_help` (finished while the dispatcher was down): free the slot,
     add to history.
   - If it is still `in_progress`: keep the slot as-is.

### Tab-close recovery

Closing the runner tab is a hard stop. No cleanup runs at stop time. The next launch's Phase 1
handles it:

- Any `in_progress` issues that produced a branch/PR before the tab closed are kept in flight.
- Any `in_progress` issues with no branch/PR (claimed but not yet started, or the agent was
  just spawned and hadn't pushed yet) are reset to `queued`. They will be re-claimed on the
  next poll.

The worst case is that an issue gets re-claimed and re-started. The background pipeline agent
for the "lost" run (if it was spawned before the tab closed) will eventually reach `ready` or
`needs_help` on its own — the dispatcher will notice the state change on the first post-recovery
tick and free the slot. If both agents finish successfully, two PRs will exist for the same
issue; a human reviewing `/merge-issue` will see the duplicate and close one. This edge case is
rare and recoverable.

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
