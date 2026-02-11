---
name: create-issue
description: Create a git worktree and tmux window for new work
argument-hint: [issue description]
allowed-tools: Bash, AskUserQuestion
---

# Create Issue Workflow

Creates a git worktree, opens a tmux window, and launches Claude in it.

## Usage

```
/create-issue Add user preference settings
/create-issue Fix the login button not working
```

## Instructions

### Step 1: Parse or Ask for Description

If `$ARGUMENTS` is provided, use it as the issue description.

If no arguments, ask: "What are you working on?"

### Step 2: Generate Names

From the description, generate:
- **Issue Name**: 2-4 words, kebab-case (e.g., `add-user-preferences`)
- **Branch Name**: `issue/<issue-name>` (e.g., `issue/add-user-preferences`)

### Step 3: Create Worktree

```bash
cd $(git rev-parse --show-toplevel)
git worktree add ../worktrees/ISSUE_NAME -b issue/ISSUE_NAME
```

### Step 4: Open tmux Window and Launch Claude

```bash
SESSION=$(tmux display-message -p '#S')
WORKTREE_PATH=$(cd "$(git rev-parse --show-toplevel)/../worktrees/ISSUE_NAME" && pwd)
tmux new-window -t "$SESSION" -n "ISSUE_NAME" -c "$WORKTREE_PATH"
tmux send-keys -t "$SESSION:ISSUE_NAME" 'claude' Enter
```

### Step 5: Report Success

```
## Issue Started

**Worktree:** ../worktrees/ISSUE_NAME
**Branch:** issue/ISSUE_NAME
**tmux window:** ISSUE_NAME

Branch `issue/ISSUE_NAME` created by Glen Barnhardt with Claude Code
```
