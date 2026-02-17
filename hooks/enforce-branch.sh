#!/bin/bash
# HARD-RULE #6: Block git commit/push on main/master
# Runs on PreToolUse hook for Bash
# Work should happen in worktrees, not on main

# Read hook input from stdin
input=$(cat)

# Get the command being executed
COMMAND=$(echo "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  echo '{"decision": "undefined"}'
  exit 0
fi

# Only check git commit and git push commands
if [[ "$COMMAND" != *"git commit"* ]] && [[ "$COMMAND" != *"git push"* ]]; then
  echo '{"decision": "undefined"}'
  exit 0
fi

# Extract target directory from command patterns:
#   cd /path && git commit ...
#   git -C /path commit ...
TARGET_DIR=""
if [[ "$COMMAND" =~ cd[[:space:]]+([^&\;]+)[[:space:]]*\&\& ]]; then
  TARGET_DIR="${BASH_REMATCH[1]}"
  # Trim whitespace and quotes
  TARGET_DIR=$(echo "$TARGET_DIR" | sed 's/^[ "'\'']*//;s/[ "'\'']*$//')
elif [[ "$COMMAND" =~ git[[:space:]]+-C[[:space:]]+([^[:space:]]+) ]]; then
  TARGET_DIR="${BASH_REMATCH[1]}"
fi

# Check current branch (in target dir if specified, else CWD)
if [ -n "$TARGET_DIR" ] && [ -d "$TARGET_DIR" ]; then
  CURRENT_BRANCH=$(git -C "$TARGET_DIR" branch --show-current 2>/dev/null)
else
  CURRENT_BRANCH=$(git branch --show-current 2>/dev/null)
fi

if [ "$CURRENT_BRANCH" = "main" ] || [ "$CURRENT_BRANCH" = "master" ]; then
  echo '{"decision": "block", "reason": "HARD-RULE #6: Use worktrees. Cannot commit/push on main."}'
  exit 0
fi

# Not on main/master -- allow
echo '{"decision": "undefined"}'
exit 0
