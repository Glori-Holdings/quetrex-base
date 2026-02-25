---
name: tab-control
description: Create or update .wezterm/project.md with tab name and color
allowed-tools: Bash, AskUserQuestion, Read, Write
disable-model-invocation: true
---

# Tab Control Workflow

Creates or updates a `.wezterm/project.md` file in the project root with a
tab name on line 1 and a tab color on line 2. If the file already exists,
shows the current values and lets the user change them.

## Usage

```
/tab-control
```

## Instructions

### Step 1: Detect Project Root

```bash
PROJECT_ROOT=$(git rev-parse --show-toplevel)
```

### Step 2: Check for Existing Configuration

Check if `.wezterm/project.md` already exists:

```bash
test -f "$PROJECT_ROOT/.wezterm/project.md" && echo "exists" || echo "missing"
```

**If it exists**, read the current values and show them to the user:

```bash
CURRENT_NAME=$(sed -n '1p' "$PROJECT_ROOT/.wezterm/project.md")
CURRENT_COLOR=$(sed -n '2p' "$PROJECT_ROOT/.wezterm/project.md")
```

Tell the user: "Current tab config: **NAME** with **COLOR** color."

### Step 3: Ask for Name

Use AskUserQuestion to ask: "What name should appear on the tab?"

- If updating an existing config, include the current name as the first
  option with "(Keep current)" appended, plus an "Other" option for custom input.
- If creating new, just ask with a free-text prompt (provide the project
  directory basename as a suggested default).

### Step 4: Ask for Color

Use AskUserQuestion to ask: "Which color for the tab?"

Offer these 5 options (all values are hex color codes):
1. **Cyan** - `#00CED1`
2. **Gold** - `#FFD700`
3. **Light Blue** - `#87CEEB`
4. **Orange** - `#FF7F50`
5. **Green** - `#32CD32`

If updating an existing config, note which color is currently selected in
the option descriptions.

### Step 5: Write Configuration

Create the directory and file:

```bash
mkdir -p "$PROJECT_ROOT/.wezterm"
```

Write `project.md` with exactly two lines:
- Line 1: the chosen name
- Line 2: the chosen hex color code (e.g., `#87CEEB`)

Use the Write tool to create `$PROJECT_ROOT/.wezterm/project.md`.

### Step 6: Report

```
## Tab Configured

**Name:** CHOSEN_NAME
**Color:** CHOSEN_COLOR
**File:** .wezterm/project.md
```

If this was an update, note what changed.
