#!/bin/bash
# auto-format.sh — PostToolUse (Write|Edit). Cosmetics only.
#
# This is NOT a gate. Formatting is the one thing it is safe to do silently;
# CORRECTNESS is checked by edit-gate.sh (same event, runs after this one) and
# proven by verify-gate.sh at Stop. Never make this script block: a formatter
# that fails is a formatter problem, not a reason to refuse a finish.
#
# Runs only where the project has already opted into Biome (a biome.json /
# biome.jsonc above the edited file) — it never imposes a formatter on a repo
# that does not use one, and never installs anything.
#
# Fixed here:
#   - the parent walk looped FOREVER on a relative path (`dirname "src"` -> "."
#     -> "." -> ...), which under the mis-scaled 10000-"second" timeout meant a
#     hung session rather than a formatted file;
#   - `jq` is no longer required to read the path (jq-free `sed` fallback);
#   - the formatter itself is capped, so `npx` reaching for the network cannot
#     stall the turn.

set -o pipefail

input=""
if [ ! -t 0 ]; then input=$(cat); fi
[ -z "$input" ] && exit 0

FILE_PATH=""
if command -v jq >/dev/null 2>&1; then
  FILE_PATH=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
fi
if [ -z "$FILE_PATH" ]; then
  FILE_PATH=$(printf '%s' "$input" | tr -d '\n' | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
fi
[ -z "$FILE_PATH" ] && exit 0
[ -f "$FILE_PATH" ] || exit 0

case "$FILE_PATH" in
  *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.json|*.jsonc) ;;
  *) exit 0 ;;
esac

# Absolute path so the parent walk terminates at "/" (see header).
case "$FILE_PATH" in
  /*) ABS="$FILE_PATH" ;;
  *)  ABS="$PWD/$FILE_PATH" ;;
esac

DIR=$(dirname "$ABS")
CONFIG=""
while : ; do
  if [ -f "$DIR/biome.json" ] || [ -f "$DIR/biome.jsonc" ]; then CONFIG="$DIR"; break; fi
  [ "$DIR" = "/" ] && break
  PARENT=$(dirname "$DIR")
  [ "$PARENT" = "$DIR" ] && break        # belt and braces: never spin
  DIR="$PARENT"
done
[ -n "$CONFIG" ] || exit 0

CAP=""
if command -v timeout >/dev/null 2>&1; then CAP="timeout 10"
elif command -v gtimeout >/dev/null 2>&1; then CAP="gtimeout 10"
fi
$CAP npx biome format --write "$ABS" >/dev/null 2>&1

exit 0
