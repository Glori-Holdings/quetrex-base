---
description: Read a Linear issue and create a comprehensive PRD through dialog
argument-hint: <ISSUE-ID e.g. SMA-40>
---

# Create PRD from Linear Issue

## Issue to Read

Fetch the Linear issue: `$ARGUMENTS`

### Rename Session

Before doing anything else, rename this Claude Code session so it is easy to identify. Use `/rename` with the issue ID and today's short date (M-D format, no leading zeros):

```
/rename $ARGUMENTS-{M}-{D}
```

For example, if the issue is SMA-55 and today is March 4: `/rename SMA-55-3-4`

### Step 0: Branch Setup (MANDATORY — DO THIS FIRST)

**CRITICAL: You MUST create a feature branch before doing ANY other work. The project enforces feature branches — committing or pushing on `main` will be BLOCKED by hooks, wasting API calls. Do NOT skip this step.**

1. If not already on `main`, switch to it:

```bash
git checkout main
```

2. Pull the latest changes:

```bash
git pull origin main
```

3. Create a feature branch for the PRD:

```bash
git checkout -b docs/prd-$ARGUMENTS
```

4. Verify you are on the new branch (NOT `main`):

```bash
git branch --show-current
```

The output MUST show `docs/prd-$ARGUMENTS`. Do NOT proceed until confirmed.

If `git checkout main` fails because of uncommitted changes on another branch, run `git stash` first, then `git checkout main`. Do NOT force-checkout or discard work.

### Step 1: Fetch the Issue

Linear's top-level `issues` query and `issueVcSearch` are unreliable with personal API keys. Always use team-scoped queries.

Parse the team key and issue number from `$ARGUMENTS` (e.g., "SMA-51" → team key "SMA", number 51).

**Step 1a** — Get the team ID:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ teams(filter: { key: { eq: \"TEAM_KEY\" } }) { nodes { id key name } } }"}'
```

Replace `TEAM_KEY` with the parsed team key (e.g., "SMA").

**Step 1b** — Fetch the issue using the team ID:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ team(id: \"TEAM_UUID\") { issues(filter: { number: { eq: ISSUE_NUMBER } }) { nodes { id identifier title description priority estimate state { name } labels { nodes { name } } project { name } team { name key } } } }"}'
```

Replace `TEAM_UUID` with the id from Step 1a and `ISSUE_NUMBER` with the parsed number (e.g., 51).

Display the fetched issue data clearly:
- **ID**: {identifier}
- **Title**: {title}
- **State**: {state.name}
- **Priority**: {priority}
- **Estimate**: {estimate}
- **Labels**: {labels}
- **Project**: {project.name}
- **Team**: {team.name}
- **Description**:
  {description}

If $LINEAR_API_KEY is not set, stop and tell the user: "Set the LINEAR_API_KEY environment variable to your Linear API token and try again."

### Step 2: Load Codebase Context

Run the project's prime command or read CLAUDE.md to understand the codebase before creating the PRD. This ensures the PRD references real patterns, files, and architecture.

Read the following files to understand the current project state:
- `CLAUDE.md` (project root) if it exists
- `package.json` for tech stack
- `.claude/commands/` to understand available tooling

Also run:
!`git log -5 --oneline`
!`git branch --show-current`

### Step 3: Refine Through Dialog

Ask the user targeted questions to fill gaps in the issue description. Work through each topic area. Do not rush — the PRD quality determines implementation quality.

Present each question clearly and wait for a response before asking the next:

**Question 1 — User Experience:**
Walk through the feature step by step. What should the user see when they arrive? What actions do they take? What happens after each action? What does success look like from the user's perspective?

**Question 2 — Architecture:**
Which existing patterns should this follow? What files and components are directly involved? Are there any similar features already implemented we should mirror? What API routes or server actions are needed?

**Question 3 — Edge Cases:**
What could go wrong? What inputs need validation? What happens when the user is not authenticated? What happens on network errors? Are there race conditions or concurrent-edit scenarios to handle?

**Question 4 — Testing Requirements:**
What unit tests are needed for the business logic? What E2E user journeys must be tested end-to-end? What edge cases must have explicit test coverage? Is there a mutation testing score target?

**Question 5 — Acceptance Criteria:**
How do we know this is done? List each measurable criterion. What CI checks must pass?

Continue the dialog until the user indicates they are satisfied. Ask follow-up questions if answers are incomplete. Do not proceed to Step 4 until you have enough information to write a PRD that an autonomous agent can implement without asking questions.

### Step 4: Generate PRD

Create the PRD at `.claude/prds/$ARGUMENTS.md` using the structure below. The PRD must be comprehensive enough that an autonomous agent can implement it without asking questions.

The PRD must include:
- Real file paths from the codebase (discovered in Step 2)
- Specific patterns to follow with file:line references where possible
- Concrete test cases with expected inputs and outputs
- Every edge case discussed in Step 3

```markdown
# {Issue ID}: {Title}

## Overview

{What this feature or fix does and why it matters. 2-3 sentences.}

## User Story

As a {user type}, I want to {action}, so that {benefit}.

## Detailed Requirements

{Comprehensive specification of what to build. Cover:
- The full user-facing flow, step by step
- All UI states (loading, error, empty, success)
- All validation rules and error messages
- Server-side behavior
- Any background jobs or async processes
- Edge cases and how they are handled}

## Architecture

- **Files to modify**: {list each file with its absolute path and what changes}
- **Files to create**: {list each new file with its absolute path and purpose}
- **Patterns to follow**: {reference existing code patterns with file:line}
- **Dependencies**: {any new packages or services needed, or "None"}

## Database Changes

{Schema changes, new tables, new columns, migrations needed — or "None"}

## API Changes

{New routes, modified routes, request/response shapes — or "None"}

## Testing Requirements

### Unit Tests

- [ ] {specific test: function X in file Y returns Z when given input W}
- [ ] {specific test: error handling when condition C occurs}
- [ ] {specific test: validation rejects input I with message M}

### E2E Tests

- [ ] {user journey: navigate to X → do Y → verify Z is visible}
- [ ] {user journey: submit form with invalid data → verify error message appears}
- [ ] {user journey: complete happy path from start to finish}

### Mutation Testing

- Stryker must achieve >60% mutation score on new code

## Acceptance Criteria

- [ ] {measurable criterion — be specific}
- [ ] {measurable criterion — be specific}
- [ ] All CI checks pass: type-check, lint, test, build, Stryker, Playwright
- [ ] Code follows existing project patterns
- [ ] No TypeScript errors, no lint warnings
```

### Step 5: Commit, Push, and Link

After writing the PRD file:

1. Stage and commit the PRD:

```bash
git add .claude/prds/$ARGUMENTS.md
git commit -m "docs: add PRD for $ARGUMENTS"
```

2. Push the branch to origin (with upstream tracking):

```bash
git push -u origin docs/prd-$ARGUMENTS
```

**IMPORTANT**: Do NOT use bare `git push` — you must specify the upstream since this is a new branch.

3. Get the issue UUID from the Step 1 API response (the `id` field, not `identifier`), then add a comment to the Linear issue linking to the PRD:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation { commentCreate(input: { issueId: \"ISSUE_UUID\", body: \"PRD ready: .claude/prds/$ARGUMENTS.md\" }) { success } }"}'
```

Replace `ISSUE_UUID` with the actual UUID from the Step 1 response.

4. **Set the issue status to "Queued"** so the runner knows it's ready. First, get the state ID for "Queued" from the team's workflow states:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ team(id: \"TEAM_UUID\") { states(filter: { name: { eq: \"Queued\" } }) { nodes { id name } } } }"}'
```

Then update the issue status:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation { issueUpdate(id: \"ISSUE_UUID\", input: { stateId: \"QUEUED_STATE_ID\" }) { success issue { id state { name } } } }"}'
```

Replace `TEAM_UUID` with the team UUID from Step 1a, `ISSUE_UUID` with the issue UUID, and `QUEUED_STATE_ID` with the state ID from the query above. Confirm to the user that the status was set to "Queued".

5. **AFTER status is confirmed "Queued", THEN add the "ai" label.** The label triggers the runner to pick up the issue — it MUST be added last to avoid a race condition where the runner transitions to "In Progress" and then the status-set overwrites it back to "Queued". Do NOT run this in parallel with step 4.

First, find the label ID for "ai" in the workspace:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ issueLabels(filter: { name: { eq: \"ai\" } }) { nodes { id name } } }"}'
```

Then add the label to the issue:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation { issueAddLabel(id: \"ISSUE_UUID\", labelId: \"AI_LABEL_ID\") { success } }"}'
```

Replace `ISSUE_UUID` with the issue UUID and `AI_LABEL_ID` with the label ID from the query above. If the "ai" label doesn't exist yet, inform the user and skip this step.

### Step 6: Cleanup (MANDATORY — DO THIS LAST)

**CRITICAL: You MUST clean up the branch and return to `main`. Leaving stale branches causes problems for subsequent `/issue-prd` runs. Do NOT skip this step.**

1. Switch back to `main`:

```bash
git checkout main
```

2. Delete the local PRD branch (it has already been pushed to remote):

```bash
git branch -D docs/prd-$ARGUMENTS
```

3. Verify you are on `main`:

```bash
git branch --show-current
```

The output MUST show `main`. If it does not, something went wrong — do NOT proceed, inform the user.

## HARD STOP

After Step 6 completes and you have verified you are on `main`, say EXACTLY:

> "PRD created for $ARGUMENTS, ai label set. You may begin working on the next issue."

Then STOP. Do not:
- Summarize the PRD contents
- Offer to implement the fix
- Suggest next steps for this issue
- Ask if the user wants to proceed with implementation

The agent runner picks up issues with the "ai" label and implements from the PRD autonomously. Your job is done.

## Notes

- **Step 0 and Step 6 are non-negotiable** — skipping them wastes API calls and leaves dirty state
- The dialog in Step 3 is the most important part — do not skip or rush it
- The PRD must include testing requirements — this is non-negotiable
- Reference real files and patterns from the codebase discovered in Step 2
- The autonomous runner will use this PRD as its sole source of truth — it must be complete
- If the issue description is very detailed, some dialog questions may be abbreviated, but always confirm testing requirements and acceptance criteria with the user
- PRD filenames use the issue identifier exactly as provided (e.g., `SMA-40.md`)
