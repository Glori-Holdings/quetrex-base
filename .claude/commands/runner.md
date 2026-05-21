---
description: Continuous local-session queue runner. Polls a project's queued column and works up to 3 issues at once through the full pipeline to PR Ready, in spawned background worktree agents. Stops at PR Ready — merge/deploy/complete remain manual gates. One runner = one project = one tab. Resumable via state file.
argument-hint: <LINEAR-PROJECT-ID | stop | --resume>
---

# Runner

Continuously polls the project's `queued` column and dispatches up to **3 issues in parallel** through the full Glori Builder pipeline, each in its own background worktree agent. Stops at `ready` (AI: PR Ready). The manual gates `/merge-issue`, `/deploy`, and `/complete` are yours to run.

**How this differs from `/auto-pilot`:**

| | `/runner` | `/auto-pilot` |
|---|---|---|
| Concurrency | 3 in parallel, continuous | 1 at a time, sequential |
| Terminus | Stops at `ready` (manual merge) | Auto-merges, sets `complete` |
| Blocker rule | `merged` = unblocked | `complete` = unblocked |
| Runs pipelines | Background worktree agents | Inline in session |
| Never stops | Polls continuously | Stops when queue empty |

See `.claude/docs/runner.md` for the full design: dispatcher loop algorithm, state-file schema, claim-lock protocol, readiness rule, and auto-recovery details.

---

## Phase 0 — Preflight

### Step 0a: Environment checks

```bash
# Verify LINEAR_API_KEY is available
set -a; . ./.env; set +a
echo "${LINEAR_API_KEY:+set}"

# Verify gh is authenticated
gh auth status 2>&1 | head -1

# Verify git is clean
git status --porcelain
```

Stop if any check fails and tell the user what to fix.

### Step 0b: Subcommand dispatch

If `$ARGUMENTS` is `stop`:
- Go to **Phase 4 (Graceful Drain)**.

If `$ARGUMENTS` is `--resume`:
- Find the most recent `.claude/runner-*.json` state file.
- Load it, run **Phase 1 (Auto-Recover)**, then continue with **Phase 2**.

Otherwise treat `$ARGUMENTS` as a LINEAR-PROJECT-ID and proceed to Step 0c.

### Step 0c: Resolve the project and the Linear States map

**The runner requires the `## Linear States` map.** Resolve `queued`, `in_progress`, `ready`, `needs_help`, and `merged` from the project's map (see `.claude/docs/linear-states.md` for the resolution pattern). If the map is missing, stop immediately:

> No `## Linear States` map found in `.claude/CLAUDE.md`. Run `/map-states` first.
> The runner cannot safely distinguish `in_progress` from `ready` or `merged` without an explicit map
> (all three may share `type: "started"` in your workspace).

Never type-fallback for these keys.

Resolve the project name and team UUID:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ project(id: \"PROJECT_ID\") { id name team { id key } } }"}'
```

Fetch the team's state list once — cache it for the whole session:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ team(id: \"TEAM_UUID\") { states { nodes { id name type } } } }"}'
```

Resolve each canonical key to its `{ id, name }` by exact name match against the map. Store as:

```
QUEUED_STATE_ID       QUEUED_STATE_NAME
IN_PROGRESS_STATE_ID  IN_PROGRESS_STATE_NAME
READY_STATE_ID        READY_STATE_NAME
NEEDS_HELP_STATE_ID   NEEDS_HELP_STATE_NAME
MERGED_STATE_ID       MERGED_STATE_NAME
```

Also resolve any states at or after `merged` (typically `merged`, `deployed`, `complete`) — these satisfy the `merged = unblocked` readiness check.

### Step 0d: Single-runner-per-project guard

Before creating or loading any state, check for an existing runner state file for this project:

```bash
STATE_FILE=".claude/runner-${PROJECT_SHORT_ID}.json"
```

If the file exists, read its `heartbeat` field. If the heartbeat timestamp is less than `2 × pollIntervalSec` (default: 240 s) old, **refuse to start**:

```
A runner is already active for project {projectName}
(heartbeat {N} seconds ago). Stop it first with /runner stop,
or use /runner --resume to take over the state file.
```

If the heartbeat is older than 2 poll intervals (stale — the runner crashed or the tab was closed), proceed: load the state file and run Phase 1 auto-recovery.

This guard enforces the **one runner per project** invariant. Running two independent runners against the same project is unsupported and actively prevented here — the Linear state-flip alone does NOT provide a reliable lock for duplicate dispatchers (both would flip the issue to the same `in_progress` value and both succeed; the re-read cannot distinguish winner from loser). The heartbeat guard eliminates the race at the source.

### Step 0e: Initialize or load state file

If no state file exists, create `.claude/runner-{PROJECT_SHORT_ID}.json`:

```json
{
  "projectId": "PROJECT_UUID",
  "projectName": "PROJECT_NAME",
  "teamId": "TEAM_UUID",
  "startedAt": "ISO_TIMESTAMP",
  "heartbeat": "ISO_TIMESTAMP",
  "pollIntervalSec": 120,
  "concurrency": 3,
  "draining": false,
  "slots": {},
  "history": []
}
```

If a state file exists but has a stale heartbeat (from Step 0d), load it and proceed to Phase 1 — do not overwrite it.

Report to the user:

```
Runner starting for {projectName}
State file: .claude/runner-{PROJECT_SHORT_ID}.json
Poll interval: 120 s   Concurrency cap: 3
Resolving queued → {QUEUED_STATE_NAME}
Stops at ready → {READY_STATE_NAME}
Run `/runner stop` to drain gracefully.
```

---

## Phase 1 — Auto-Recover

Run on every launch (fresh or `--resume`) before claiming anything. Reconciles any `in_progress` issues left over from a prior run or a hard tab-close.

### Step 1a: Query all in_progress issues

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ issues(filter: { project: { id: { eq: \"PROJECT_ID\" } }, state: { name: { eq: \"IN_PROGRESS_STATE_NAME\" } } }) { nodes { id identifier title } } }"}'
```

### Step 1b: For each in_progress issue, check for live progress

An issue has **live progress** if either of these is true:

```bash
# Check for open PR whose branch matches the issue identifier (lowercase) followed by a dash.
# Anchor the identifier with a trailing dash to prevent glo-5 from matching glo-51 or glo-57.
IDENTIFIER_LOWER="glo-57"   # example — use the actual lowercase identifier
gh pr list --state open --json number,headRefName | \
  python3 -c "import json,sys; prs=json.load(sys.stdin); print(any('${IDENTIFIER_LOWER}-' in p['headRefName'].lower() for p in prs))"

# Check for pushed remote branch — anchor with trailing dash
git ls-remote --heads origin "*${IDENTIFIER_LOWER}-*"
```

Replace `IDENTIFIER_LOWER` with the lowercase issue identifier (e.g. `glo-57`). The trailing `-` anchor prevents `glo-5` from matching `glo-51` or `glo-57`.

- **Live progress found (open PR or pushed branch)** → The agent that was driving this issue died with the previous session. A recovered slot must not sit idle — **re-dispatch**: spawn a fresh background worktree agent (isolation: "worktree") that resumes from the existing branch and drives the issue to `ready`. Record the slot with the new `agentRef` and `status: "in_flight"`. See `.claude/docs/runner.md` §6 for the re-dispatch rationale.
- **No live progress** → Reset the issue: move it back to the `queued` column:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation { issueUpdate(id: \"ISSUE_UUID\", input: { stateId: \"QUEUED_STATE_ID\" }) { success } }"}'
```

Then remove it from the state file's `slots`. It is now reclaimable on the next poll.

### Step 1c: Reconcile slot table

For each entry in `slots` with `status: "in_flight"`, verify the issue is still `in_progress` in Linear. If it has moved to `ready` or `needs_help` (finished while the dispatcher was down), free the slot by moving the entry to `history`:

```json
{ "identifier": "GLO-57", "outcome": "ready", "pr": 81, "at": "ISO_TIMESTAMP" }
```

Report the reconciliation results:

```
Auto-recover: checked {N} in_progress issues
  Re-dispatched (live branch/PR, fresh agent spawned): {list of identifiers}
  Reset to queued (no branch/PR found): {list of identifiers}
  Slot freed (finished while down): {list}
```

---

## Phase 2 — Dispatcher Loop

The dispatcher is **intentionally lean**. It never runs a pipeline inline — heavy pipeline context lives in spawned background agents. The long-lived session would blow its context if it ran pipelines directly.

Repeat every `pollIntervalSec` seconds using the harness `/loop` + `ScheduleWakeup`. Default: **120 s**.

### Tick step 1: Free completed slots

For each slot in `slots` with `status: "in_flight"`:

Check the issue's current Linear state:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ issue(id: \"ISSUE_UUID\") { id identifier state { name } } }"}'
```

- State name == `READY_STATE_NAME` → slot is done. Move entry to `history` with `outcome: "ready"`. Add a Linear comment:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation { commentCreate(input: { issueId: \"ISSUE_UUID\", body: \"Reached PR Ready — awaiting manual /merge-issue.\" }) { success } }"}'
```

- State name == `NEEDS_HELP_STATE_NAME` → slot failed. Move entry to `history` with `outcome: "needs_help"`. The background pipeline already moved the issue and added a comment; the dispatcher just frees the slot.
- State name is still `IN_PROGRESS_STATE_NAME` → leave slot occupied.
- Any other state (human moved it while in flight) → free the slot, note in history with `outcome: "human_moved"`.

### Tick step 2: Refill up to the concurrency cap

If `draining: true`, skip this step entirely.

Count slots with `status: "in_flight"`. While that count is less than `concurrency` (3):

**Poll the queued column:**

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ issues(filter: { project: { id: { eq: \"PROJECT_ID\" } }, state: { name: { eq: \"QUEUED_STATE_NAME\" } } }, orderBy: sortOrder) { nodes { id identifier title sortOrder relations { nodes { type relatedIssue { id identifier state { name } } } } } } }"}'
```

**Apply the readiness rule (merged = unblocked):**

For each candidate issue, examine its `relations` list. A relation with `type: "blocks"` on issue X means X is blocked by `relatedIssue`. Concretely: if the query returns `{ type: "blocks", relatedIssue: { identifier: "GLO-50", state: { name: "..." } } }` on issue X, then GLO-50 is a blocker of X. Check each such `relatedIssue`'s state name against the `MERGED_STATE_NAME` and any column that comes after it (deployed, complete — resolved from the map by name, never hardcoded). If every blocker is in `merged` or a later column, the issue is ready to run. If the issue has no `blocks`-type relations, it has no blockers and is ready.

Also skip any issue whose UUID is already present as a key in the state file's `slots` table (intra-runner dedup — prevents re-claiming an issue the dispatcher already owns).

Pick the first ready issue in `sortOrder`. If none are ready, break (all candidates are blocked or already claimed — try again next tick).

**Claim it:**

Flip the issue `queued → in_progress` and immediately record the slot. The lock is the enforced single-runner-per-project invariant (heartbeat guard, Phase 0d) plus the slot-table dedup above — NOT the idempotent Linear state flip (two callers setting the same value both succeed; a re-read cannot distinguish them). With only one active runner per project, the only real race is a mid-tick restart, which Phase 1 already handles.

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation { issueUpdate(id: \"ISSUE_UUID\", input: { stateId: \"IN_PROGRESS_STATE_ID\" }) { success issue { id state { name } } } }"}'
```

**Record the slot before spawning:**

Write the slot to the state file immediately after the `issueUpdate` succeeds — before the agent is spawned. The slot entry is the intra-runner dedup fence; it must exist before the next refill iteration can run:

```json
"ISSUE_UUID": {
  "identifier": "GLO-57",
  "branch": "feature/glo-57-...",
  "agentRef": "pending",
  "status": "in_flight",
  "retries": 0,
  "claimedAt": "ISO_TIMESTAMP",
  "lastCheckedAt": "ISO_TIMESTAMP"
}
```

**Spawn a background worktree agent:**

Each claimed issue gets one background agent with `isolation: "worktree"`. Pass the issue ID, identifier, title, team UUID, and the resolved state IDs for `in_progress`, `ready`, and `needs_help`. The agent runs the full pipeline to `ready` and stops (see "Spawned Pipeline Agent" below).

Update `agentRef` in the slot entry with the harness task reference returned by the spawn call. Rewrite the state file. Continue the refill loop.

**Write the heartbeat.** At the end of every tick — after all slot changes and state-file writes — update the `heartbeat` field in the state file to the current UTC timestamp. This is what the single-runner guard (Phase 0d) reads on the next launch to know whether this runner is still active.

### Tick step 3: Idle handling

If no slots are occupied and no ready queued issues were found, the runner is idle. Log an idle heartbeat **at most once every 10 ticks** to avoid spamming the tab:

```
[runner idle] {N} issues queued, all blocked or none queued. Next poll in 120 s.
```

The runner stays alive. It is continuous — it does not exit when the queue empties.

### Tick step 4: Context guard

Check dispatcher context usage. If at or above **70%**, run `/compact` before the next tick.

This is safe: in-flight pipelines run as **harness-tracked background agents**, not as conversation state. The state file is the source of truth. A compacted (or fully restarted) dispatcher reconstructs every slot from Linear + the state file via Phase 1. See `.claude/docs/runner.md` for rationale.

---

## Spawned Pipeline Agent

Each claimed issue spawns ONE background agent. Configuration:

```
isolation: "worktree"
```

The agent receives: issue ID, identifier, title, description, team UUID, resolved state IDs (`in_progress`, `ready`, `needs_help`), and the feature branch name to create.

The agent runs, in order:

1. Create the feature branch `feature/<identifier-slug>` from fresh `main` inside the worktree.
2. **Architect** — implementation plan, file ownership map, `designer_required` flag.
3. **Designer** (only if architect flagged `designer_required: true`) — design spec.
4. **Developer(s)** — parallel implementation in separate sub-worktrees per architect's ownership map.
5. **Merge sub-branches** into the feature branch.
6. **QA** — verify with actual exit codes (up to 3 retries; fix and rerun on failure).
7. **Reviewer** — semantic review of full diff; fix and re-QA on rejection (counts against retry limit).
8. **git-workflow** — commit, push, open squash PR to main. git-workflow sets the issue to `ready`. That is the terminus.

**The agent STOPS AT `ready`. It never merges, deploys, or completes.**

**3-strike / hard blocker / unanswerable ambiguity:** move the issue to the `needs_help` column (exact name from the map), add a Linear comment with the failure detail, and exit. The dispatcher learns the outcome from the issue's Linear state on the next tick and frees the slot.

The dispatcher does not parse agent output inline. It polls Linear state on each tick.

---

## Phase 4 — Graceful Drain (`/runner stop`)

### Step 4a: Set draining flag

Write `"draining": true` to the state file.

Report:

```
Runner draining. No new issues will be claimed.
Current in-flight: {list of identifiers}
Will exit when all in-flight slots reach ready or needs_help.
```

### Step 4b: Keep ticking

Continue the dispatcher loop (Phase 2, tick step 1 only — skip tick step 2). On each tick, check whether all in-flight slots are done.

### Step 4c: Exit condition

When `in-flight count == 0`, proceed to Phase 5 (Summary) and exit the loop.

---

## Phase 5 — Summary (on drain or explicit exit)

```
Runner finished.

Reached PR Ready: {N}
  {identifier}: {title} — PR #{number}
  ...

Moved to needs_help: {N}
  {identifier}: {title} — {failure summary}
  ...

Still queued (not started): {N} issues remain in the queue.

State log: .claude/runner-{PROJECT_SHORT_ID}.json

Next steps (human gates):
  /merge-issue {identifier}   — merge a PR
  /deploy                     — mark as deployed
  /complete {identifier}      — sign off after testing
```

---

## Resuming an Interrupted Run

If the runner's tab is closed or the session ends unexpectedly:

```
/runner --resume
```

This loads the most recent `.claude/runner-*.json` state file, runs Phase 1 auto-recovery (reconciles any orphaned `in_progress` issues — live branch/PR means re-dispatch a fresh agent; no branch/PR means reset to `queued`), and continues Phase 2.

---

## Notes

- `LINEAR_API_KEY` is loaded from the project `.env` via `set -a; . ./.env; set +a` — it is not expected to be a shell environment variable before the command runs.
- Resolve all states through the project `## Linear States` map. See `.claude/docs/linear-states.md`. Never hardcode column names.
- The runner requires a complete map — run `/map-states` if it is missing. Type-fallback is not available for `in_progress`, `ready`, or `merged` (all commonly `type: "started"`).
- The concurrency cap is 3 in-flight issues. This is not configurable from the command line in v1; edit the state file's `concurrency` field to change it.
- One runner per project is enforced by the heartbeat guard (Phase 0d). Running two independent runners against the same project is unsupported — the Linear state-flip does NOT prevent double-claiming (both callers set the same `in_progress` value; both succeed; the re-read returns `in_progress` for both). The heartbeat guard is the actual lock.
- See `.claude/docs/runner.md` for the full design rationale, state-file schema details, and edge-case handling.
