#!/bin/bash
# sync-to-claude.sh -- One-way sync from quetrex-base to ~/.claude
# Usage: ./scripts/sync-to-claude.sh [--dry-run] [--force]
#
# Copies managed files from this repo to the running ~/.claude directory.
# Creates timestamped backups before overwriting changed files.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_DIR="$HOME/.claude"
BACKUP_DIR="$TARGET_DIR/.sync-backups/$(date +%Y%m%d-%H%M%S)"
DRY_RUN=false
FORCE=false
CHANGED=0
SKIPPED=0
SYNCED=0

# Parse arguments
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --force) FORCE=true ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

# Files managed by quetrex-base (relative to repo root)
# Add new files here as they are added to the repo
MANAGED_FILES=(
  "CLAUDE.md"
  "HARD-RULES.md"
  "hooks/config-guard.sh"
  "hooks/test-guard.sh"
  "hooks/require-approval.sh"
  "hooks/enforce-branch.sh"
  "hooks/track-modifications.sh"
  "hooks/quality-gate.sh"
  "hooks/pre-pr-gate.sh"
  "settings.json"
  "statusline-command.sh"
  "team-protocol.md"
  "pipeline-protocol.md"
  "commands/add-project.md"
  "commands/create-issue.md"
  "commands/deploy-production.md"
  "skills/agent-surveillance/SKILL.md"
  "skills/agent-surveillance/package.json"
  "skills/agent-surveillance/scripts/server.js"
)

echo "=== quetrex-base sync ==="
echo "Source: $REPO_DIR"
echo "Target: $TARGET_DIR"
if $DRY_RUN; then echo "Mode: DRY RUN (no changes)"; fi
if $FORCE; then echo "Mode: FORCE (overwrite without prompting)"; fi
echo ""

for file in "${MANAGED_FILES[@]}"; do
  src="$REPO_DIR/$file"
  dst="$TARGET_DIR/$file"

  # Skip files that don't exist in repo
  if [ ! -f "$src" ]; then
    echo "  SKIP (not in repo): $file"
    ((SKIPPED++))
    continue
  fi

  # New file -- just copy
  if [ ! -f "$dst" ]; then
    echo "  NEW: $file"
    if ! $DRY_RUN; then
      mkdir -p "$(dirname "$dst")"
      cp "$src" "$dst"
    fi
    ((SYNCED++))
    continue
  fi

  # Compare
  if diff -q "$src" "$dst" > /dev/null 2>&1; then
    echo "  OK (identical): $file"
    continue
  fi

  # Files differ
  ((CHANGED++))
  echo "  CHANGED: $file"

  if $DRY_RUN; then
    echo "    Would backup and overwrite"
    diff --unified=3 "$dst" "$src" | head -20 || true
    echo ""
    continue
  fi

  # Backup the running version
  mkdir -p "$BACKUP_DIR/$(dirname "$file")"
  cp "$dst" "$BACKUP_DIR/$file"
  echo "    Backed up to: $BACKUP_DIR/$file"

  if $FORCE; then
    cp "$src" "$dst"
    echo "    Overwritten (force mode)"
    ((SYNCED++))
  else
    # Show diff and prompt
    echo "    Diff (running -> repo):"
    diff --unified=3 "$dst" "$src" | head -30 || true
    echo ""
    read -rp "    Overwrite $file with repo version? [y/N] " answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
      cp "$src" "$dst"
      echo "    Overwritten"
      ((SYNCED++))
    else
      echo "    Skipped"
      ((SKIPPED++))
    fi
  fi
done

echo ""
echo "=== Summary ==="
echo "  Synced: $SYNCED"
echo "  Changed (needs review): $CHANGED"
echo "  Skipped: $SKIPPED"

# Check for untracked files in ~/.claude that should be in repo
echo ""
echo "=== Untracked Files Check ==="
for cmd_file in "$TARGET_DIR"/commands/*.md; do
  [ -f "$cmd_file" ] || continue
  basename_file=$(basename "$cmd_file")
  if [ ! -f "$REPO_DIR/commands/$basename_file" ]; then
    echo "  UNTRACKED: commands/$basename_file (exists in ~/.claude but not in repo)"
  fi
done

if [ $CHANGED -gt 0 ] && ! $FORCE && ! $DRY_RUN; then
  echo ""
  echo "Backups saved to: $BACKUP_DIR"
fi
