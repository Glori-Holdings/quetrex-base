#!/bin/bash
# Require user approval for sensitive operations
# Runs on PreToolUse hook for Bash commands

# Read hook input from stdin
input=$(cat)

# Get the command being executed
COMMAND=$(echo "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)

# Deployment commands allowed - CLAUDE.md requires asking for approval before deploying
# The approval workflow is handled in the conversation, not the hook

# PR creation is allowed - /close-issue workflow handles quality checks
# The user invoking /close-issue IS their approval to create the PR

# PR merge is allowed - /close-issue workflow handles the full approval
# The user invoking /close-issue IS their approval to merge

# Block force push to main/master
if [[ "$COMMAND" == *"git push"* ]] && [[ "$COMMAND" == *"--force"* ]] && ([[ "$COMMAND" == *"main"* ]] || [[ "$COMMAND" == *"master"* ]]); then
  echo '{"decision": "block", "reason": "FORCE PUSH TO MAIN BLOCKED - This is a destructive operation. Ask user for explicit approval."}'
  exit 0
fi

# Allow all other commands
echo '{"decision": "undefined"}'
exit 0
