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

If any required check is failing, warn the user and ask whether to proceed. Mutation Testing and E2E Tests may be skipped/`continue-on-error` — those do not block.

## Step 3: Merge the PR

```bash
gh pr merge {PR_NUMBER} --merge --delete-branch
```

If merge fails, report the error and STOP.

## Step 4: Update Linear Status to "Human: Review"

**MANDATORY — this is the entire reason this skill exists. NEVER skip.**

Read the LINEAR_API_KEY from the environment. If not set, read it from `.env.local`.

First, get the issue UUID. Use the SMA team UUID `55e6dc25-090c-4731-82c2-44549801a709` for SMA issues. For other team keys, look up the team UUID dynamically.

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Content-Type: application/json" \
  -H "Authorization: $LINEAR_API_KEY" \
  -d '{"query": "{ team(id: \"TEAM_UUID\") { issues(filter: { number: { eq: ISSUE_NUMBER } }) { nodes { id identifier title state { name } } } } }"}'
```

Then set status to "Human: Review" (state ID: `57e4fe98-bd23-425a-9493-bd651d621a90`):

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Content-Type: application/json" \
  -H "Authorization: $LINEAR_API_KEY" \
  -d '{"query": "mutation { issueUpdate(id: \"ISSUE_UUID\", input: { stateId: \"57e4fe98-bd23-425a-9493-bd651d621a90\" }) { success issue { identifier title state { name } } } }"}'
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
- If any step fails, report clearly what failed and what state things are in
- For non-SMA team keys, look up the team UUID dynamically via the teams query
