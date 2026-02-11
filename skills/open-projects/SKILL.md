---
name: open-projects
description: Reconnect all tmux project sessions after iTerm2 restart
allowed-tools: Bash
disable-model-invocation: true
---

# Open Projects Workflow

Reconnects all existing tmux project sessions to iTerm2 windows after a
restart. Each session gets its own iTerm2 window with all tabs restored.

## Usage

```
/open-projects
```

## Instructions

### Step 1: List Sessions

```bash
SESSIONS=$(tmux ls -F '#{session_name}' 2>/dev/null)
```

If no sessions exist, report "No tmux sessions found" and stop.

### Step 2: Open Disconnected Sessions

For each session, check if it already has an active client. Only open
a new iTerm2 window for sessions without a connected client:

```bash
for SESSION in $SESSIONS; do
  CLIENT_COUNT=$(tmux list-clients -t "$SESSION" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$CLIENT_COUNT" = "0" ]; then
    osascript <<EOF
tell application "iTerm2"
  activate
  set newWindow to (create window with default profile)
  tell current session of newWindow
    write text "tmux -CC attach -t $SESSION"
  end tell
end tell
EOF
    sleep 2
  fi
done
```

Sessions that already have an active client (window is already open) are skipped.

### Step 3: Report

List all sessions and their tab counts:

```bash
tmux ls -F '#{session_name} (#{session_windows} tabs)'
```

Report in this format:

```
## Projects Restored

- dealerq (3 tabs)
- aidio (2 tabs)
- revenue-rotator (1 tab)
```

If some sessions were already connected, note which ones were skipped.
