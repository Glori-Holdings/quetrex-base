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

# Check current branch
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null)

if [ "$CURRENT_BRANCH" = "main" ] || [ "$CURRENT_BRANCH" = "master" ]; then
  echo '{"decision": "block", "reason": "HARD-RULE #6: Use worktrees. Cannot commit/push on main."}'
  exit 0
fi

# Not on main/master -- allow
echo '{"decision": "undefined"}'
exit 0
