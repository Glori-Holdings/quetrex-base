---
name: create-issue
description: Create a git worktree and feature branch for new work
argument-hint: <issue-id> <description>
allowed-tools: Bash, AskUserQuestion
disable-model-invocation: true
---

# Create Issue Workflow

Creates a git worktree with a feature branch and changes into it.

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

### Step 4: Report

```
## Issue Started

**Worktree:** ../worktrees/WORKTREE_DIR
**Branch:** BRANCH_NAME

Branch `BRANCH_NAME` created by Glen Barnhardt with Claude Code
```
