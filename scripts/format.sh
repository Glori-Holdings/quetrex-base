#!/usr/bin/env bash
# format.sh — PostToolUse(Write|Edit) format-on-save. CONVENIENCE ONLY.
#
# Runs the project's formatter on the file that was just written/edited.
# It is NON-BLOCKING by contract: it ALWAYS exits 0 and never emits a block
# decision. A missing formatter, a formatter error, or an unformattable file
# must never interrupt the pipeline — this is a nicety, not a quality floor.
# (The quality floor is verify-gate on Stop/SubagentStop.)
#
# Formatter source of truth: .quetrex/verify.json  ->  .format  (a command
# string, e.g. "npx biome format --write" / "ruff format" / "gofmt -w"). The
# changed file path is appended as the final argument. If no verify.json/.format
# is configured, it falls back to autodetecting biome for JS/TS/JSON.
set -uo pipefail

input=$(cat)
FILE_PATH=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$FILE_PATH" ] && exit 0
[ -f "$FILE_PATH" ] || exit 0

# Resolve the repo root FROM THE FILE'S directory (worktree-safe).
DIR=$(dirname "$FILE_PATH")
ROOT=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null) || ROOT=""

# 1) Configured formatter from verify.json (preferred, stack-agnostic).
if [ -n "$ROOT" ] && [ -f "$ROOT/.quetrex/verify.json" ]; then
  FMT=$(jq -r '.format // empty' "$ROOT/.quetrex/verify.json" 2>/dev/null)
  if [ -n "$FMT" ]; then
    ( cd "$ROOT" && eval "$FMT \"$FILE_PATH\"" ) >/dev/null 2>&1 || true
    exit 0
  fi
fi

# 2) Fallback: autodetect biome for web files (matches the legacy behaviour).
case "$FILE_PATH" in
  *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.json|*.jsonc|*.css)
    d="$DIR"
    while [ "$d" != "/" ] && [ -n "$d" ]; do
      if [ -f "$d/biome.json" ] || [ -f "$d/biome.jsonc" ]; then
        ( cd "$d" && npx biome format --write "$FILE_PATH" ) >/dev/null 2>&1 || true
        exit 0
      fi
      d=$(dirname "$d")
    done
    ;;
esac

exit 0
