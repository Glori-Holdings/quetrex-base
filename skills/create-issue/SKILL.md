---
name: create-issue
description: Create a git worktree and feature branch, then orchestrate an agent team to build it
argument-hint: <issue-id> <description>
allowed-tools: Bash, AskUserQuestion, Read, Glob, Grep, Task, TeamCreate, TeamDelete, SendMessage, TaskCreate, TaskList, TaskGet, TaskUpdate, TaskOutput, TaskStop
---

# Create Issue Workflow

Creates a git worktree with a feature branch, then orchestrates an agent team
to build the feature using the team protocol.

## Usage

```
/create-issue DQ-1 Fix the login button
/create-issue AI-3 Add voice export feature
```

## Instructions

### Step 1: Parse Arguments

If `$ARGUMENTS` is provided, split into:
- **Issue ID**: first token (e.g., `DQ-1`)
- **Description**: remaining tokens (e.g., `Fix the login button`)

If no arguments, ask two questions:
1. "What is the issue ID?" (e.g., `DQ-1`)
2. "Describe the issue" (e.g., `Fix the login button`)

### Step 2: Generate Names

From issue ID and description, generate:
- **Branch name**: `issue/ISSUE_ID-description-kebab-case` (e.g., `issue/DQ-1-fix-the-login-button`)
- **Worktree dir**: `ISSUE_ID-description-kebab-case` (e.g., `DQ-1-fix-the-login-button`)

The kebab-case portion is the description lowercased with spaces replaced by hyphens.

### Step 3: Create Worktree and Change Into It

```bash
PROJECT_ROOT=$(git rev-parse --show-toplevel)
cd "$PROJECT_ROOT"
git worktree add "../worktrees/$WORKTREE_DIR" -b "$BRANCH_NAME"
cd "../worktrees/$WORKTREE_DIR"
```

### Step 4: Report Worktree Created

```
## Issue Started

**Worktree:** ../worktrees/WORKTREE_DIR
**Branch:** BRANCH_NAME

Branch `BRANCH_NAME` created by Glen Barnhardt with Claude Code
```

### Step 5: Load Orchestration Protocol

Read `~/.claude/team-protocol.md` for the full orchestration protocol.
This contains the contract-first development process, staggered spawning
rules, file ownership, validation gates, and anti-patterns.

You MUST follow this protocol for the rest of the build.

Also read `~/.claude/HARD-RULES.md` for non-negotiable rules.

### Step 6: Analyze Scope and Present Plan

You are running in **INTERACTIVE** mode:
- You MAY ask the user clarifying questions before creating the team
- You SHOULD present a summary of the plan and get user confirmation

Understand:
- What are we building?
- What components/layers are involved?
- What are the dependencies between components?

Present to the user:

```
## Build Plan

**Feature:** [name]

### Team Composition
- [N] developers: [brief role for each]
- 1 tester
- 1 reviewer

### File Ownership
- dev-1 owns: [files]
- dev-2 owns: [files]

### Contract Boundaries
- [interface/type definitions that bridge agents]

### Task Dependency Graph
[task list with dependencies]

Proceed with this plan?
```

Wait for user confirmation before proceeding.

### Step 7: Launch Surveillance Dashboard

Invoke `/agent-surveillance` to start the monitoring dashboard at http://localhost:3847.

### Step 8: Execute Protocol

Follow the orchestration protocol from `~/.claude/team-protocol.md`:
1. Phase 1: Define contracts (you already did this in Step 6)
2. Phase 2: Staggered team creation
3. Phase 3: Coordination
4. Phase 4: Validation
5. Phase 5: Cleanup

### Step 9: Report Completion

When the build is complete:

```
## Build Complete

**PR:** [URL]
**Branch:** [name]
**Files Changed:** [count]

### Quality Gates
- TypeScript: 0 errors, 0 warnings
- Lint: 0 errors, 0 warnings
- Tests: [X] passing

### Team Summary
- [agent]: [what they did]
```
