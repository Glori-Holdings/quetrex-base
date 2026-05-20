---
name: story-builder
description: Build comprehensive user stories through structured developer interview — feeds into domain-capture for business logic extraction
argument-hint: <path-to-prd.md OR "new" for interactive creation>
disable-model-invocation: true
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, AskUserQuestion
---

# User Story Builder

## Input Validation

Input: `$ARGUMENTS`

If `$ARGUMENTS` is empty or missing, say: "Usage: `/story-builder .claude/prds/project-prd.md` or `/story-builder new`" and STOP.

If `$ARGUMENTS` is "new", we will create stories from scratch through interview.
If `$ARGUMENTS` is a file path, verify the file exists. If not, say: "PRD not found at {path}" and STOP.

## Step 1: Identify User Types

### If working from a PRD:

Read the PRD file. Extract every mentioned user type, role, or persona. Present them:

"I found these user types in the PRD:
1. {user type 1} — {brief description}
2. {user type 2} — {brief description}
..."

Ask: "Are these all the user types? Are there any I missed? Any that interact with the system indirectly (admins, testers, API consumers, external systems)?"

### If "new" (no PRD):

Ask: "Who are ALL the people and systems that interact with this application? Think about:
- The primary end user
- Administrators or managers
- Other team roles (testers, support staff, etc.)
- External systems that send data in (webhooks, APIs)
- Background processes that act autonomously

List every actor, even if they only do one thing."

Wait for response. Compile the complete user type list.

## Step 2: Map User Journeys Per User Type

For EACH user type identified, walk through their complete journey:

"Let's map everything **{user type}** does. I'll walk through their journey from the moment they first interact with the system."

### Questions per user type:

**Entry Point:**
"How does {user type} first arrive? What do they see? Is there onboarding?"

**Primary Actions:**
"What are the main things {user type} does day-to-day? Walk me through a typical session."

**For each action mentioned, drill down:**
"When {user type} does {action}:
- What do they see before they act?
- What do they click/tap/submit?
- What should happen immediately (optimistic UI)?
- What should happen in the background?
- What should other users see as a result?
- What happens if it fails?
- Can they undo it?"

**Edge Actions:**
"What does {user type} do that's NOT part of the daily routine? Settings changes, bulk operations, exports, one-time setup?"

**Exit Points:**
"How does {user type} leave? Do they log out? Does the session expire? Is there state to preserve?"

## Step 3: Write User Stories

After each user type's journey is complete, write the stories IMMEDIATELY (don't wait for all user types).

Create or append to `.claude/user-stories/{user-type-slug}.md`:

```markdown
# User Stories: {User Type Name}

## Role Description
{Who this person is, what they care about, their skill level}

## Daily Workflow
{The typical session flow, in order}

---

### Story: {Short descriptive name}

**As a** {user type},
**I want to** {specific action with detail},
**So that** {business value or outcome}.

#### Scenario: Happy Path
```
GIVEN {starting state}
WHEN {user action}
THEN {expected result}
AND {additional consequences — count updates, notifications, status changes}
```

#### Scenario: Error Case
```
GIVEN {starting state}
WHEN {user action with bad input or failed condition}
THEN {error handling — what user sees, what gets rolled back}
```

#### Scenario: Edge Case
```
GIVEN {unusual but valid starting state}
WHEN {user action}
THEN {expected behavior in this edge case}
```

#### Affected Entities
- {entity}: {what changes — field, value, side effect}
- {entity}: {what changes}

#### Business Rules
- {any rule that governs this action}
- {any invariant that must hold}

#### UI States
- **Loading**: {what user sees while action processes}
- **Success**: {what user sees on success}
- **Error**: {what user sees on failure}
- **Empty**: {what user sees if there's no data}

---
```

Write stories using the GIVEN/WHEN/THEN format. This is critical — it makes the stories directly testable and directly translatable to business rules for the domain expert.

**Every story MUST include:**
- At least the happy path scenario
- Affected entities with specific field changes
- Business rules that govern the action
- UI states (loading, success, error, empty)

**Add edge case and error scenarios when:**
- The developer mentioned them during the interview
- The action modifies counts or status fields
- The action affects multiple entities
- The action can fail partially

## Step 4: Cross-Cutting Concerns

After all user types are covered, ask about rules that apply EVERYWHERE:

"Now let's talk about rules that apply across the entire application:

1. **Authentication**: What happens when a session expires mid-action?
2. **Authorization**: Are there actions that some user types can see but not perform?
3. **Multi-tenancy**: What's the isolation boundary? Can users ever see other tenants' data?
4. **Real-time updates**: When one user acts, do other users see updates immediately?
5. **Audit trail**: Are there actions that need to be logged for compliance?
6. **Rate limiting**: Are there actions that need throttling?
7. **Data retention**: Is anything soft-deleted vs hard-deleted?"

Write cross-cutting stories to `.claude/user-stories/cross-cutting.md`.

## Step 5: Write Story Index

Create `.claude/user-stories/INDEX.md`:

```markdown
# User Stories Index

Generated: {today's date}
Project: {project name or directory}

## User Types
| User Type | Story Count | File |
|-----------|-------------|------|
| {type} | {count} | {filename} |

## Story Summary
| ID | Story Name | User Type | Entities Affected | Has Edge Cases |
|----|-----------|-----------|-------------------|----------------|
| US-001 | {name} | {type} | {entities} | Yes/No |

## Cross-Cutting Rules
{count} rules documented in cross-cutting.md

## Coverage Gaps
{list any areas the developer wants to revisit later}

## Next Step
Run `/domain-capture greenfield .claude/user-stories/INDEX.md` to extract
business rules from these stories into the knowledge base.
```

## Step 6: Commit

```bash
git add .claude/user-stories/
git commit -m "docs: add user stories from story-builder session"
```

Report to the user:

> **User stories complete.**
> - User types covered: {count}
> - Total stories: {count}
> - Stories with edge cases: {count}
> - Cross-cutting rules: {count}
> - Coverage gaps: {count}
>
> **Next step**: Run `/domain-capture greenfield .claude/user-stories/INDEX.md`
> to extract business rules into the knowledge base.

Then STOP.

## Rules

- NEVER invent stories — only document what the developer describes
- NEVER skip the drill-down questions for primary actions
- One user type at a time — complete it fully before moving to the next
- Write stories incrementally after each user type, not at the end
- Every story must have GIVEN/WHEN/THEN scenarios — no vague descriptions
- Every story must list affected entities — this feeds the domain expert
- If the developer says "same as {other user type} but with {difference}", still write separate stories with the differences explicit
- If the developer says "I'll think about that later", add it to Coverage Gaps
- The story files are designed to feed directly into `/domain-capture greenfield` — maintain the structured format exactly
- Number stories sequentially across all files (US-001, US-002, etc.) for easy reference
