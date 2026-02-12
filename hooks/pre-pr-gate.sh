#!/bin/bash
# Block `gh pr create` unless all quality gates have verifiable receipts
# Runs on PreToolUse hook for Bash
# Always outputs valid JSON and exits 0

input=$(cat)
COMMAND=$(echo "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  echo '{"decision": "undefined"}'
  exit 0
fi

# Only intercept PR creation commands
if [[ "$COMMAND" != *"gh pr create"* ]]; then
  echo '{"decision": "undefined"}'
  exit 0
fi

# Find the worktree root (where .issue/ lives)
WORKTREE_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$WORKTREE_ROOT" ]; then
  # Not in a git repo — nothing to protect, let the command through
  echo '{"decision": "undefined"}'
  exit 0
fi

RECEIPT_DIR="$WORKTREE_ROOT/.issue/receipts"

# --- Required receipts ---
MISSING=""

# 1. Type check receipt
if [ ! -f "$RECEIPT_DIR/type-check.json" ]; then
  MISSING="$MISSING type-check"
else
  STATUS=$(jq -r '.status // "unknown"' "$RECEIPT_DIR/type-check.json" 2>/dev/null)
  if [ "$STATUS" != "pass" ]; then
    MISSING="$MISSING type-check(status=$STATUS)"
  fi
  # Check freshness: receipt must be newer than most recent code change
  RECEIPT_TS=$(jq -r '.timestamp // 0' "$RECEIPT_DIR/type-check.json" 2>/dev/null)
  LATEST_FILE=$(git diff --name-only HEAD 2>/dev/null | head -1)
  if [ -n "$LATEST_FILE" ] && [ -f "$LATEST_FILE" ]; then
    LATEST_EDIT=$(stat -f %m "$LATEST_FILE" 2>/dev/null || echo "0")
    if [ "$RECEIPT_TS" -lt "$LATEST_EDIT" ] 2>/dev/null; then
      MISSING="$MISSING type-check(stale)"
    fi
  fi
fi

# 2. Lint receipt
if [ ! -f "$RECEIPT_DIR/lint.json" ]; then
  MISSING="$MISSING lint"
else
  STATUS=$(jq -r '.status // "unknown"' "$RECEIPT_DIR/lint.json" 2>/dev/null)
  if [ "$STATUS" != "pass" ]; then
    MISSING="$MISSING lint(status=$STATUS)"
  fi
fi

# 3. Test receipt
if [ ! -f "$RECEIPT_DIR/test.json" ]; then
  MISSING="$MISSING test"
else
  STATUS=$(jq -r '.status // "unknown"' "$RECEIPT_DIR/test.json" 2>/dev/null)
  if [ "$STATUS" != "pass" ]; then
    MISSING="$MISSING test(status=$STATUS)"
  fi
fi

# 4. Reviewer receipt
if [ ! -f "$RECEIPT_DIR/reviewer.json" ]; then
  MISSING="$MISSING reviewer-approval"
else
  VERDICT=$(jq -r '.verdict // "unknown"' "$RECEIPT_DIR/reviewer.json" 2>/dev/null)
  if [ "$VERDICT" != "APPROVED" ]; then
    MISSING="$MISSING reviewer(verdict=$VERDICT)"
  fi
fi

# 5. Smoke test receipt (if .issue/smoke-test-required marker exists)
if [ -f "$WORKTREE_ROOT/.issue/smoke-test-required" ]; then
  if [ ! -f "$RECEIPT_DIR/smoke-test.json" ]; then
    MISSING="$MISSING smoke-test"
  else
    STATUS=$(jq -r '.status // "unknown"' "$RECEIPT_DIR/smoke-test.json" 2>/dev/null)
    if [ "$STATUS" != "pass" ]; then
      MISSING="$MISSING smoke-test(status=$STATUS)"
    fi
  fi
fi

# 6. Domain validation receipt (if domain checklist was assigned)
if [ -f "$RECEIPT_DIR/domain-validation-required.json" ]; then
  DOMAINS=$(jq -r '.domains[]' "$RECEIPT_DIR/domain-validation-required.json" 2>/dev/null)
  for DOMAIN in $DOMAINS; do
    if [ ! -f "$RECEIPT_DIR/domain-$DOMAIN.json" ]; then
      MISSING="$MISSING domain-$DOMAIN"
    else
      STATUS=$(jq -r '.status // "unknown"' "$RECEIPT_DIR/domain-$DOMAIN.json" 2>/dev/null)
      if [ "$STATUS" != "pass" ]; then
        MISSING="$MISSING domain-$DOMAIN(status=$STATUS)"
      fi
    fi
  done
fi

if [ -n "$MISSING" ]; then
  echo "{\"decision\": \"block\", \"reason\": \"PR BLOCKED: Missing or failing quality gate receipts:$MISSING. Run all gates and produce receipts before creating PR.\"}"
  exit 0
fi

# All gates verified
echo '{"decision": "undefined"}'
exit 0
