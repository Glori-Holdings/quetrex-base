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

check_receipt() {
  local receipt_file="$1"
  local receipt_name="$2"
  local check_field="${3:-status}"
  local pass_value="${4:-pass}"

  if [ ! -f "$receipt_file" ]; then
    MISSING="$MISSING $receipt_name"
    return
  fi

  local field_val
  field_val=$(jq -r ".${check_field} // \"unknown\"" "$receipt_file" 2>/dev/null)
  if [ "$field_val" != "$pass_value" ]; then
    MISSING="$MISSING ${receipt_name}(${check_field}=${field_val})"
    return
  fi

  # SHA-based freshness: receipt git_sha must match current HEAD
  local receipt_sha
  receipt_sha=$(jq -r '.git_sha // empty' "$receipt_file" 2>/dev/null)
  if [ -n "$receipt_sha" ]; then
    local current_sha
    current_sha=$(git rev-parse HEAD 2>/dev/null)
    if [ "$receipt_sha" != "$current_sha" ]; then
      MISSING="$MISSING ${receipt_name}(stale:sha_mismatch)"
    fi
  fi
}

# 1. Type check
check_receipt "$RECEIPT_DIR/type-check.json" "type-check"

# 2. Lint
check_receipt "$RECEIPT_DIR/lint.json" "lint"

# 3. Test
check_receipt "$RECEIPT_DIR/test.json" "test"

# 4. Reviewer
check_receipt "$RECEIPT_DIR/reviewer.json" "reviewer-approval" "verdict" "APPROVED"

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

# 7. Auto-detect schema changes requiring domain-db receipt
if [ -n "$WORKTREE_ROOT" ]; then
  SCHEMA_CHANGED=$(git -C "$WORKTREE_ROOT" diff --name-only main...HEAD 2>/dev/null | grep -E '(lib/db/schema|drizzle/|prisma/)' || true)
  if [ -n "$SCHEMA_CHANGED" ]; then
    check_receipt "$RECEIPT_DIR/domain-db.json" "domain-db"
  fi
fi

# 8. Secrets scanning in changed files
if [ -n "$WORKTREE_ROOT" ]; then
  CHANGED_FILES=$(git -C "$WORKTREE_ROOT" diff --name-only main...HEAD 2>/dev/null || true)
  if [ -n "$CHANGED_FILES" ]; then
    SECRETS_FOUND=""
    while IFS= read -r file; do
      filepath="$WORKTREE_ROOT/$file"
      [ -f "$filepath" ] || continue
      # Check for common secret patterns
      if grep -qEi '(AKIA[0-9A-Z]{16}|-----BEGIN (RSA |EC |DSA )?PRIVATE KEY|sk_live_[0-9a-zA-Z]{24,}|ghp_[0-9a-zA-Z]{36}|xox[bpoas]-[0-9a-zA-Z-]+)' "$filepath" 2>/dev/null; then
        SECRETS_FOUND="$SECRETS_FOUND $file"
      fi
    done <<< "$CHANGED_FILES"
    if [ -n "$SECRETS_FOUND" ]; then
      MISSING="$MISSING secrets-detected(files:$SECRETS_FOUND)"
    fi
  fi
fi

# 9. Team protocol validation (when team artifacts exist)
if [ -n "$WORKTREE_ROOT" ] && [ -d "$WORKTREE_ROOT/.issue" ]; then
  # Check if this was a team session (team config exists)
  if ls "$WORKTREE_ROOT/.issue"/team-*.json >/dev/null 2>&1; then
    # Team sessions require reviewer receipt
    check_receipt "$RECEIPT_DIR/reviewer.json" "team-reviewer" "verdict" "APPROVED"
  fi
fi

if [ -n "$MISSING" ]; then
  echo "{\"decision\": \"block\", \"reason\": \"PR BLOCKED: Missing or failing quality gate receipts:$MISSING. Run all gates and produce receipts before creating PR.\"}"
  exit 0
fi

# All gates verified
echo '{"decision": "undefined"}'
exit 0
