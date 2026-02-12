#!/bin/bash
# quality-gate.sh -- Run a quality gate and produce a verifiable receipt
# Usage: bash quality-gate.sh <gate-name> <command...>
# Example: bash quality-gate.sh type-check npm run type-check
#
# Writes receipt to .issue/receipts/<gate-name>.json
# Outputs the original command output so agents see results
# Exits with original exit code

set -uo pipefail

GATE_NAME="${1:-}"
shift || true
COMMAND="$*"

if [ -z "$GATE_NAME" ] || [ -z "$COMMAND" ]; then
  echo "Usage: bash quality-gate.sh <gate-name> <command...>" >&2
  echo "Example: bash quality-gate.sh type-check npm run type-check" >&2
  exit 1
fi

WORKTREE_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$WORKTREE_ROOT" ]; then
  echo "ERROR: Cannot determine git root. Are you in a worktree?" >&2
  exit 1
fi

RECEIPT_DIR="$WORKTREE_ROOT/.issue/receipts"
mkdir -p "$RECEIPT_DIR"

# Capture output and exit code
START_TS=$(date +%s)
OUTPUT=$(eval "$COMMAND" 2>&1)
EXIT_CODE=$?
END_TS=$(date +%s)
DURATION_MS=$(( (END_TS - START_TS) * 1000 ))

# Compute hash of output
OUTPUT_HASH="sha256:$(echo "$OUTPUT" | shasum -a 256 | cut -d' ' -f1)"

# Determine status
if [ "$EXIT_CODE" -eq 0 ]; then
  STATUS="pass"
else
  STATUS="fail"
fi

# Get summary (last 5 lines, max 200 chars)
SUMMARY=$(echo "$OUTPUT" | tail -5 | head -c 200)

# Get git SHA
GIT_SHA=$(git rev-parse HEAD 2>/dev/null || echo "unknown")

# Get agent name from environment (set by Claude Code agent framework)
AGENT_NAME="${CLAUDE_AGENT_NAME:-unknown}"

# Write receipt using jq
jq -n \
  --arg gate "$GATE_NAME" \
  --arg status "$STATUS" \
  --argjson timestamp "$END_TS" \
  --arg agent "$AGENT_NAME" \
  --arg command "$COMMAND" \
  --arg output_hash "$OUTPUT_HASH" \
  --arg output_summary "$SUMMARY" \
  --argjson exit_code "$EXIT_CODE" \
  --arg git_sha "$GIT_SHA" \
  --argjson duration_ms "$DURATION_MS" \
  '{
    gate: $gate,
    status: $status,
    timestamp: $timestamp,
    agent: $agent,
    command: $command,
    output_hash: $output_hash,
    output_summary: $output_summary,
    exit_code: $exit_code,
    git_sha: $git_sha,
    duration_ms: $duration_ms
  }' > "$RECEIPT_DIR/$GATE_NAME.json"

# Output the original command output for the agent to see
echo "$OUTPUT"

# Exit with original exit code
exit $EXIT_CODE
