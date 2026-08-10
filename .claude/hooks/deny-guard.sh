#!/bin/bash
# deny-guard.sh — blocks ONLY catastrophic, irreversible commands.
# PreToolUse (Bash matcher).
#
# HOOK CONTRACT (course L5): a PreToolUse hook blocks by printing
#   {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#     "permissionDecision":"deny","permissionDecisionReason":"..."}}
# on stdout and exiting 0. A deny is evaluated BENEATH the permission engine,
# so it fires even under defaultMode "dontAsk", bypassPermissions and
# --dangerously-skip-permissions. Exit 2 = blocking error with stderr handed
# back to the agent. Exit 1 does NOT block. Anything but 0 or 2 is non-blocking.
#
# FAIL-CLOSED INPUT HANDLING (finding #9). The old form was
#   cmd=$(jq -r ... 2>/dev/null); [ -z "$cmd" ] && exit 0
# so a missing or erroring jq silently disabled the gate with no trace. Now:
#   - jq is preferred, with the jq-free `sed` extraction merge-gate.sh uses
#     as the fallback, and
#   - input that carries a command but cannot be parsed exits 2 with a message
#     on stderr — it is never treated as "nothing to inspect".
#   - deny() also emits well-formed JSON without jq, so the DENY path itself
#     cannot fail open on a missing dependency.
#
# TOKEN MATCHING, NOT SUBSTRING MATCHING (finding #15). The old matcher looked
# for `reset --hard` / `push --force` / `git commit` anywhere in an arbitrary
# shell string, which denied real, safe commands:
#   grep -rn "git reset --hard" docs/      (the phrase is the SEARCH PATTERN)
#   git push --force-with-lease origin/x   (the SAFE form, the standard remedy)
# This script now splits the command into pipeline segments (quote-aware, so a
# separator inside a quoted literal does not split, and quoted text is never
# read as a command) and inspects the FIRST TOKEN of each segment — the same
# shape the `rm` rule already used. Text that merely MENTIONS a dangerous
# command is not a dangerous command.
#
# Escape hatch that is NOT weakened: if a segment pipes into a bare shell
# (`... | bash`), the segment's literal text really is about to be executed, so
# the legacy whole-string substring scan is applied as a backstop.

set -o pipefail

# --- read hook input -------------------------------------------------------
input=""
if [ ! -t 0 ]; then input=$(cat); fi
[ -z "$input" ] && exit 0

JQ_OK=0
if command -v jq >/dev/null 2>&1 && printf '%s' "$input" | jq . >/dev/null 2>&1; then
  JQ_OK=1
fi

TOOL_NAME=""
cmd=""
if [ "$JQ_OK" -eq 1 ]; then
  TOOL_NAME=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)
  cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
  # jq parsed the payload: an absent/empty command genuinely means there is no
  # shell command to inspect.
  [ -n "$TOOL_NAME" ] && [ "$TOOL_NAME" != "Bash" ] && exit 0
  [ -z "$cmd" ] && exit 0
else
  # jq missing or the payload is not valid JSON. Best-effort jq-free extraction
  # (same shape as merge-gate.sh:70-75), then FAIL CLOSED if that finds nothing
  # while the payload plainly carries a command.
  cmd=$(printf '%s' "$input" | tr -d '\n' | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p')
  if [ -z "$cmd" ]; then
    if printf '%s' "$input" | grep -q '"command"'; then
      echo "deny-guard: could not parse this tool call (jq unavailable or malformed hook JSON), so the catastrophic-command guard cannot evaluate it. Refusing to run it unchecked. Install jq, then retry." >&2
      exit 2
    fi
    exit 0
  fi
fi

# --- deny (fail-closed even without jq) ------------------------------------
deny() {
  reason="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg r "$reason" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  else
    esc=$(printf '%s' "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$esc"
  fi
  exit 0
}

# --- quote-aware segmentation ----------------------------------------------
# Emits one pipeline segment per line. Quote characters are dropped but their
# CONTENTS are preserved verbatim, and separators inside quotes do NOT split —
# so `grep -rn "git reset --hard" docs/` is one segment whose first token is
# `grep`, while `rm -rf "/"` still presents `/` as an argument.
split_segments() {
  s="$1"; out=""; inq=""; i=0; n=${#s}
  while [ "$i" -lt "$n" ]; do
    ch="${s:$i:1}"
    if [ -n "$inq" ]; then
      if [ "$ch" = "$inq" ]; then inq=""; else out="$out$ch"; fi
    else
      case "$ch" in
        "'"|'"') inq="$ch" ;;
        ';'|'&'|'|'|'('|')'|'{'|'}'|'`') out="$out
" ;;
        *) out="$out$ch" ;;
      esac
    fi
    i=$((i + 1))
  done
  printf '%s\n' "$out"
}

PIPE_TO_SHELL=0

# --- rm ---------------------------------------------------------------------
check_rm() {
  shift                      # drop 'rm'
  recursive=0
  paths=""
  for a in "$@"; do
    case "$a" in
      --recursive|--recursive=*|-R|-r) recursive=1 ;;
      --*) : ;;
      -*) case "$a" in *[rR]*) recursive=1 ;; esac ;;
      *) paths="$paths
$a" ;;
    esac
  done
  [ "$recursive" -eq 1 ] || return 0
  printf '%s\n' "$paths" | while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in
      '/'|'/*'|'~'|'~/'|'~/*'|'.'|'./'|'./*'|'..'|'../'|'../*'|'$HOME'|'$HOME/'|'$HOME/*')
        echo "ROOTHOME" ;;
      /System|/System/*|/Applications|/Applications/*|/Library|/Library/*|/etc|/etc/*|/usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/opt|/opt/*)
        echo "SYSTEM" ;;
      *)
        if [ -n "$HOME" ]; then
          case "$p" in
            "$HOME"|"$HOME/"|"$HOME/*") echo "ROOTHOME" ;;
          esac
        fi
        ;;
    esac
  done > "$VERDICT_TMP"
  if grep -q ROOTHOME "$VERDICT_TMP" 2>/dev/null; then
    deny "Refusing recursive delete of a root/home/current/parent path — name a specific subpath instead."
  fi
  if grep -q SYSTEM "$VERDICT_TMP" 2>/dev/null; then
    deny "Refusing recursive delete of a system directory."
  fi
  return 0
}

# --- git --------------------------------------------------------------------
# A ref this pipeline CREATES AND REPLACES by construction, so removing it is
# routine rather than catastrophic:
#   quetrex-spec/*  one dispatch's plan JSON, republished on every dispatch
#   *-gates         one run's gate evidence, republished on every run
# Everything else — main, a unit branch, anything the guard cannot resolve —
# is protected. NOTE the deliberate asymmetry with $VARIABLES: a PreToolUse
# hook is handed the command text BEFORE the shell expands it, so `--delete
# "$SPEC_BRANCH"` is indistinguishable from `--delete "$BASE_BRANCH"` and is
# therefore NOT disposable. Shipped engine commands spell their namespace out
# at the call site (`quetrex-spec/$TASK_ID`, `$BRANCH_PREFIX$TASK-gates`)
# precisely so this rule can see them; test/deny-guard-push-delete.test.sh
# feeds those real lines to this real hook to keep that true.
disposable_ref() {
  r="${1#+}"                  # a leading + (force refspec) is not part of the name
  r="${r#:}"                  # the empty-source delete form, `:<ref>`
  r="${r#refs/heads/}"
  case "$r" in
    quetrex-spec/*|*-gates) return 0 ;;
  esac
  return 1
}

check_git() {
  shift                      # drop 'git'
  # skip git's own global options so `git -C /worktree push --force` is seen
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -C|-c|--git-dir|--work-tree|--namespace|--exec-path)
        if [ "$#" -ge 2 ]; then shift 2; else return 0; fi ;;
      -*) shift ;;
      *) break ;;
    esac
  done
  [ "$#" -gt 0 ] || return 0
  sub="$1"; shift
  case "$sub" in
    reset)
      for a in "$@"; do
        [ "$a" = "--hard" ] && deny "git reset --hard is blocked — stash or commit first."
      done
      ;;
    clean)
      for a in "$@"; do
        case "$a" in
          --force|--force=*) deny "git clean -f is blocked (irreversible)." ;;
          --*) : ;;
          -*) case "$a" in *f*) deny "git clean -f is blocked (irreversible)." ;; esac ;;
        esac
      done
      ;;
    push)
      # DELETION IS MORE DESTRUCTIVE THAN FORCE-PUSH, not less. `push --force`
      # MOVES a ref (the old tip survives in reflogs and in every clone that
      # has it); `push --delete` / `push :<ref>` REMOVES it. Denying the first
      # while waving the second through was a hole, and one the engine's own
      # ls-remote -> delete -> push publication idiom teaches by example.
      delete=0
      skip_next=0
      pos_first=""
      pos_seen=0
      pos_rest=""
      for a in "$@"; do
        if [ "$skip_next" -eq 1 ]; then skip_next=0; continue; fi
        case "$a" in
          # --force-with-lease / --force-if-includes are the SAFE forms (they
          # refuse to clobber work the local ref has not seen) and are the
          # standard post-rebase remedy. They are explicitly NOT blocked.
          --force-with-lease|--force-with-lease=*|--force-if-includes) : ;;
          --force) deny "Unconditional force-push is blocked — use --force-with-lease, or a PR + branch protection." ;;
          --delete) delete=1 ;;
          # options that take a SEPARATE value, so the value is never mistaken
          # for a remote or a refspec
          -o|--push-option|--receive-pack|--exec|--repo) skip_next=1 ;;
          --*) : ;;
          -*) case "$a" in
                *f*) deny "Unconditional force-push is blocked — use --force-with-lease, or a PR + branch protection." ;;
              esac
              case "$a" in
                *d*) delete=1 ;;
              esac ;;
          # a redirection (`2>/dev/null`, `>out`, `2>&1`) is not a refspec —
          # git refuses `<` and `>` in a ref name, so this can never hide one
          *'>'*|*'<'*) : ;;
          *) if [ "$pos_seen" -eq 0 ]; then
               pos_seen=1; pos_first="$a"
             else
               pos_rest="$pos_rest $a"
             fi ;;
        esac
      done
      # The empty-source refspec `:<ref>` is a delete that names no flag at all
      # — `git push origin :main` — so it is checked on its own, always.
      for p in $pos_first $pos_rest; do
        case "$p" in
          :*|+:*)
            disposable_ref "$p" || deny "Deleting the remote ref '$p' is blocked. \`git push <remote> :<ref>\` is a ref DELETION — strictly less recoverable than the force-push this guard already denies. Only the pipeline's disposable namespaces may be deleted: quetrex-spec/* and *-gates." ;;
        esac
      done
      if [ "$delete" -eq 1 ]; then
        # `git push [--delete] <remote> <ref>...`: the first positional is the
        # remote. A delete that named only ONE positional is malformed git, so
        # inspect it rather than assuming it was a harmless remote name.
        targets="$pos_rest"
        [ -n "$targets" ] || targets="$pos_first"
        for p in $targets; do
          disposable_ref "$p" || deny "Deleting the remote ref '$p' is blocked — it removes the branch outright, which is strictly less recoverable than the force-push this guard already denies. Only the pipeline's disposable namespaces may be deleted this way: quetrex-spec/* and *-gates. Name the branch literally at the call site (this hook sees the command before the shell expands \$VARS); to retire anything else, go through a PR and branch protection."
        done
      fi
      ;;
  esac
  return 0
}

# --- one segment ------------------------------------------------------------
check_tokens() {
  depth="$1"; shift
  # strip leading env assignments and benign wrappers
  while [ "$#" -gt 0 ]; do
    case "$1" in
      [A-Za-z_]*=*) shift ;;
      sudo|doas|nohup|command|builtin|exec|time|nice|ionice|env) shift ;;
      *) break ;;
    esac
  done
  [ "$#" -gt 0 ] || return 0
  head="${1##*/}"            # /bin/rm -> rm
  case "$head" in
    rm) check_rm "$@" ;;
    git) check_git "$@" ;;
    bash|sh|zsh|dash|ksh|eval|xargs)
      # The literal text handed to a shell IS a command. Re-inspect it once.
      shift
      while [ "$#" -gt 0 ]; do
        case "$1" in -*) shift ;; *) break ;; esac
      done
      if [ "$#" -eq 0 ]; then
        # `... | bash` — the piped text is executed but is not in this segment.
        PIPE_TO_SHELL=1
      elif [ "$depth" -lt 2 ]; then
        check_tokens $((depth + 1)) "$@"
      fi
      ;;
  esac
  return 0
}

VERDICT_TMP=$(mktemp "${TMPDIR:-/tmp}/quetrex-deny-guard.XXXXXX" 2>/dev/null) || VERDICT_TMP="${TMPDIR:-/tmp}/quetrex-deny-guard.$$"
trap 'rm -f "$VERDICT_TMP" 2>/dev/null' EXIT

set -f                       # no globbing while word-splitting segments
while IFS= read -r seg; do
  [ -n "$seg" ] || continue
  # shellcheck disable=SC2086
  check_tokens 0 $seg
done <<< "$(split_segments "$cmd")"
set +f

# --- backstop: text piped into a bare shell really will be executed ---------
if [ "$PIPE_TO_SHELL" -eq 1 ]; then
  c=" $(printf '%s' "$cmd" | tr -s '[:space:]' ' ') "
  case "$c" in
    *"reset --hard"*) deny "git reset --hard is blocked — stash or commit first." ;;
    *"clean -f"*|*"clean -df"*|*"clean -fd"*|*"clean -xf"*|*"clean -fx"*) deny "git clean -f is blocked (irreversible)." ;;
  esac
  case "$c" in
    *"--force-with-lease"*|*"--force-if-includes"*) : ;;
    *"push --force"*|*"push -f"*) deny "Unconditional force-push is blocked — use --force-with-lease, or a PR + branch protection." ;;
  esac
  # Ref DELETION, same backstop. Coarser than check_git's token rule by
  # necessity (this text has not been parsed into arguments), so the disposable
  # namespaces are recognised by substring and cleared first — over-blocking is
  # how a guard gets switched off, and the pipeline pipes its own publication
  # steps around often enough to matter.
  case "$c" in
    *"quetrex-spec/"*|*"-gates"*) : ;;
    *" push "*)
      case "$c" in
        *" --delete "*|*" -d "*)
          deny "Deleting a remote ref is blocked. This text is piped into a shell, so it really is about to run: \`git push --delete <ref>\` removes the branch outright, which is strictly less recoverable than the force-push this guard already denies. Only quetrex-spec/* and *-gates may be deleted this way." ;;
        *" :"*)
          deny "Deleting a remote ref is blocked. This text is piped into a shell, so it really is about to run: \`git push <remote> :<ref>\` is a ref DELETION. Only quetrex-spec/* and *-gates may be deleted this way." ;;
      esac ;;
  esac
fi

exit 0
