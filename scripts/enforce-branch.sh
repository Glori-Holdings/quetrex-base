#!/usr/bin/env bash
# enforce-branch.sh — PreToolUse(Bash): never commit/push while ON main/master.
#
# Work belongs on a feature branch or in a worktree. This hook forces an
# interactive confirmation ("ask") — it does NOT hard-deny — so a human can
# still deliberately bootstrap or override, but the agent can never silently
# commit onto the protected branch on its own initiative.
#   (ask wins over an allowlist "allow"; precedence deny > ask > allow.)
#
# BUG FIXES over the legacy hook (both were real false-positive sources):
#   1. Match the ACTUAL command being run, not the literal substring
#      "git commit" appearing inside echoed docs / heredocs / strings.
#      We strip quoted segments before testing, so `echo "run git commit"`
#      no longer trips the guard.
#   2. Allow the FIRST commit on a freshly-created repo/branch (no HEAD yet) —
#      you cannot make a feature branch before the initial commit exists.
#
# Worktree-aware: the branch is resolved for the directory the command actually
# runs in (`git -C <dir> ...`, `cd <dir> &&`, else the session cwd), so a commit
# inside a feature worktree is correctly seen as being on the feature branch.
set -uo pipefail

input=$(cat)
COMMAND=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$COMMAND" ] && exit 0

# --- Strip quoted segments so echoed/documented "git commit" text is ignored.
STRIPPED=$(printf '%s' "$COMMAND" | sed "s/'[^']*'//g; s/\"[^\"]*\"//g")

# --- Is this REALLY a git commit or git push invocation (bare or `git -C dir`)?
GIT_PFX='git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+'
IS_COMMIT=0; IS_PUSH=0
[[ "$STRIPPED" =~ ${GIT_PFX}commit ]] && IS_COMMIT=1
[[ "$STRIPPED" =~ ${GIT_PFX}push ]] && IS_PUSH=1
[ "$IS_COMMIT" -eq 0 ] && [ "$IS_PUSH" -eq 0 ] && exit 0

# --- Tag pushes (deploy/version rollback tags) are exempt.
if [ "$IS_PUSH" -eq 1 ]; then
  if [[ "$STRIPPED" == *"git tag"* ]] || \
     [[ "$STRIPPED" == *"refs/tags/"* ]] || \
     [[ "$STRIPPED" =~ push[[:space:]]+(origin[[:space:]]+)?deploy/ ]] || \
     [[ "$STRIPPED" =~ push[[:space:]]+(origin[[:space:]]+)?v[0-9] ]]; then
    exit 0
  fi
fi

# --- Resolve the working directory the git command targets.
SESSION_CWD=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
TARGET_DIR=""
gitc_re='git[[:space:]]+-C[[:space:]]+([^[:space:]]+)'
cd_re='cd[[:space:]]+([^&;]+)[[:space:]]*&&'
if [[ "$STRIPPED" =~ $gitc_re ]]; then
  TARGET_DIR="${BASH_REMATCH[1]}"
elif [[ "$STRIPPED" =~ $cd_re ]]; then
  TARGET_DIR=$(printf '%s' "${BASH_REMATCH[1]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
fi

DIR=""
if [ -n "$TARGET_DIR" ] && [ -d "$TARGET_DIR" ]; then
  DIR="$TARGET_DIR"
elif [ -n "$SESSION_CWD" ] && [ -d "$SESSION_CWD" ]; then
  DIR="$SESSION_CWD"
fi

if [ -n "$DIR" ]; then
  CURRENT_BRANCH=$(git -C "$DIR" branch --show-current 2>/dev/null)
  HAS_HEAD=$(git -C "$DIR" rev-parse --verify -q HEAD 2>/dev/null)
else
  CURRENT_BRANCH=$(git branch --show-current 2>/dev/null)
  HAS_HEAD=$(git rev-parse --verify -q HEAD 2>/dev/null)
fi

# Could not determine the branch (not a git repo / detached HEAD) → fail open.
[ -z "$CURRENT_BRANCH" ] && exit 0

# Only gate the protected branches.
if [ "$CURRENT_BRANCH" != "main" ] && [ "$CURRENT_BRANCH" != "master" ]; then
  exit 0
fi

# First commit on a brand-new repo (no HEAD yet): allow bootstrapping.
if [ "$IS_COMMIT" -eq 1 ] && [ -z "$HAS_HEAD" ]; then
  exit 0
fi

VERB="commit"; [ "$IS_PUSH" -eq 1 ] && VERB="push"
jq -cn --arg b "$CURRENT_BRANCH" --arg v "$VERB" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",
    permissionDecisionReason:("You are about to " + $v + " while on branch \"" + $b + "\". Work belongs on a feature branch/worktree — use `git -C <worktree>` so the branch is detected. Approve only if this is an intentional, authorized action on " + $b + ".")}}'
exit 0
