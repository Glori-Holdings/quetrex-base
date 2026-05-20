---
description: Fetch a Linear issue, evaluate it, and kick off the implementation pipeline
argument-hint: <ISSUE-ID e.g. QUE-40>
---

# Issue PRD: Pipeline Intake

## Issue: $ARGUMENTS

### Session Rename
/rename $ARGUMENTS-{M}-{D}

### Step 1: Fetch the Issue

Linear's top-level `issues` query and `issueVcSearch` are unreliable with personal API keys. Always use team-scoped queries.

Parse the team key and issue number from `$ARGUMENTS` (e.g., "QUE-40" → team key "QUE", number 40).

If $LINEAR_API_KEY is not set, stop and tell the user: "Set the LINEAR_API_KEY environment variable to your Linear API token and try again."

**Step 1a** — Get the team ID:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ teams(filter: { key: { eq: \"TEAM_KEY\" } }) { nodes { id key name } } }"}'
```

Replace `TEAM_KEY` with the parsed team key (e.g., "QUE").

**Step 1b** — Fetch the issue using the team ID:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ team(id: \"TEAM_UUID\") { issues(filter: { number: { eq: ISSUE_NUMBER } }) { nodes { id identifier title description priority state { name } labels { nodes { name } } project { name } } } }"}'
```

Replace `TEAM_UUID` with the id from Step 1a and `ISSUE_NUMBER` with the parsed number (e.g., 40).

Display clearly:
- **ID**: {identifier}
- **Title**: {title}
- **State**: {state.name}
- **Priority**: {priority}
- **Labels**: {labels}
- **Project**: {project.name}
- **Description**:
  {description}

If the issue state is "In Progress" or "Done", warn the user: "This issue is already {state.name}. Stopping to avoid duplicate work." Then stop.

### Step 2: Evaluate and Clarify

Read the issue carefully. Ask yourself: could an architect start work on this without asking follow-up questions?

The architect needs to know:
- What to build (goal is clear)
- What's in scope and out of scope
- Any technical constraints or decisions only the user can make

If the issue is clear — ask NOTHING. Proceed to Step 3.

If there are genuine gaps — ask ONLY about those specific gaps. One or two sharp questions. Not a template. Not a checklist. If the issue says "add dark mode" with no other context, ask what components need it and whether there's a design system to follow. If the issue says "fix the auth bug where users get logged out after 5 minutes" that is clear enough — ask nothing.

Wait for answers before proceeding.

### Step 3: Branch Setup

Create the feature branch:

```bash
git checkout main
git pull origin main
git checkout -b feature/$ARGUMENTS-$(echo "{title}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | cut -c1-50)
git branch --show-current
```

Confirm you are on the feature branch before continuing.

### Step 4: Comment on Linear Issue

Add a comment to the Linear issue to mark it as in progress:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation { commentCreate(input: { issueId: \"ISSUE_UUID\", body: \"Pipeline started — architect building implementation plan.\" }) { success } }"}'
```

Replace `ISSUE_UUID` with the `id` field (UUID) from the Step 1b response.

### Step 5: Hand Off

Tell the orchestrator:

> "Issue $ARGUMENTS is ready. Branch: {branch-name}. Starting pipeline: architect → developer(s) → QA → reviewer → git-workflow."

Then invoke the architect agent to create the implementation plan for this issue, passing it the issue title, description, and any clarifications from Step 2.

## Notes
- LINEAR_API_KEY must be set as an environment variable
- The architect creates the implementation PRD — this skill does not
- If the issue is already In Progress or Done, warn the user and stop
- Never set the issue to "Queued" — that was the old runner pattern
