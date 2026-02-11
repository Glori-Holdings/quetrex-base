#!/bin/bash
# HARD-RULE #1: Block edits to protected config files
# Runs on PreToolUse hook for Write|Edit
# Config files should not be modified to fix code issues

# Read hook input from stdin
input=$(cat)

# Get the file path being edited
FILE_PATH=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

if [ -z "$FILE_PATH" ]; then
  echo '{"decision": "undefined"}'
  exit 0
fi

# Extract basename for matching
BASENAME=$(basename "$FILE_PATH")

# Protected config files
case "$BASENAME" in
  tsconfig.json|biome.json|biome.jsonc|eslint.config.js|eslint.config.mjs| \
  .eslintrc.js|.eslintrc.json|.eslintrc.yml|.eslintrc.yaml| \
  vitest.config.ts|vitest.config.js|vitest.config.mts| \
  next.config.ts|next.config.js|next.config.mjs| \
  tailwind.config.ts|tailwind.config.js| \
  drizzle.config.ts|drizzle.config.js)
    echo '{"decision": "block", "reason": "HARD-RULE #1: Cannot modify config. Fix code, not config."}'
    exit 0
    ;;
esac

# Not a protected file -- allow
echo '{"decision": "undefined"}'
exit 0
