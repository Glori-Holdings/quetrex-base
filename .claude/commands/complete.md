---
description: Mark deployed issues Complete after human testing. /complete SMA-57 completes one issue; /complete (blank) moves all deployed issues in a project to Complete.
argument-hint: <ISSUE-ID e.g. SMA-57 (optional — blank completes all deployed in a project)>
---

# Complete

The final manual gate. After an issue has been deployed and a human has tested it, `/complete`
moves it to the `complete` state. Resolve all states through the project map — see
`.claude/docs/linear-states.md`.

Two modes:
- **`/complete SMA-57`** — complete that single issue.
- **`/complete`** (no argument) — complete **every** issue currently in the `deployed` state for a
  project (per-project batch), with an explicit confirmation first.

## Step 0: Prerequisites

```bash
echo "${LINEAR_API_KEY:+set}"
```

If empty, stop: "Set LINEAR_API_KEY (run /quetrex-setup or /secrets add LINEAR_API_KEY)."

## Step 1: Resolve the state names from the map

Read the `## Linear States` section in the project `.claude/CLAUDE.md`. You need the column names
for `deployed` and `complete`.

If there is no `## Linear States` section, stop and tell the user:
"No Linear state map found. Run `/map-states` first so I know which columns mean
'deployed' and 'complete'."

---

## Mode A: Single issue — `/complete SMA-57`

### A1. Parse and look up

Parse the team key and number (e.g. "SMA-57" → key "SMA", number 57).

Get the team UUID:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ teams(filter: { key: { eq: \"TEAM_KEY\" } }) { nodes { id key name } } }"}'
```

Get the issue (UUID + current state):

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ team(id: \"TEAM_UUID\") { issues(filter: { number: { eq: ISSUE_NUMBER } }) { nodes { id identifier title state { name } } } } }"}'
```

### A2. Sanity check

- If the issue is already in the `complete` column: say "$ARGUMENTS is already Complete." and STOP.
- If the issue is **not** in the `deployed` column: warn —
  "$ARGUMENTS is currently '{state.name}', not Deployed. Complete is meant for deployed,
  human-tested issues. Complete it anyway?" — and wait for confirmation before proceeding.

### A3. Resolve the `complete` state ID and set it

Find the team state whose `name` exactly matches the `complete` column from the map (Step 1):

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ team(id: \"TEAM_UUID\") { states { nodes { id name type } } } }"}'
```

Update the issue:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation { issueUpdate(id: \"ISSUE_UUID\", input: { stateId: \"COMPLETE_STATE_ID\" }) { success issue { identifier state { name } } } }"}'
```

Verify `success: true`. Report:

> **$ARGUMENTS → Complete.**

Then STOP.

---

## Mode B: Batch — `/complete` with no argument

### B1. Determine the project

Ask: "Which Linear project should I complete deployed issues for? (project name or ID)".

If a recent `.claude/autopilot-*.json` exists, you may offer its `projectId` as the default, but
still confirm before acting.

Resolve the project ID if given a name:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ projects(filter: { name: { contains: \"PROJECT_NAME\" } }) { nodes { id name } } }"}'
```

### B2. Find all deployed issues in that project

Resolve the `deployed` column name from the map (Step 1). Query the project's issues in that
state — match on the exact state name:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ issues(filter: { project: { id: { eq: \"PROJECT_ID\" } }, state: { name: { eq: \"DEPLOYED_COLUMN_NAME\" } } }) { nodes { id identifier title } } }"}'
```

If none are found: say "No deployed issues in {project} to complete." and STOP.

### B3. Confirm — MANDATORY

List every issue that will be moved, then ask the exact question:

```
These {N} deployed issues in {project} will move to Complete:
  SMA-57: {title}
  SMA-58: {title}
  ...

Are you sure you want to move all to Complete?
```

Wait for an explicit yes. If the user says no, STOP and change nothing. This is per-project only —
never touch issues outside the chosen project.

### B4. Move them all

Resolve the `complete` state ID (exact name match from the map). For each issue, run:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation { issueUpdate(id: \"ISSUE_UUID\", input: { stateId: \"COMPLETE_STATE_ID\" }) { success } }"}'
```

Report a summary:

> **Completed {N} issues in {project}:** SMA-57, SMA-58, …

Then STOP.

## Rules

- Always resolve `deployed` and `complete` from the project map — never hardcode names.
- Mode B is **per-project** and requires explicit "are you sure?" confirmation before any change.
- `/complete` is a human gate. The pipeline never calls it automatically (except `/auto-pilot`,
  which sets `complete` directly as its deliberate exception).
