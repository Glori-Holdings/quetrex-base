---
name: create-issue
description: Create a git worktree and tmux window for new work (legacy — prefer /create-issue skill)
argument-hint: <issue-id> <description>
allowed-tools: Bash, AskUserQuestion
---

# Create Issue Workflow (Legacy)

> **Note:** The `/create-issue` skill (`skills/create-issue/SKILL.md`) is the canonical version. This command is kept for tmux-based workflows.

Creates a git worktree, opens a tmux window, and launches Claude in it.

## Usage

```
/create-issue DQ-1 Add user preference settings
/create-issue AI-3 Fix the login button not working
```

## Instructions

### Step 1: Parse Arguments

If `$ARGUMENTS` is provided, split into:
- **Issue ID**: first token (e.g., `DQ-1`)
- **Description**: remaining tokens (e.g., `Add user preference settings`)

If no arguments, ask:
1. "What is the issue ID?" (e.g., `DQ-1`)
2. "Describe the issue"

### Step 2: Generate Names

From issue ID and description, generate:
- **Branch Name**: `issue/ISSUE_ID-description-kebab-case` (e.g., `issue/DQ-1-add-user-preferences`)
- **Worktree Dir**: `ISSUE_ID-description-kebab-case` (e.g., `DQ-1-add-user-preferences`)

### Step 3: Create Worktree

```bash
PROJECT_ROOT=$(git rev-parse --show-toplevel)
cd "$PROJECT_ROOT"
git worktree add "../worktrees/$WORKTREE_DIR" -b "$BRANCH_NAME"
```

### Step 4: Open tmux Window and Launch Claude

```bash
SESSION=$(tmux display-message -p '#S')
WORKTREE_PATH=$(cd "$(git rev-parse --show-toplevel)/../worktrees/$WORKTREE_DIR" && pwd)
tmux new-window -t "$SESSION" -n "$WORKTREE_DIR" -c "$WORKTREE_PATH"
tmux send-keys -t "$SESSION:$WORKTREE_DIR" 'claude' Enter
```

### Step 5: Report Success

```
## Issue Started

**Worktree:** ../worktrees/WORKTREE_DIR
**Branch:** BRANCH_NAME
**tmux window:** WORKTREE_DIR

Branch `BRANCH_NAME` created by Glen Barnhardt with Claude Code
```
