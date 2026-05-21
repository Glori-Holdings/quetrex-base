---
name: merge-issue
description: Merge a PR and move the Linear issue to the Merged state. The first manual gate after the pipeline stops at PR Ready.
argument-hint: <ISSUE-ID e.g. SMA-57>
disable-model-invocation: true
---

# Merge Issue PR and Move to Merged

The automatic pipeline stops at `ready` (AI: PR Ready). This is the first **human gate** after
that: it merges the PR and moves the issue to the `merged` column. The remaining gates are
`/deploy` (→ deployed) and `/complete` (→ complete). Resolve all states through the project's
`## Linear States` map — see `.claude/docs/linear-states.md`.

## Input Validation

Issue identifier: `$ARGUMENTS`

If `$ARGUMENTS` is empty or missing, say: "Usage: `/merge-issue SMA-{N}` — please provide an issue ID." and STOP.

Parse the team key and issue number (e.g., "SMA-57" → team key "SMA", number 57). If parsing fails, say: "Could not parse issue ID from `$ARGUMENTS`. Expected format: SMA-57" and STOP.

## Step 1: Find the PR

Search for an open PR whose branch contains the issue identifier:

```bash
gh pr list --state open --json number,title,headRefName
```

Match on the branch name (e.g., `sma-57`). If no open PR is found:
1. Check if a merged/closed PR exists: `gh pr list --state merged --json number,title,headRefName` and search for the issue.
2. If found merged, say: "**$ARGUMENTS already merged** (PR #{number}). No action needed." and STOP.
3. If found closed (not merged), say: "PR #{number} for $ARGUMENTS was closed without merging. Check Linear for status." and STOP.
4. If no PR exists at all, say: "No PR found for $ARGUMENTS. Has one been created yet?" and STOP.

Display:
- **PR #**: {number}
- **Title**: {title}
- **Branch**: {headRefName}

## Step 2: Verify CI Status

```bash
gh pr checks {PR_NUMBER}
```

If any required check is failing, warn the user and ask whether to proceed.

## Step 3: Merge the PR

```bash
gh pr merge {PR_NUMBER} --merge --delete-branch
```

If merge fails, report the error and STOP.

## Step 4: Update Linear Status to "Merged"

**MANDATORY — this is the entire reason this skill exists. NEVER skip.**

Read the `LINEAR_API_KEY` from the environment.

**Step 4a** — Look up the team UUID dynamically using the team key parsed from `$ARGUMENTS`:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Content-Type: application/json" \
  -H "Authorization: $LINEAR_API_KEY" \
  -d '{"query": "{ teams(filter: { key: { eq: \"TEAM_KEY\" } }) { nodes { id key name } } }"}'
```

Replace `TEAM_KEY` with the parsed team key (e.g., "SMA"). Extract the `id` field — this is the team UUID.

**Step 4b** — Get the issue UUID:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Content-Type: application/json" \
  -H "Authorization: $LINEAR_API_KEY" \
  -d '{"query": "{ team(id: \"TEAM_UUID\") { issues(filter: { number: { eq: ISSUE_NUMBER } }) { nodes { id identifier title state { name } } } } }"}'
```

**Step 4c** — Resolve the `merged` column from the project's `## Linear States` map. Query the team's workflow states and find the one whose `name` exactly equals that column:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Content-Type: application/json" \
  -H "Authorization: $LINEAR_API_KEY" \
  -d '{"query": "{ team(id: \"TEAM_UUID\") { states { nodes { id name type } } } }"}'
```

Select the state whose `name` exactly equals the `merged` column (e.g. "Merged"). If the project has no `## Linear States` map, stop and tell the user to run `/map-states` — there is no reliable type-based fallback for `merged` (it usually shares `type: "started"` with several other columns).

**Step 4d** — Set the issue status:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Content-Type: application/json" \
  -H "Authorization: $LINEAR_API_KEY" \
  -d '{"query": "mutation { issueUpdate(id: \"ISSUE_UUID\", input: { stateId: \"MERGED_STATE_ID\" }) { success issue { identifier title state { name } } } }"}'
```

**Verify** the mutation returned `success: true`. If it failed, report the error.

## Step 5: Clean Up

Delete the local branch if it exists and return to main:

```bash
git branch -D {BRANCH_NAME} 2>/dev/null
git checkout main && git pull origin main
```

## Step 6: Confirm

Report EXACTLY:

> **$ARGUMENTS merged.**
> - PR #{PR_NUMBER} merged
> - Linear status: Merged
> - Branch {BRANCH_NAME} deleted
>
> Next gates: `/deploy` to ship it, then `/complete $ARGUMENTS` after testing.

Then STOP.

## Rules

- NEVER set an issue to `complete` — that's the `/complete` gate after deploy and testing
- NEVER skip the Linear status update
- NEVER hardcode team UUIDs, state IDs, or column names — resolve `merged` from the project map and look up IDs dynamically
- If any step fails, report clearly what failed and what state things are in
