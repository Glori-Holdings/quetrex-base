#!/bin/bash
# HARD-RULE #3: Block edits to existing test files
# Runs on PreToolUse hook for Write|Edit
# Edit is always blocked on test files
# Write is allowed for NEW test files (file doesn't exist yet)
# Write is blocked for EXISTING test files (overwriting is forbidden)

# Read hook input from stdin
input=$(cat)

# Get tool name and file path
TOOL_NAME=$(echo "$input" | jq -r '.tool_name // empty' 2>/dev/null)
FILE_PATH=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

# Block Edit always on test files
# Block Write ONLY on existing test files (new test files are allowed)
if [ "$TOOL_NAME" = "Edit" ]; then
  : # fall through to test-file pattern matching below
elif [ "$TOOL_NAME" = "Write" ]; then
  # Allow Write if the file doesn't exist yet (new test file)
  if [ ! -f "$FILE_PATH" ]; then
    echo '{"decision": "undefined"}'
    exit 0
  fi
  # File exists -- fall through to test-file pattern matching
else
  echo '{"decision": "undefined"}'
  exit 0
fi

if [ -z "$FILE_PATH" ]; then
  echo '{"decision": "undefined"}'
  exit 0
fi

# Check if path matches test file patterns
BASENAME=$(basename "$FILE_PATH")
case "$BASENAME" in
  *.test.ts|*.test.tsx|*.test.js|*.test.jsx| \
  *.spec.ts|*.spec.tsx|*.spec.js|*.spec.jsx)
    echo '{"decision": "block", "reason": "HARD-RULE #3: Tests are immutable. Fix code, not tests."}'
    exit 0
    ;;
esac

# Check if file is inside a __tests__ directory
if [[ "$FILE_PATH" == *"__tests__/"* ]]; then
  echo '{"decision": "block", "reason": "HARD-RULE #3: Tests are immutable. Fix code, not tests."}'
  exit 0
fi

# Not a test file -- allow
echo '{"decision": "undefined"}'
exit 0
