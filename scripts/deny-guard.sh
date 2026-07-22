#!/usr/bin/env bash
# deny-guard.sh — PreToolUse(Bash) hard deny for catastrophic, irreversible commands.
#
# Emits the ONLY schema PreToolUse honours:
#   {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#     "permissionDecision":"deny","permissionDecisionReason":"..."}}
# printed on exit 0. Because it is a `deny` decision it fires even under
# `bypassPermissions` / `--dangerously-skip-permissions` / defaultMode "dontAsk"
# (precedence: deny > ask > allow, and deny is honoured in every permission mode).
#
# DESIGN: block only the handful of operations that are irreversible AND
# blast-radius-wide. Targeted deletes, resets of a single file, normal git and
# shell work all pass through with NO prompt — this is a floor, not a nag.
#
# The hook NEVER errors out in a way that blocks work: any parse failure => exit 0
# (fail-open on parsing, fail-closed only on a confirmed catastrophic match).
set -uo pipefail

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$cmd" ] && exit 0

deny() {
  jq -cn --arg r "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# Normalise: collapse all whitespace to single spaces and pad with a leading /
# trailing space so token boundaries (" word ") match at the ends too.
c=" $(printf '%s' "$cmd" | tr '\n\t' '  ' | tr -s ' ') "

# ---------------------------------------------------------------------------
# 1. Recursive rm of a root / home / cwd / parent / system directory.
#    Only inspect `rm` invocations whose flag cluster contains r or R.
# ---------------------------------------------------------------------------
if printf '%s' "$c" | grep -qE '(^| |;|&|\|)rm +(-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)( |$|-)'; then
  # filesystem root, root-glob, home shorthand, cwd, parent — as a whole target token
  if printf '%s' "$c" | grep -qE ' (-[a-zA-Z]+ )*(/|/\*|~|~/|\.|\./|\.\.|\.\./|\$HOME|\$HOME/|\*)( |;|&|\||\)|$)'; then
    deny "Blocked recursive delete of a root/home/current/parent/glob path. Name a specific subpath (e.g. rm -rf ./build) and re-run."
  fi
  # true system roots (NOT /Users — home lives under it and targeted deletes are fine)
  if printf '%s' "$c" | grep -qE ' (/System|/Applications|/Library|/etc|/usr|/bin|/sbin|/opt|/var|/private|/boot|/dev|/proc)( |/|;|&|\||\)|$)'; then
    deny "Blocked recursive delete of a system directory. This is irreversible; do it manually outside the agent if truly intended."
  fi
  # the home directory itself, spelled out (subpaths under it are allowed)
  case "$c" in
    *" $HOME "*|*" $HOME/ "*|*" $HOME;"*|*" $HOME/;"*) deny "Blocked recursive delete of your home directory." ;;
  esac
fi

# ---------------------------------------------------------------------------
# 2. Other irreversible / destructive operations.
# ---------------------------------------------------------------------------
case "$c" in
  # history / working-tree destruction
  *" git reset --hard"*)
    deny "git reset --hard is blocked — it discards uncommitted work irreversibly. Stash or commit first." ;;
  *" git clean -"*f*|*" git clean --force"*)
    deny "git clean -f is blocked — it permanently deletes untracked files. Remove specific paths instead." ;;
  *" git checkout -- ."*|*" git checkout -- :/"*|*" git restore ."*)
    deny "Blanket checkout/restore of the whole tree is blocked — it discards all local edits. Target specific files." ;;
  # force push (any form) — protected-branch history rewrite
  *" git push --force"*|*" git push -"*f*|*"--force-with-lease"*)
    deny "Force-push is blocked — protected branches use PRs. If a history fix is truly needed, do it manually." ;;
  *" git branch -D "*|*" git branch --delete --force"*)
    : ;; # deleting a local branch is recoverable via reflog — allowed
esac

# Destructive SQL / database drops embedded in a command.
if printf '%s' "$c" | grep -qiE '(drop +(database|schema)|truncate +table|drop +table +[^ ]|delete +from +[^ ]+ *(;|$))'; then
  # Allow `DROP TABLE IF EXISTS` inside a migration file being written elsewhere;
  # this only fires on a command actually EXECUTING the statement (psql/mysql -c, etc.)
  if printf '%s' "$c" | grep -qiE '(psql|mysql|mariadb|sqlite3|mongosh|clickhouse-client|cockroach)'; then
    deny "Blocked an ad-hoc destructive DB statement (DROP/TRUNCATE/unfiltered DELETE). Route schema changes through a reviewed migration."
  fi
fi

# Remote-code execution: piping a downloaded script straight into a shell.
if printf '%s' "$c" | grep -qE '(curl|wget|fetch)[^|]*\| *(sudo +)?(ba)?sh( |$|-)'; then
  deny "Blocked 'curl|sh' style remote-code execution. Download, inspect, then run the script deliberately."
fi

# World-writable recursive chmod / chown of a broad tree.
if printf '%s' "$c" | grep -qE ' chmod +-[a-zA-Z]*R[a-zA-Z]* +(777|a\+rwx|0777)'; then
  deny "Blocked recursive chmod 777 — it removes all access control. Set the minimum permissions on a specific path."
fi

# Overwriting a whole block device or the disk.
if printf '%s' "$c" | grep -qE ' (dd +[^&|;]*of=/dev/|mkfs\.|> */dev/sd[a-z]|> */dev/disk)'; then
  deny "Blocked a raw block-device write (dd/mkfs to /dev/*). This destroys disks; never run it from an agent."
fi

# fork bomb
case "$c" in *":(){ :|:& };:"*|*":()"*"{"*":|:"*) deny "Blocked a fork-bomb pattern." ;; esac

exit 0
