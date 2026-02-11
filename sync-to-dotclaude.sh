#!/bin/bash
set -euo pipefail

# Sync quetrex-base → ~/.claude/
# Run from the quetrex-base directory or anywhere (auto-detects repo root)

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
DOTCLAUDE="$HOME/.claude"

echo "Syncing quetrex-base → ~/.claude/"
echo "Source: $REPO_ROOT"
echo "Target: $DOTCLAUDE"
echo ""

# Ensure target directories exist
mkdir -p "$DOTCLAUDE"/{agents,hooks,commands,skills,docs,prompts}

# Core config files
for f in CLAUDE.md HARD-RULES.md team-protocol.md pipeline-protocol.md settings.json statusline-command.sh; do
  if [ -f "$REPO_ROOT/$f" ]; then
    cp "$REPO_ROOT/$f" "$DOTCLAUDE/$f"
    echo "  copied $f"
  fi
done

# Agents
for f in "$REPO_ROOT"/agents/*.md; do
  [ -f "$f" ] && cp "$f" "$DOTCLAUDE/agents/" && echo "  copied agents/$(basename "$f")"
done

# Hooks
for f in "$REPO_ROOT"/hooks/*.sh; do
  [ -f "$f" ] && cp "$f" "$DOTCLAUDE/hooks/" && echo "  copied hooks/$(basename "$f")"
done

# Commands
for f in "$REPO_ROOT"/commands/*.md; do
  [ -f "$f" ] && cp "$f" "$DOTCLAUDE/commands/" && echo "  copied commands/$(basename "$f")"
done

# Skills (recursive — each skill is a directory)
if [ -d "$REPO_ROOT/skills" ]; then
  for skill_dir in "$REPO_ROOT"/skills/*/; do
    skill_name="$(basename "$skill_dir")"
    mkdir -p "$DOTCLAUDE/skills/$skill_name"
    cp -R "$skill_dir"* "$DOTCLAUDE/skills/$skill_name/" 2>/dev/null || true
    echo "  copied skills/$skill_name/"
  done
fi

# Docs
if [ -d "$REPO_ROOT/docs" ]; then
  cp "$REPO_ROOT"/docs/*.md "$DOTCLAUDE/docs/" 2>/dev/null && echo "  copied docs/" || true
fi

# Prompts
if [ -d "$REPO_ROOT/prompts" ]; then
  cp "$REPO_ROOT"/prompts/*.md "$DOTCLAUDE/prompts/" 2>/dev/null && echo "  copied prompts/" || true
fi

echo ""
echo "Sync complete. ~/.claude/ is up to date with quetrex-base."
