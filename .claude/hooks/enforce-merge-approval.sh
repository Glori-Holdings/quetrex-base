#!/usr/bin/env bash
# enforce-merge-approval.sh — PreToolUse hook (Bash matcher).
#
# POLICY: changes reach main/master ONLY via a PR, and NO PR merges
# without the human's explicit approval in the terminal. This hook forces an
# interactive approval prompt ("ask") for every merge / publish-to-master
# command — even when an allowlist or a non-interactive permission mode
# (e.g. defaultMode "dontAsk") would otherwise let it run silently.
#
# A hook cannot read the conversation, so it cannot verify that the human
# actually said "merge this PR". Instead it GUARANTEES the human is prompted
# to confirm every time, so a merge can never happen on the agent's own
# initiative. permissionDecision "ask" wins over an allowlist "allow"
# (precedence: deny > defer > ask > allow).
#
# Gated commands (matched whether invoked bare or via `git -C <dir> ...`):
#   - gh pr merge ...                        (merging a PR)
#   - git push ... targeting master/main     (direct push to the protected branch)
#   - git merge ... while ON master/main     (local merge into the protected branch)
#
# Tag pushes (deploy/version rollback tags) are exempt, matching enforce-branch.sh.
#
# Output: exit 0 + JSON with permissionDecision "ask". No JSON => normal flow.

input=$(cat)
COMMAND=$(echo "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$COMMAND" ] && exit 0

ask() {
  jq -cn --arg r "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
  exit 0
}

# A git subcommand, invoked either bare (`git push`) or with a leading
# `-C <dir>` (`git -C /worktree push`) — the form this repo's workflow uses.
GIT_PFX='git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+'

# ---- 1. gh pr merge -------------------------------------------------------
if [[ "$COMMAND" == *"gh pr merge"* ]]; then
  ask "MERGE GATE: merging a PR requires your explicit approval. Approve only if you told me to merge this PR."
fi

# Tag pushes are exempt (deploy/version rollback tags), matching enforce-branch.sh.
is_tag_push() {
  [[ "$COMMAND" == *"git tag"* ]] || \
  [[ "$COMMAND" == *"refs/tags/"* ]] || \
  [[ "$COMMAND" =~ push[[:space:]]+(origin[[:space:]]+)?deploy/ ]] || \
  [[ "$COMMAND" =~ push[[:space:]]+(origin[[:space:]]+)?v[0-9] ]]
}

# ---- 2. git push targeting master/main ------------------------------------
# Covers `git push origin master`, `git push origin HEAD:master`, `:main`, etc.
# — including pushing to master FROM a feature branch, which enforce-branch.sh
# (which only checks the current branch) does not catch.
if [[ "$COMMAND" =~ ${GIT_PFX}push ]] && ! is_tag_push; then
  if [[ "$COMMAND" =~ (^|[[:space:]:/])(master|main)([[:space:]]|$) ]] || \
     [[ "$COMMAND" =~ :(refs/heads/)?(master|main)([[:space:]]|$) ]]; then
    ask "MERGE GATE: pushing directly to master/main must not run silently — changes reach master via a PR. Approve only if this is an intentional, authorized push."
  fi
fi

# ---- 3. git merge while ON master/main ------------------------------------
if [[ "$COMMAND" =~ ${GIT_PFX}merge ]]; then
  SESSION_CWD=$(echo "$input" | jq -r '.cwd // empty' 2>/dev/null)
  TARGET_DIR=""
  if [[ "$COMMAND" =~ cd[[:space:]]+([^\&\;]+)[[:space:]]*\&\& ]]; then
    TARGET_DIR="${BASH_REMATCH[1]}"
    TARGET_DIR=$(echo "$TARGET_DIR" | sed 's/^[ "'\'']*//;s/[ "'\'']*$//')
  elif [[ "$COMMAND" =~ git[[:space:]]+-C[[:space:]]+([^[:space:]]+) ]]; then
    TARGET_DIR="${BASH_REMATCH[1]}"
  fi
  if [ -n "$TARGET_DIR" ] && [ -d "$TARGET_DIR" ]; then
    BR=$(git -C "$TARGET_DIR" branch --show-current 2>/dev/null)
  elif [ -n "$SESSION_CWD" ] && [ -d "$SESSION_CWD" ]; then
    BR=$(git -C "$SESSION_CWD" branch --show-current 2>/dev/null)
  else
    BR=$(git branch --show-current 2>/dev/null)
  fi
  if [ "$BR" = "master" ] || [ "$BR" = "main" ]; then
    ask "MERGE GATE: a local merge into $BR requires your explicit approval. Prefer a PR; approve only if intentional."
  fi
fi

exit 0
