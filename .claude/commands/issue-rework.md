---
description: Create a rework document from tester feedback on a previously completed issue
argument-hint: <ISSUE-ID e.g. SMA-62>
---

# Rework Issue from Tester Feedback

## Issue to Rework

Rework the Linear issue: `$ARGUMENTS`

### Rename Session

Before doing anything else, rename this Claude Code session:

```
/rename rework-$ARGUMENTS-{M}-{D}
```

For example, if the issue is SMA-62 and today is March 16: `/rename rework-SMA-62-3-16`

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

3. Create a feature branch for the rework doc:

```bash
git checkout -b docs/rework-$ARGUMENTS
```

4. Verify you are on the new branch (NOT `main`):

```bash
git branch --show-current
```

The output MUST show `docs/rework-$ARGUMENTS`. Do NOT proceed until confirmed.

If `git checkout main` fails because of uncommitted changes on another branch, run `git stash` first, then `git checkout main`. Do NOT force-checkout or discard work.

### Step 1: Fetch the Issue + Tester Comments

Linear's top-level `issues` query and `issueVcSearch` are unreliable with personal API keys. Always use team-scoped queries.

Parse the team key and issue number from `$ARGUMENTS` (e.g., "SMA-62" -> team key "SMA", number 62).

**Step 1a** — Get the team ID:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ teams(filter: { key: { eq: \"TEAM_KEY\" } }) { nodes { id key name } } }"}'
```

Replace `TEAM_KEY` with the parsed team key (e.g., "SMA").

**Step 1b** — Fetch the issue with ALL comments:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ team(id: \"TEAM_UUID\") { issues(filter: { number: { eq: ISSUE_NUMBER } }) { nodes { id identifier title description priority estimate state { name } labels { nodes { name } } project { name } team { name key } comments { nodes { body createdAt user { name } } } } } }"}'
```

Display the issue summary:
- **ID**: {identifier}
- **Title**: {title}
- **State**: {state.name} (should be "Human: Changes Needed")
- **Labels**: {labels}

**Step 1c** — Extract tester feedback:

From the comments, identify the **tester's feedback comments** — these are comments that came AFTER any "PRD ready" or CI-related system comments, from non-system users (not "Glen Barnhardt" system comments about CI or PRD). Display them clearly:

> **Tester Feedback:**
> {each tester comment with date and author}

If there are no tester comments, STOP and tell the user: "No tester feedback found on $ARGUMENTS. Is the feedback in a different location?"

If $LINEAR_API_KEY is not set, stop and tell the user: "Set the LINEAR_API_KEY environment variable to your Linear API token and try again."

### Step 2: Load Context

Read the following to understand what was already built:

1. **Original PRD** — `.claude/prds/$ARGUMENTS.md` (if it exists)
2. **CLAUDE.md** — project root, for architecture context
3. **Git history** — find commits and PRs related to this issue:

```bash
git log --oneline --all --grep="$ARGUMENTS" | head -20
```

Also check for merged PRs:

```bash
gh pr list --state merged --search "$ARGUMENTS" --json number,title,mergedAt --limit 5
```

This tells the rework agent what code already exists on main.

### Step 3: Quick Dialog

This is NOT the full 5-question PRD dialog. The tester's comment IS the spec. Ask only what's needed:

**Question 1 — Scope Confirmation:**
Present a summary to the user:

> Based on tester feedback, here's what needs to change:
> {bullet list of each issue from tester comments}
>
> The original PRD specified: {relevant section from original PRD}
>
> Is this the complete scope, or is there additional context?

**Question 2 (only if needed) — Ambiguity:**
If any tester comment is unclear or could be interpreted multiple ways, ask ONE targeted follow-up. Otherwise, skip this.

Do NOT ask about architecture, testing philosophy, or acceptance criteria — derive those from the original PRD and codebase patterns.

### Step 4: Generate Rework Document

Determine the rework filename:
- If `.claude/prds/$ARGUMENTS-rework.md` does NOT exist: use `$ARGUMENTS-rework.md`
- If it exists, find the highest existing number and increment: `$ARGUMENTS-rework-2.md`, `$ARGUMENTS-rework-3.md`, etc.

Create the rework document at `.claude/prds/{filename}`:

```markdown
# $ARGUMENTS Rework: {Title}

## Tester Feedback

{Verbatim tester comments with dates — this is the source of truth for what to fix}

## What Was Already Implemented

- PR #{number}: {title} (merged {date})
- Key files modified: {list from PR}

## What Needs to Change

{For each piece of tester feedback, specify:}

### {Feedback item 1 summary}

**Problem**: {what the tester reported}
**Root cause**: {your analysis of why this happened — reference specific files/lines if possible}
**Fix**: {what needs to change, with specific file paths}

### {Feedback item 2 summary}

{same structure}

## Files to Modify

{List each file with its absolute path and what changes are needed}

## Testing Requirements

- [ ] {specific test derived from tester feedback — e.g., "Verify audit log menu item appears for admin role"}
- [ ] {regression test — ensure original functionality still works}
- [ ] All CI checks pass: type-check, lint, test, build

## Acceptance Criteria

- [ ] {directly maps to each piece of tester feedback}
- [ ] {e.g., "Lead Form Event field saves selected value and persists on form submission"}
- [ ] No TypeScript errors, no lint warnings
- [ ] Code follows existing project patterns
```

### Step 5: Commit, Push, and Update Linear

1. Stage and commit the rework doc:

```bash
git add .claude/prds/$ARGUMENTS-rework*.md
git commit -m "docs: add rework document for $ARGUMENTS"
```

2. Push the branch:

```bash
git push -u origin docs/rework-$ARGUMENTS
```

3. Add a comment to the Linear issue:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation { commentCreate(input: { issueId: \"ISSUE_UUID\", body: \"Rework document ready: .claude/prds/{REWORK_FILENAME}\" }) { success } }"}'
```

Replace `ISSUE_UUID` with the UUID from Step 1, and `{REWORK_FILENAME}` with the actual filename used.

### Step 6: Set Linear Status to Todo

Get the "Todo" state ID:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ team(id: \"TEAM_UUID\") { states(filter: { name: { eq: \"Todo\" } }) { nodes { id name } } } }"}'
```

Update the issue status:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation { issueUpdate(id: \"ISSUE_UUID\", input: { stateId: \"TODO_STATE_ID\" }) { success issue { id state { name } } } }"}'
```

### Step 7: Cleanup (MANDATORY — DO THIS LAST)

1. Switch back to `main`:

```bash
git checkout main
```

2. Delete the local rework doc branch:

```bash
git branch -D docs/rework-$ARGUMENTS
```

3. Verify you are on `main`:

```bash
git branch --show-current
```

## HARD STOP

After Step 7 completes and you have verified you are on `main`, say EXACTLY:

> "Rework document created for $ARGUMENTS. Run /issue-prd $ARGUMENTS to kick off the implementation pipeline."

Then STOP. Do not:
- Summarize the rework document contents
- Offer to implement the fix
- Suggest next steps for this issue
- Ask if the user wants to proceed with implementation

## Notes

- Step 0 and Step 7 are non-negotiable — skipping them wastes API calls and leaves dirty state
- The dialog in Step 3 should be FAST — the tester's comment is the spec, not a starting point for a new PRD
- The rework document must be self-contained enough that an agent can implement without asking questions
- Always reference the original PRD for context but do NOT copy its full content into the rework doc
- If the issue has been reworked before, reference previous rework docs so the agent knows the history
