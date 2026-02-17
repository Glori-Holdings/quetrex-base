#!/bin/bash
# Track code modifications for smart quality gate detection
# Runs AFTER Write/Edit tools via PostToolUse hook

# Read hook input from stdin
input=$(cat)

# Get tool name from input
TOOL_NAME=$(echo "$input" | jq -r '.tool_name // empty' 2>/dev/null)

# Use PPID for consistent session tracking across all hooks
# All hooks in a Claude session share the same parent process
SESSION_MARKER="/tmp/claude-modified-$PPID"

# Track if Write or Edit tools were used
if [[ "$TOOL_NAME" == "Write" ]] || [[ "$TOOL_NAME" == "Edit" ]]; then
  # Mark that code was modified this session
  date +%s > "$SESSION_MARKER"

  # --- Receipt Invalidation ---
  # When code is modified, invalidate quality gate receipts
  # (forces re-verification before PR creation)
  WORKTREE_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
  if [ -n "$WORKTREE_ROOT" ] && [ -d "$WORKTREE_ROOT/.issue/receipts" ]; then
    for RECEIPT in type-check.json lint.json test.json coverage.json smoke-test.json reviewer.json domain-db.json; do
      if [ -f "$WORKTREE_ROOT/.issue/receipts/$RECEIPT" ]; then
        # Mark as stale rather than deleting (preserves history)
        jq '.status = "stale" | .invalidated_at = now | .invalidated_reason = "code_modified"' \
          "$WORKTREE_ROOT/.issue/receipts/$RECEIPT" > "$WORKTREE_ROOT/.issue/receipts/$RECEIPT.tmp" \
          && mv "$WORKTREE_ROOT/.issue/receipts/$RECEIPT.tmp" "$WORKTREE_ROOT/.issue/receipts/$RECEIPT"
      fi
    done
  fi

  # --- Shared File Warning ---
  FILE_PATH_HOOK=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
  if [ -n "$FILE_PATH_HOOK" ] && [ -n "$WORKTREE_ROOT" ]; then
    SHARED_PATTERNS="lib/types|lib/db/schema|lib/shared|lib/utils|components/ui"
    if echo "$FILE_PATH_HOOK" | grep -qE "$SHARED_PATTERNS"; then
      echo "WARNING: Shared file modified: $FILE_PATH_HOOK. Other parts of the app may be affected." >&2
      # Append to shared-file warnings log
      WARNINGS_FILE="$WORKTREE_ROOT/.issue/shared-file-warnings.json"
      if [ ! -f "$WARNINGS_FILE" ]; then
        echo '[]' > "$WARNINGS_FILE"
      fi
      jq --arg file "$FILE_PATH_HOOK" --arg ts "$(date +%s)" \
        '. + [{"file": $file, "modified_at": ($ts | tonumber), "warning": "Shared file modified — run impact analysis"}]' \
        "$WARNINGS_FILE" > "$WARNINGS_FILE.tmp" && mv "$WARNINGS_FILE.tmp" "$WARNINGS_FILE"
    fi
  fi

  # --- Loop Detection ---
  FILE_PATH=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
  if [ -n "$FILE_PATH" ]; then
    EDIT_COUNTS="/tmp/claude-edit-counts-$PPID"
    echo "$FILE_PATH" >> "$EDIT_COUNTS"

    # Count edits to this specific file
    COUNT=$(grep -cF "$FILE_PATH" "$EDIT_COUNTS" 2>/dev/null || echo "0")
    if [ "$COUNT" -ge 5 ]; then
      echo "LOOP DETECTION: $FILE_PATH edited $COUNT times. Stop and reassess approach." >&2
    fi
  fi
fi

# Always allow the tool to complete - this is a PostToolUse hook
exit 0
