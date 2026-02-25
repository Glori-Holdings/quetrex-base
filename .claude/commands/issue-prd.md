---
description: Read a Linear issue and create a comprehensive PRD through dialog
argument-hint: <ISSUE-ID e.g. SMA-40>
---

# Create PRD from Linear Issue

## Issue to Read

Fetch the Linear issue: `$ARGUMENTS`

### Step 1: Fetch the Issue

Use curl to read the issue from Linear:

!`curl -s -X POST https://api.linear.app/graphql -H "Authorization: $LINEAR_API_KEY" -H "Content-Type: application/json" -d "{\"query\": \"{ issueVcSearch(filter: { identifier: { eq: \\\"$ARGUMENTS\\\" } }) { nodes { id identifier title description priority estimate state { name } labels { nodes { name } } project { name } team { name key } } } }\"}"`

Parse and display the issue title, description, labels, priority, and project.

If the API call fails or returns no results, try the issues query instead:

!`curl -s -X POST https://api.linear.app/graphql -H "Authorization: $LINEAR_API_KEY" -H "Content-Type: application/json" -d "{\"query\": \"{ issues(filter: { identifier: { eq: \\\"$ARGUMENTS\\\" } }) { nodes { id identifier title description priority estimate state { name } labels { nodes { name } } project { name } team { name key } } } }\"}"`

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

### Step 5: Commit and Link

After writing the PRD file:

1. Commit the PRD to the current branch:

```bash
git add .claude/prds/$ARGUMENTS.md
git commit -m "docs: add PRD for $ARGUMENTS"
```

2. Push to origin:

```bash
git push
```

3. Get the issue UUID from the Step 1 API response (the `id` field, not `identifier`), then add a comment to the Linear issue linking to the PRD:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation { commentCreate(input: { issueId: \"ISSUE_UUID\", body: \"PRD ready: .claude/prds/$ARGUMENTS.md\" }) { success } }"}'
```

Replace `ISSUE_UUID` with the actual UUID from the Step 1 response.

4. Ask the user: "Would you like to set the issue status to 'Queued' to trigger the runner?"

If yes, get the state ID for "Queued" from the team's workflow states and update the issue:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation { issueUpdate(id: \"ISSUE_UUID\", input: { stateId: \"QUEUED_STATE_ID\" }) { success issue { id state { name } } } }"}'
```

## Notes

- The dialog in Step 3 is the most important part — do not skip or rush it
- The PRD must include testing requirements — this is non-negotiable
- Reference real files and patterns from the codebase discovered in Step 2
- The autonomous runner will use this PRD as its sole source of truth — it must be complete
- If the issue description is very detailed, some dialog questions may be abbreviated, but always confirm testing requirements and acceptance criteria with the user
- PRD filenames use the issue identifier exactly as provided (e.g., `SMA-40.md`)
