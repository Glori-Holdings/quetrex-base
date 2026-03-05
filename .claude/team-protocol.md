# Agent Team Protocol

## When to Use Teams
Use agent teams when work touches 3+ files across layers (UI + API + DB).
For simpler work, use subagents or work directly.

## Team Structure
- **Lead**: Plans, creates tasks, coordinates. Never writes code.
- **Teammates**: Independent Claude instances that claim and complete tasks.
- Teams are self-coordinating via a shared task list.

## How It Works

### 1. Plan
- Break work into tasks with clear file ownership
- No two teammates should edit the same file
- Each task should be independently testable
- Define 5-6 tasks per teammate

### 2. Create Team
- Start with 3-5 teammates for most workflows
- Give each teammate enough context (they don't inherit your conversation)
- Include: what to build, which files they own, relevant patterns

### 3. Coordinate
- Monitor via TaskList
- Send messages to specific teammates when needed
- Don't broadcast — target the teammate who needs the info

### 4. Validate
- Each teammate runs verification before marking tasks complete
- Lead does a final check: type-check, lint, test, build all pass
- If anything fails, send feedback to the responsible teammate

## Task Design
- Each task has a clear deliverable (a file, a function, a test)
- Tasks declare dependencies (use addBlockedBy/addBlocks)
- Tasks include acceptance criteria

## File Ownership
This is the #1 rule: **no two teammates edit the same file.**
- Split work along file boundaries
- Shared types/interfaces go in a task that completes first
- Other tasks depend on the shared types task

## Quality
- Every teammate runs `npm run type-check && npm run lint` before completing
- Tests are written by the teammate who owns the code
- Lead verifies all checks pass before creating PR
