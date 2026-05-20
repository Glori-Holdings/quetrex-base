---
name: merge-issue
description: Merge a PR and update Linear issue status to Human Review
argument-hint: <ISSUE-ID e.g. SMA-57>
disable-model-invocation: true
---

# Merge Issue PR and Update Linear Status

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

## Step 4: Update Linear Status to "Human: Review"

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

**Step 4c** — Find the "Human: Review" state by name. Query the team's workflow states and find the one whose name contains "review" or "human review" (case-insensitive):

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Content-Type: application/json" \
  -H "Authorization: $LINEAR_API_KEY" \
  -d '{"query": "{ team(id: \"TEAM_UUID\") { states { nodes { id name } } } }"}'
```

From the results, select the state whose name matches (case-insensitive) "human: review", "human review", or contains both "human" and "review". If multiple states match and you cannot determine which is correct, list them to the user and ask which to use before proceeding.

**Step 4d** — Set the issue status:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Content-Type: application/json" \
  -H "Authorization: $LINEAR_API_KEY" \
  -d '{"query": "mutation { issueUpdate(id: \"ISSUE_UUID\", input: { stateId: \"REVIEW_STATE_ID\" }) { success issue { identifier title state { name } } } }"}'
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

> **$ARGUMENTS merged and moved to Human: Review.**
> - PR #{PR_NUMBER} merged
> - Linear status: Human: Review
> - Branch {BRANCH_NAME} deleted

Then STOP.

## Rules

- NEVER set an issue to "Complete" — only the human does that
- NEVER skip the Linear status update
- NEVER hardcode team UUIDs or state IDs — always look them up dynamically
- If any step fails, report clearly what failed and what state things are in
