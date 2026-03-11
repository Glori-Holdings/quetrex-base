#!/bin/bash
# Block writes containing hardcoded secrets/API keys
# Runs on PreToolUse hook for Write|Edit

input=$(cat)
TOOL_NAME=$(echo "$input" | jq -r '.tool_name // empty' 2>/dev/null)

# Only check Write tool (has full content); Edit doesn't expose new_string reliably
if [ "$TOOL_NAME" != "Write" ]; then
  exit 0
fi

CONTENT=$(echo "$input" | jq -r '.tool_input.content // empty' 2>/dev/null)

if [ -z "$CONTENT" ]; then
  exit 0
fi

# Check for common secret patterns
if echo "$CONTENT" | grep -qEi '(AKIA[0-9A-Z]{16}|-----BEGIN (RSA |EC |DSA )?PRIVATE KEY|sk_live_[0-9a-zA-Z]{24,}|ghp_[0-9a-zA-Z]{36}|xox[bpoas]-[0-9a-zA-Z-]+|lin_api_[0-9a-zA-Z]+)'; then
  echo '{"decision": "block", "reason": "BLOCKED: Detected hardcoded secret/API key. Use environment variables instead."}'
  exit 0
fi

exit 0
