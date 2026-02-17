#!/bin/bash
# HARD-RULE #3: Block edits to COMMITTED test files
# Runs on PreToolUse hook for Write|Edit
#
# Policy:
#   - Pre-existing tests (committed in HEAD) are IMMUTABLE -- fix code, not tests
#   - New test files not yet committed CAN be created and iterated on
#     (test-writer agents need to refine tests within a session)

# Read hook input from stdin
input=$(cat)

# Get tool name and file path
TOOL_NAME=$(echo "$input" | jq -r '.tool_name // empty' 2>/dev/null)
FILE_PATH=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

# Only guard Write and Edit tools
if [ "$TOOL_NAME" != "Edit" ] && [ "$TOOL_NAME" != "Write" ]; then
  echo '{"decision": "undefined"}'
  exit 0
fi

# Need a file path to check
if [ -z "$FILE_PATH" ]; then
  echo '{"decision": "undefined"}'
  exit 0
fi

# --- Is this a test file? ---
IS_TEST=false

BASENAME=$(basename "$FILE_PATH")
case "$BASENAME" in
  *.test.ts|*.test.tsx|*.test.js|*.test.jsx| \
  *.spec.ts|*.spec.tsx|*.spec.js|*.spec.jsx)
    IS_TEST=true
    ;;
esac

if [[ "$FILE_PATH" == *"__tests__/"* ]]; then
  IS_TEST=true
fi

# Not a test file -- allow
if [ "$IS_TEST" = false ]; then
  echo '{"decision": "undefined"}'
  exit 0
fi

# --- It's a test file. Was it committed before this session? ---

# If the file doesn't exist on disk yet, it's brand new -- allow creation
if [ ! -f "$FILE_PATH" ]; then
  echo '{"decision": "undefined"}'
  exit 0
fi

# Check if the file exists in the last commit (HEAD)
# Resolve symlinks (macOS /tmp -> /private/tmp) so path prefix stripping works
RESOLVED_DIR=$(cd "$(dirname "$FILE_PATH")" 2>/dev/null && pwd -P)
RESOLVED_PATH="$RESOLVED_DIR/$(basename "$FILE_PATH")"
REPO_ROOT=$(git -C "$RESOLVED_DIR" rev-parse --show-toplevel 2>/dev/null)
if [ -n "$REPO_ROOT" ]; then
  RELATIVE_PATH="${RESOLVED_PATH#$REPO_ROOT/}"
  if git -C "$REPO_ROOT" cat-file -e "HEAD:$RELATIVE_PATH" 2>/dev/null; then
    # File exists in HEAD -- this is a pre-existing test. BLOCK.
    echo '{"decision": "block", "reason": "HARD-RULE #3: Tests are immutable. Fix code, not tests."}'
    exit 0
  else
    # File is NOT in HEAD -- it was created in this session. Allow iteration.
    echo '{"decision": "undefined"}'
    exit 0
  fi
fi

# Not in a git repo -- fall back to blocking (safe default)
echo '{"decision": "block", "reason": "HARD-RULE #3: Tests are immutable. Fix code, not tests."}'
exit 0
