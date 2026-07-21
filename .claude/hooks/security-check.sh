#!/bin/bash
# Block writes and edits containing hardcoded secrets/API keys
# Runs on PreToolUse hook for Write|Edit

input=$(cat)
TOOL_NAME=$(echo "$input" | jq -r '.tool_name // empty' 2>/dev/null)

# Extract content based on tool type
if [ "$TOOL_NAME" = "Write" ]; then
  CONTENT=$(echo "$input" | jq -r '.tool_input.content // empty' 2>/dev/null)
elif [ "$TOOL_NAME" = "Edit" ]; then
  CONTENT=$(echo "$input" | jq -r '.tool_input.new_string // empty' 2>/dev/null)
else
  exit 0
fi

if [ -z "$CONTENT" ]; then
  exit 0
fi

# Secret patterns — add new services here as needed
PATTERN='AKIA[0-9A-Z]{16}'
PATTERN="$PATTERN"'|-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY'
PATTERN="$PATTERN"'|sk_live_[0-9a-zA-Z]{24,}'
PATTERN="$PATTERN"'|sk_test_[0-9a-zA-Z]{24,}'
PATTERN="$PATTERN"'|sk-ant-[0-9a-zA-Z-]{20,}'
PATTERN="$PATTERN"'|sk-[a-zA-Z0-9]{40,}'
PATTERN="$PATTERN"'|ghp_[0-9a-zA-Z]{36}'
PATTERN="$PATTERN"'|github_pat_[0-9a-zA-Z_]{59}'
PATTERN="$PATTERN"'|xox[bpoas]-[0-9a-zA-Z-]+'
PATTERN="$PATTERN"'|lin_api_[0-9a-zA-Z]+'
PATTERN="$PATTERN"'|FlyV1 [a-zA-Z0-9+/]+'
PATTERN="$PATTERN"'|rnd_[0-9a-zA-Z]{32,}'
if printf '%s' "$CONTENT" | grep -qE -- "$PATTERN"; then
  jq -cn '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"Hardcoded secret/API key detected. Use environment variables or ~/.claude/secrets.env instead."}}'
  exit 0
fi

exit 0
