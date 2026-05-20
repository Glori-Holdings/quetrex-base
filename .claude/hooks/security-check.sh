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
if echo "$CONTENT" | grep -qE \
  'AKIA[0-9A-Z]{16}|'\
  '-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY|'\
  'sk_live_[0-9a-zA-Z]{24,}|'\
  'sk_test_[0-9a-zA-Z]{24,}|'\
  'sk-ant-[0-9a-zA-Z-]{20,}|'\
  'sk-[a-zA-Z0-9]{40,}|'\
  'ghp_[0-9a-zA-Z]{36}|'\
  'github_pat_[0-9a-zA-Z_]{59}|'\
  'xox[bpoas]-[0-9a-zA-Z-]+|'\
  'lin_api_[0-9a-zA-Z]+|'\
  'FlyV1 [a-zA-Z0-9+/]+|'\
  'rnd_[0-9a-zA-Z]{32,}'; then
  echo '{"decision": "block", "reason": "BLOCKED: Detected hardcoded secret/API key. Use environment variables or ~/.claude/secrets.env instead."}'
  exit 0
fi

exit 0
