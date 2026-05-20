---
description: Work through all Linear issues in a project autonomously. Runs the full pipeline (architect → developers → QA → reviewer → merge) for each issue in dependency order, auto-merges PRs, and continues until the backlog is empty. Run after /plan-project to walk away and let Glori Builder finish the project.
argument-hint: <LINEAR-PROJECT-ID>
---

# Auto-Pilot

Works through every queued issue in a Linear project — one at a time, in dependency order — until the backlog is empty. Each issue runs the full Glori Builder pipeline and is auto-merged to main when QA and review pass.

## Before Starting

```bash
# Verify LINEAR_API_KEY is set
echo "${LINEAR_API_KEY:+set}"

# Verify gh is authenticated
gh auth status 2>&1 | head -1

# Verify git is clean and on main
git branch --show-current
git status --porcelain
```

Stop if any check fails and tell the user what to fix.

## Phase 1: Load the Backlog

### Step 1a: Get project issues from Linear

If `$ARGUMENTS` is provided, use it as the project ID. Otherwise, ask: "Which Linear project should I work? (provide the project ID)"

Fetch all unstarted/backlog issues for this project, sorted by `sortOrder`:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ issues(filter: { project: { id: { eq: \"PROJECT_ID\" } }, state: { type: { in: [\"unstarted\", \"backlog\"] } } }, orderBy: sortOrder) { nodes { id identifier title sortOrder state { name type } relations { nodes { type relatedIssue { id identifier state { type } } } } } } }"}'
```

### Step 1b: Build execution order

From the results, build the dependency graph:
- An issue is **ready** if all issues it is blocked by are in state `completed`
- Sort ready issues by `sortOrder` (ascending)
- Group into execution batches (same batch = no inter-dependency)

Display the plan:

```
Auto-pilot plan: {N} issues

Batch 1 (start immediately):
  {identifier}: {title}
  {identifier}: {title}

Batch 2 (after Batch 1):
  {identifier}: {title}

...

Issues will be worked sequentially within each batch.
PRs will be auto-merged after QA and review pass.
Failed issues (3 QA retries exhausted) will be skipped and logged.

Proceed?
```

Wait for confirmation.

### Step 1c: Initialize state file

Create `.claude/autopilot-{YYYYMMDD-HHMM}.json`:

```json
{
  "projectId": "PROJECT_ID",
  "startedAt": "ISO_TIMESTAMP",
  "issues": {}
}
```

This file tracks progress and allows resuming if the session ends.

---

## Phase 2: Work Each Issue

For each issue in execution order (batch by batch, sequential within batch):

### Step 2a: Check if already done (resumable)

```bash
cat .claude/autopilot-*.json 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d['issues'].get('ISSUE_ID', {}).get('status', 'pending'))
"
```

If status is `complete` or `skipped`, skip to next issue.

### Step 2b: Mark as in progress

Update state file: `"ISSUE_ID": { "status": "in_progress", "retries": 0 }`

Update Linear status to In Progress:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation { issueUpdate(id: \"ISSUE_UUID\", input: { stateId: \"IN_PROGRESS_STATE_ID\" }) { success } }"}'
```

### Step 2c: Create the feature branch

```bash
git checkout main && git pull origin main
BRANCH="feature/$(echo '{identifier}-{title}' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | cut -c1-60)"
git checkout -b "$BRANCH"
```

### Step 2d: Run the pipeline

Invoke each agent in sequence, passing the issue details:

1. **Architect agent** — create implementation plan for this issue
2. **Designer agent** (if architect flagged `designer_required: true`) — create design spec
3. **Developer agent(s)** — spawn parallel workers per architect's file ownership map
4. **Merge sub-branches** — merge each developer's sub-branch into the feature branch
5. **QA agent** — run verification chain, report exit codes

**If QA fails:**
- Increment retry counter
- If retries < 3: send exact failure output to developer agent(s), re-run developers and QA
- If retries == 3: mark issue as `skipped`, add Linear comment explaining failures, continue to next issue

6. **Reviewer agent** — semantic review of full diff
   - If reviewer rejects: send feedback to developer, rerun developers → QA → reviewer (counts against retry limit)
   - If reviewer approves: continue

### Step 2e: Create and merge the PR

**git-workflow agent** — commit, push, create PR.

Wait for CI to pass:

```bash
gh pr checks {PR_NUMBER} --watch --timeout 600
```

If CI passes, auto-merge:

```bash
gh pr merge {PR_NUMBER} --squash
```

Pull new main:

```bash
git checkout main && git pull origin main
```

If CI fails after 2 minutes: treat as QA failure, increment retry counter.

### Step 2f: Update status

On **success**:
- Update Linear issue to Done
- Update state file: `"status": "complete", "pr": PR_NUMBER`
- Add Linear comment: "Completed by Glori Builder auto-pilot."

On **skip** (3 failures):
- Update Linear issue to status `in_review` (human needs to look)
- Update state file: `"status": "skipped", "reason": "3 QA/review cycles exhausted"`
- Add Linear comment with the failure details

### Step 2g: Context check

After each issue, check context usage. If above 70%, run `/compact` before starting the next issue. Auto-pilot is fully resumable from the state file — a fresh session can continue with `/auto-pilot --resume`.

---

## Phase 3: Summary

When all issues are processed (or none remain in a ready state):

```
Auto-pilot complete.

✓ Completed: {N} issues
  {identifier}: {title}
  ...

⚠ Skipped (needs human review): {N} issues
  {identifier}: {title} — {failure summary}

✗ Blocked (dependencies not met): {N} issues
  {identifier}: {title} — waiting on {blocking-identifier}

State log: .claude/autopilot-{timestamp}.json
```

For skipped issues: update Linear to `In Review` so they surface for manual attention.

---

## Resuming an Interrupted Run

If auto-pilot stops mid-run (context overflow, session end, error):

```
/auto-pilot --resume
```

This reads the most recent `.claude/autopilot-*.json` state file, skips completed issues, and continues from where it left off.

---

## Notes

- Issues are worked sequentially — parallel batches in v1 are sequential for reliability
- Each issue gets a clean branch from the latest main after the previous merge
- Auto-merge waits for CI to pass — branch protection is enforced
- State file survives session restarts — auto-pilot is always resumable
- Skipped issues are not deleted from Linear — they stay visible for human review
- Run `/auto-pilot PROJECT-ID` at any time to work remaining backlog issues
