#!/bin/bash
# Auto-format files after edits using Biome
# Runs on PostToolUse hook for Write|Edit

input=$(cat)
FILE_PATH=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# Only format JS/TS/JSON files
case "$FILE_PATH" in
  *.ts|*.tsx|*.js|*.jsx|*.json|*.jsonc)
    # Find the nearest biome.json or biome.jsonc
    DIR=$(dirname "$FILE_PATH")
    while [ "$DIR" != "/" ]; do
      if [ -f "$DIR/biome.json" ] || [ -f "$DIR/biome.jsonc" ]; then
        npx biome format --write "$FILE_PATH" 2>/dev/null
        exit 0
      fi
      DIR=$(dirname "$DIR")
    done
    ;;
esac

exit 0
