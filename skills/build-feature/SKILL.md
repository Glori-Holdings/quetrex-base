---
name: build-feature
description: Orchestrate an agent team to build a feature from a plan document or description
argument-hint: [plan-path-or-description]
disable-model-invocation: true
---

# Build Feature with Agent Team

## When to Use

Use this skill when you need multiple agents collaborating on a feature that
touches 3+ files across layers (UI + API + DB). For simpler changes, work
directly without a team.

## Arguments

- `$ARGUMENTS` — Path to a markdown plan file, OR an inline feature description

## Instructions

### Step 1: Read the Plan

If `$ARGUMENTS` is a file path (ends in .md or contains /), read the file.
Otherwise, treat the arguments as an inline feature description.

Understand:
- What are we building?
- What components/layers are involved?
- What are the dependencies between components?

### Step 2: Load Orchestration Protocol

Read `~/.claude/team-protocol.md` for the full orchestration protocol.
This contains the contract-first development process, staggered spawning
rules, file ownership, validation gates, and anti-patterns.

You MUST follow this protocol for the rest of the build.

### Step 3: Set Mode

You are running in **INTERACTIVE** mode:
- You MAY ask the user clarifying questions before creating the team
- You SHOULD present a summary of the plan and get user confirmation
- You SHOULD launch the agent-surveillance dashboard before TeamCreate

### Step 4: Present Plan for Approval

Before creating any team or spawning agents, present to the user:

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

### Step 5: Launch Surveillance Dashboard

Invoke `/agent-surveillance` to start the monitoring dashboard at http://localhost:3847.

### Step 6: Execute Protocol

Follow the orchestration protocol from `~/.claude/team-protocol.md`:
1. Phase 1: Define contracts (you already did this in Step 4)
2. Phase 2: Staggered team creation
3. Phase 3: Coordination
4. Phase 4: Validation
5. Phase 5: Cleanup

### Step 7: Report Completion

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
