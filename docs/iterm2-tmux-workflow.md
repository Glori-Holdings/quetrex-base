# iTerm2 + tmux -CC Multi-Project Session Workflow

**Owner:** Glen Barnhardt
**Created:** 2026-01-31
**Updated:** 2026-01-31
**System:** macOS (Darwin 25.2.0, arm64 / Apple Silicon)
**tmux:** 3.5a (installed via Homebrew at `/opt/homebrew/bin/tmux`)
**iTerm2:** Build 3.5.x+ (must support tmux integration mode)

---

## Overview

Each project gets its own tmux session and iTerm2 window. Issues are tabs
within that window. Sessions persist across iTerm2 restarts.

```
quetrex-base (window)      aidio (window)
├── QX-1 : Fix login       ├── AI-1 : Add voice
├── QX-2 : Add cart         └── AI-3 : Fix export
└── (main shell)
```

Key properties:

- **One tmux session per project** (session name = git repo directory name)
- tmux windows appear as **native iTerm2 tabs** within that project's window
- **AppleScript** opens new iTerm2 windows per project, reusing the
  "Glen Barnhardt" profile with a per-project command override
- **Session persistence** via tmux server surviving iTerm2 restarts
- **`/open-projects`** reconnects all sessions after restart
- `/create-issue` and `/close-issue` manage the full lifecycle
- All standard tmux commands (`new-window`, `send-keys`, `kill-window`)
  are fully compatible with `-CC` mode

No `.tmux.conf` file is needed. The tmux defaults work correctly with
iTerm2 integration mode.

---

## Prerequisites

1. **macOS** with iTerm2 installed
2. **tmux** installed via Homebrew:
   ```bash
   brew install tmux
   ```
3. **iTerm2** with at least two profiles:
   - `Default` (index 0, GUID: `09140F75-3904-4E18-9146-203BE33B8CBC`)
   - `Glen Barnhardt` (index 1, GUID: `A70981FC-B8D3-4A31-B4EB-05CA037AE04C`)
4. The `Glen Barnhardt` profile is the **default startup profile**
   (`Default Bookmark Guid` matches its GUID)

---

## iTerm2 Configuration

### Plist Location

```
~/Library/Preferences/com.googlecode.iterm2.plist
```

### Setting 1: OpenTmuxWindowsIn (Global)

Controls how tmux windows are displayed in iTerm2's tmux integration mode.

| Value | Behavior |
|-------|----------|
| 0 | Separate native windows (default -- bad, clutters desktop) |
| 1 | Tabs in a new window |
| **2** | **Tabs in the existing window (what we use)** |

**Command to set:**

```bash
defaults write com.googlecode.iterm2 OpenTmuxWindowsIn -int 2
```

**Command to verify:**

```bash
defaults read com.googlecode.iterm2 OpenTmuxWindowsIn
# Expected output: 2
```

### Setting 2: Glen Barnhardt Profile -- Custom Command

The startup profile runs `tmux -CC` to connect to the "main" session on
launch. Per-project sessions are created separately by `/create-issue`.

**Profile array index:** `1` (under `New Bookmarks` in the plist)
**Profile name:** `Glen Barnhardt`
**Profile GUID:** `A70981FC-B8D3-4A31-B4EB-05CA037AE04C`

Two keys must be set on this profile:

| Key | Value | Purpose |
|-----|-------|---------|
| `Custom Command` | `Yes` | Enables a custom startup command instead of default shell |
| `Command` | `tmux -CC new-session -A -s main` | The command to run on profile launch |

**Command breakdown:**

| Flag | Meaning |
|------|---------|
| `-CC` | iTerm2 tmux integration mode (control mode with extra features) |
| `new-session` | Create a new tmux session |
| `-A` | Attach to existing session if it exists, otherwise create new |
| `-s main` | Session name is "main" |

The `-A` flag is critical -- it means iTerm2 will **reconnect** to the
existing tmux session on restart instead of creating a duplicate.

**Commands to set:**

```bash
# Enable custom command on the profile
/usr/libexec/PlistBuddy -c "Set :'New Bookmarks':1:'Custom Command' 'Yes'" \
  ~/Library/Preferences/com.googlecode.iterm2.plist

# Set the command (use Set if key exists, Add if it doesn't)
/usr/libexec/PlistBuddy -c "Set :'New Bookmarks':1:'Command' 'tmux -CC new-session -A -s main'" \
  ~/Library/Preferences/com.googlecode.iterm2.plist 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :'New Bookmarks':1:'Command' string 'tmux -CC new-session -A -s main'" \
  ~/Library/Preferences/com.googlecode.iterm2.plist
```

### Setting 3: Default Profile (optional, recommended)

The `Default` profile (index 0) should also have the same command so that
any new iTerm2 window/tab opened via the Default profile also connects
to tmux:

```bash
/usr/libexec/PlistBuddy -c "Set :'New Bookmarks':0:'Custom Command' 'Yes'" \
  ~/Library/Preferences/com.googlecode.iterm2.plist

/usr/libexec/PlistBuddy -c "Set :'New Bookmarks':0:'Command' 'tmux -CC new-session -A -s main'" \
  ~/Library/Preferences/com.googlecode.iterm2.plist 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :'New Bookmarks':0:'Command' string 'tmux -CC new-session -A -s main'" \
  ~/Library/Preferences/com.googlecode.iterm2.plist
```

---

## How It Works End-to-End

### Normal Startup

1. Open iTerm2
2. "Glen Barnhardt" profile launches (it is the default profile)
3. Profile runs `tmux -CC new-session -A -s main`
4. If session "main" exists, iTerm2 attaches to it (restoring all tabs)
5. If session "main" does not exist, a new session is created
6. All tmux windows appear as native iTerm2 tabs
7. Project sessions are NOT auto-connected -- use `/open-projects` to restore them

### /create-issue Workflow

The `/create-issue` skill creates a git worktree, ensures the project has
a tmux session with an iTerm2 window, opens a tab for the issue, and
launches Claude in it.

**Skill file:** `.claude/skills/create-issue/SKILL.md`

**Usage:**

```
/create-issue DQ-1 Fix the login button
/create-issue AI-3 Add voice export feature
```

**Steps:**

1. **Parse arguments** -- split `$ARGUMENTS` into issue ID and description
2. **Generate names:**
   - Tab name: `DQ-1 : Fix the login button`
   - Branch name: `issue/DQ-1-fix-the-login-button`
   - Worktree dir: `DQ-1-fix-the-login-button`
3. **Detect project:**
   ```bash
   PROJECT_ROOT=$(git rev-parse --show-toplevel)
   PROJECT_NAME=$(basename "$PROJECT_ROOT")
   ```
4. **Ensure project has an iTerm2 window** via three cases:
   - **No session** -- create session + open iTerm2 window via AppleScript
   - **Session but no client** (after restart) -- open iTerm2 window via AppleScript
   - **Session with client** -- no action, new tabs appear automatically
5. **Create worktree:**
   ```bash
   git worktree add "../worktrees/$WORKTREE_DIR" -b "$BRANCH_NAME"
   ```
6. **Open tmux window and launch Claude:**
   ```bash
   WINDOW_ID=$(tmux new-window -t "$PROJECT_NAME" -n "$TAB_NAME" -c "$WORKTREE_PATH" -P -F '#{window_id}')
   tmux send-keys -t "$WINDOW_ID" 'claude' Enter
   ```
   Uses `#{window_id}` to target the window, avoiding parsing issues with
   `:` in the tab name.
7. **Report success** with issue, project, worktree, branch, and session info.

**Why AppleScript?** Each project gets its own iTerm2 window. When the
first issue for a project is created, AppleScript opens a new iTerm2
window with the default profile, then writes `tmux -CC attach -t PROJECT_NAME`
into it to establish control mode. Subsequent issues for the same project
appear as tabs in that same window.

**Important:** The `create window with profile "name" command "cmd"` syntax
does NOT work for `-CC` control mode. The working pattern is to create a
window with the default profile and use `write text` to send the tmux command.

### /close-issue Workflow

The `/close-issue` skill runs quality gates, commits, pushes, creates a
PR, merges, cleans up the worktree, and closes the tmux tab. It uses a
two-phase design where cleanup is **guaranteed** once mutations begin.

**Skill file:** `.claude/skills/close-issue/SKILL.md`

**Phase 1 (read-only):** Capture context, pre-cleanup, quality gates.
Failure = stop, no cleanup needed.

**Phase 2 (mutations):** Stage, commit, push, create PR, merge.
Failure = skip to cleanup.

**Mandatory cleanup:** Remove worktree, delete local branch, return to main.

**Close tmux tab:** `tmux kill-window` closes the native iTerm2 tab. If
it's the last window in the session, the session is destroyed automatically.

No changes were needed for multi-project support -- close-issue reads
the branch name dynamically, gets the worktree path from `pwd`, and
`tmux kill-window` works identically in any session.

### /open-projects Workflow

The `/open-projects` skill reconnects all tmux sessions to iTerm2 windows
after a restart.

**Skill file:** `.claude/skills/open-projects/SKILL.md`

**Usage:**

```
/open-projects
```

**Steps:**

1. List all tmux sessions
2. For each session without an active client, open an iTerm2 window via AppleScript
3. Skip sessions that already have an active client
4. Report which sessions were restored and their tab counts

**When to use:** After quitting and reopening iTerm2, the "main" session
reconnects automatically (via the profile command). Project sessions need
`/open-projects` to reconnect their iTerm2 windows.

### Session Persistence

1. Quit iTerm2 (Cmd+Q or close all windows)
2. tmux server continues running in the background
3. All programs in all tmux windows keep running
4. Reopen iTerm2
5. Profile runs `tmux -CC new-session -A -s main` -- "main" session reconnects
6. Run `/open-projects` to reconnect project sessions
7. All project windows and tabs are restored

**To verify the tmux server is running while iTerm2 is closed:**

```bash
# From any other terminal (Terminal.app, SSH, etc.)
tmux ls
# Expected: main: N windows ... (detached)
#           quetrex-base: N windows ... (detached)
#           aidio: N windows ... (detached)
```

### Session Lifecycle

- **Created:** When `/create-issue` runs for the first time in a project
- **Tabs added:** Each subsequent `/create-issue` adds a tab
- **Tabs removed:** Each `/close-issue` removes a tab via `tmux kill-window`
- **Destroyed:** When the last tab in a session is closed, tmux destroys the session
- **Recreated:** Next `/create-issue` in the project creates a new session

---

## Tab Naming Convention

Tabs use the format: `ISSUE_ID : Description`

Examples:
- `DQ-1 : Fix the login button`
- `AI-3 : Add voice export feature`
- `QX-12 : Refactor authentication flow`

The issue ID prefix makes it easy to identify which issue each tab belongs to.

---

## Worktree Directory Structure

```
~/Projects/
  quetrex-base/           # Main repository (main branch)
    .claude/
      skills/
        create-issue/SKILL.md
        close-issue/SKILL.md
        open-projects/SKILL.md
      docs/
        iterm2-tmux-workflow.md
      CLAUDE.md
      HARD-RULES.md
  aidio/                  # Another project
  worktrees/              # All issue worktrees live here
    DQ-1-fix-login-bug/   # Example: issue/DQ-1-fix-login-bug branch
    AI-3-add-voice/       # Example: issue/AI-3-add-voice branch
```

Each worktree gets its own tmux window (iTerm2 tab) named after the
issue. When `/close-issue` completes, both the worktree directory and
the tmux tab are removed.

---

## Complete Setup Script (from scratch)

Run this script to configure everything in one shot. **iTerm2 must be
closed before running.**

```bash
#!/bin/bash
set -euo pipefail

PLIST="$HOME/Library/Preferences/com.googlecode.iterm2.plist"
BACKUP="$PLIST.backup.$(date +%Y%m%d-%H%M%S)"
TMUX_CMD="tmux -CC new-session -A -s main"

echo "=== iTerm2 + tmux -CC Setup ==="

# Step 1: Verify tmux is installed
if ! command -v tmux &>/dev/null; then
  echo "ERROR: tmux not found. Install with: brew install tmux"
  exit 1
fi
echo "tmux version: $(tmux -V)"

# Step 2: Verify iTerm2 plist exists
if [ ! -f "$PLIST" ]; then
  echo "ERROR: iTerm2 plist not found at $PLIST"
  echo "Launch iTerm2 at least once first, then close it and re-run."
  exit 1
fi

# Step 3: Backup
cp "$PLIST" "$BACKUP"
echo "Backup created: $BACKUP"

# Step 4: Set OpenTmuxWindowsIn to 2 (tabs in existing window)
defaults write com.googlecode.iterm2 OpenTmuxWindowsIn -int 2
echo "OpenTmuxWindowsIn set to 2 (tabs in existing window)"

# Step 5: Find the "Glen Barnhardt" profile index
PROFILE_COUNT=$(/usr/libexec/PlistBuddy -c "Print :'New Bookmarks'" "$PLIST" 2>&1 | grep -c "Name =")
GB_INDEX=-1

for i in $(seq 0 $((PROFILE_COUNT - 1))); do
  NAME=$(/usr/libexec/PlistBuddy -c "Print :'New Bookmarks':$i:Name" "$PLIST" 2>&1)
  if [ "$NAME" = "Glen Barnhardt" ]; then
    GB_INDEX=$i
    break
  fi
done

if [ "$GB_INDEX" = "-1" ]; then
  echo "ERROR: 'Glen Barnhardt' profile not found in iTerm2."
  echo "Create the profile manually in iTerm2 first, then re-run."
  exit 1
fi
echo "Found 'Glen Barnhardt' profile at index $GB_INDEX"

# Step 6: Set Custom Command on Glen Barnhardt profile
/usr/libexec/PlistBuddy -c "Set :'New Bookmarks':$GB_INDEX:'Custom Command' 'Yes'" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :'New Bookmarks':$GB_INDEX:'Command' '$TMUX_CMD'" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :'New Bookmarks':$GB_INDEX:'Command' string '$TMUX_CMD'" "$PLIST"
echo "Glen Barnhardt profile configured with: $TMUX_CMD"

# Step 7: Also set on Default profile (index 0) if it exists
DEFAULT_NAME=$(/usr/libexec/PlistBuddy -c "Print :'New Bookmarks':0:Name" "$PLIST" 2>&1 || echo "")
if [ -n "$DEFAULT_NAME" ]; then
  /usr/libexec/PlistBuddy -c "Set :'New Bookmarks':0:'Custom Command' 'Yes'" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :'New Bookmarks':0:'Command' '$TMUX_CMD'" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :'New Bookmarks':0:'Command' string '$TMUX_CMD'" "$PLIST"
  echo "Default profile also configured with: $TMUX_CMD"
fi

# Step 8: Verify
echo ""
echo "=== Verification ==="
echo "OpenTmuxWindowsIn: $(defaults read com.googlecode.iterm2 OpenTmuxWindowsIn)"
echo "Glen Barnhardt Custom Command: $(/usr/libexec/PlistBuddy -c "Print :'New Bookmarks':$GB_INDEX:'Custom Command'" "$PLIST")"
echo "Glen Barnhardt Command: $(/usr/libexec/PlistBuddy -c "Print :'New Bookmarks':$GB_INDEX:'Command'" "$PLIST")"
echo ""
echo "=== Done ==="
echo "Launch iTerm2 to start using tmux integration mode."
echo "Backup saved at: $BACKUP"
```

---

## Troubleshooting

### tmux windows open as separate windows instead of tabs

```bash
defaults read com.googlecode.iterm2 OpenTmuxWindowsIn
# If not 2, fix it:
defaults write com.googlecode.iterm2 OpenTmuxWindowsIn -int 2
# Restart iTerm2
```

### iTerm2 opens plain zsh instead of tmux

Check the profile command:

```bash
/usr/libexec/PlistBuddy -c "Print :'New Bookmarks':1:'Custom Command'" \
  ~/Library/Preferences/com.googlecode.iterm2.plist
# Must be: Yes

/usr/libexec/PlistBuddy -c "Print :'New Bookmarks':1:'Command'" \
  ~/Library/Preferences/com.googlecode.iterm2.plist
# Must be: tmux -CC new-session -A -s main
```

If the profile index changed, re-discover it:

```bash
PLIST="$HOME/Library/Preferences/com.googlecode.iterm2.plist"
COUNT=$(/usr/libexec/PlistBuddy -c "Print :'New Bookmarks'" "$PLIST" 2>&1 | grep -c "Name =")
for i in $(seq 0 $((COUNT - 1))); do
  echo "Index $i: $(/usr/libexec/PlistBuddy -c "Print :'New Bookmarks':$i:Name" "$PLIST")"
done
```

### Duplicate sessions on restart

If iTerm2 creates a new session instead of attaching:

```bash
# Check existing sessions
tmux ls
# Kill duplicates
tmux kill-session -t main-copy  # or whatever the duplicate is named
```

The `-A` flag in the command should prevent this. If it happens, the
session name may not match. Verify the command uses `-s main`.

### Project window not appearing

If `/create-issue` doesn't open a new window:

1. Check if the session was created: `tmux has-session -t PROJECT_NAME`
2. Check if a client is connected: `tmux list-clients -t PROJECT_NAME`
3. Try manually:
   ```bash
   osascript <<'EOF'
   tell application "iTerm2"
     activate
     set newWindow to (create window with default profile)
     tell current session of newWindow
       write text "tmux -CC attach -t PROJECT_NAME"
     end tell
   end tell
   EOF
   ```
4. Verify iTerm2 is running: `pgrep -l iTerm`

### tmux server died

```bash
# Check if tmux is running
pgrep tmux
# If not, just open iTerm2 -- it will create a new "main" session
# Project sessions are gone -- create new issues as needed
```

### Profile GUID mismatch

If a fresh iTerm2 install generates new GUIDs, the `Default Bookmark
Guid` must be updated to match the "Glen Barnhardt" profile:

```bash
PLIST="$HOME/Library/Preferences/com.googlecode.iterm2.plist"
# Get the Glen Barnhardt GUID (adjust index if needed)
GB_GUID=$(/usr/libexec/PlistBuddy -c "Print :'New Bookmarks':1:'Guid'" "$PLIST")
# Set it as the default
/usr/libexec/PlistBuddy -c "Set :'Default Bookmark Guid' '$GB_GUID'" "$PLIST"
```

---

## Rollback

To undo all changes and return to the previous state:

```bash
# 1. Quit iTerm2
osascript -e 'tell application "iTerm2" to quit'
sleep 2

# 2. Restore OpenTmuxWindowsIn
defaults write com.googlecode.iterm2 OpenTmuxWindowsIn -int 0

# 3. Restore plist from backup
cp ~/Library/Preferences/com.googlecode.iterm2.plist.backup \
   ~/Library/Preferences/com.googlecode.iterm2.plist

# 4. Kill tmux server
tmux kill-server 2>/dev/null || true

# 5. Relaunch iTerm2
open -a iTerm
```

---

## Key Concepts

### Why -CC mode and not regular tmux?

| Feature | Regular tmux | tmux -CC (integration mode) |
|---------|--------------|-----------------------------|
| Tab appearance | tmux status bar, nested terminal | Native iTerm2 tabs |
| Scrollback | tmux scrollback buffer | Native iTerm2 scrollback |
| Copy/paste | tmux copy mode | Native macOS Cmd+C/V |
| Mouse support | Must configure in tmux | Native iTerm2 mouse support |
| Font rendering | Single font across panes | Per-tab iTerm2 profiles |
| Session persistence | Yes | Yes |
| `new-window` command | Creates tmux window | Creates native iTerm2 tab |
| `send-keys` command | Works | Works |
| `kill-window` command | Closes tmux window | Closes native iTerm2 tab |

The `-CC` flag stands for "control mode with cooked input." iTerm2
intercepts tmux's control protocol and renders tmux windows as native
tabs instead of inside a terminal multiplexer UI.

### Why one session per project?

- **Tab grouping:** All issue tabs for a project are in one window
- **Clean desktop:** Projects don't intermix their tabs
- **Independent lifecycle:** Closing all issues for a project destroys
  only that session
- **Restart recovery:** `/open-projects` can reconnect each project
  independently

### Why -A flag?

The `-A` flag on `new-session` means "attach if session exists." This
is what enables the reconnect-on-restart behavior:

- First launch: no "main" session exists, so tmux creates one
- Restart: "main" session exists, so tmux attaches to it
- All windows/tabs are preserved because the tmux server never stopped

### Why AppleScript for per-project windows?

The iTerm2 profile command only runs at startup (for the "main" session).
Project sessions are created dynamically by `/create-issue`. AppleScript
opens a new iTerm2 window and writes the `tmux -CC attach` command into it.

**Important:** The `create window with profile "name" command "cmd"` syntax
does NOT establish `-CC` control mode correctly. The working pattern is:

```applescript
tell application "iTerm2"
  activate
  set newWindow to (create window with default profile)
  tell current session of newWindow
    write text "tmux -CC attach -t SESSION_NAME"
  end tell
end tell
```

This creates a window, then sends the tmux command as typed input, which
properly establishes the `-CC` control mode connection.

### Why no .tmux.conf?

The tmux defaults work correctly with `-CC` mode. No status bar
configuration is needed (iTerm2 provides its own tab bar). No mouse
configuration is needed (iTerm2 handles mouse natively). No key
bindings are needed (the skills use tmux commands directly, not
keyboard shortcuts).

---

## Version History

| Date | Change |
|------|--------|
| 2026-01-31 | Multi-project architecture: one session per project, AppleScript windows, /open-projects skill |
| 2026-01-31 | Initial setup: OpenTmuxWindowsIn=2, profile command=tmux -CC |
