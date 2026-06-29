#!/usr/bin/env bash
# workflow-reminder.sh — UserPromptSubmit hook (GLOBAL, all projects).
#
# Injects a standing reminder to prefer the Workflow tool (multi-agent
# orchestration) for substantial work, so the main loop parallelizes and
# conserves its context window instead of grinding through work inline.
#
# A hook can only NUDGE (inject this text); it cannot strictly force a tool
# choice. This reminder + the matching memory/feedback is the reliable lever.
#
# stdout from a UserPromptSubmit hook is added to the model's context.
cat <<'EOF'
[workflow-preference] For substantial multi-file / multi-step build, refactor, audit, migration, or research work, PREFER the Workflow tool (multi-agent orchestration: architect → parallel worktree developers → integrate → QA → reviewer → git-workflow) over doing the work inline or via sequential one-off agents — it parallelizes and conserves the context window. Skip the Workflow tool only for trivial/single-file edits, quick lookups, or conversational replies.
EOF
