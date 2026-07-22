#!/usr/bin/env bash
# verify-gate.sh — Stop + SubagentStop hook. THE core non-negotiable gate.
#
# PILLAR #1 (EXCELLENT CODE): an agent must NOT be able to finish while the
# project's verification chain is red. This hook binds the finish decision to
# the REAL exit codes of the project's verify commands — never to chat prose
# like "tests passing". If any command exits non-zero it emits
#   {"decision":"block","reason":"<failing output>"}
# on exit 0 (the ONLY form Stop/SubagentStop honor), so the agent is handed the
# failure and told to fix it. A bounded self-heal counter caps the loop at
# QUETREX_VERIFY_MAX (default 3); on the cap it writes .quetrex/ESCALATION and
# blocks one final time telling the agent to STOP self-healing and surface to
# the user — so red code can never be silently reported as done.
#
# Single source of truth for the chain (in priority order):
#   1. $ROOT/.quetrex/verify.json  -> .verify[]   (canonical; written by init)
#   2. $ROOT/.claude/CLAUDE.md      "## Verification" fenced command block
#   3. autodetect (package.json scripts / Makefile / pyproject / go.mod / Cargo)
# If none resolves, there is nothing to gate -> allow finish (exit 0).
#
# Worktree-safe root: $CLAUDE_PROJECT_DIR first, then `git rev-parse` from the
# session cwd. All artifacts live under $ROOT/.quetrex/.
#
# Skips cleanly (allows finish, never blocks) when it genuinely CANNOT verify:
#   - not a git repo / no chain resolvable
#   - nothing changed since the last green ledger run (fast path)
#   - required tooling/deps absent (exit 127 / "command not found" / "Missing
#     script" / ENOENT) — blocking on a missing toolchain would gridlock the
#     agent, and the merge gate (enforce-merge-approval) re-reads the ledger
#     independently, so a genuinely un-runnable chain still cannot ship as green.
#
# Contract: Stop/SubagentStop hooks BLOCK via {"decision":"block","reason":...}
# printed on EXIT 0. Printing block JSON then exiting non-zero DISCARDS the JSON.
# This script therefore always `exit 0` after emitting, and emits nothing to
# stdout when it allows the finish.

set -uo pipefail

MAX_ATTEMPTS="${QUETREX_VERIFY_MAX:-3}"

# --- read hook input (best-effort; absence is fine) ------------------------
INPUT=""
if [ ! -t 0 ]; then INPUT=$(cat); fi
jqget() { printf '%s' "$INPUT" | jq -r "$1 // empty" 2>/dev/null; }
SESSION_CWD=$(jqget '.cwd')

# --- resolve repo root (worktree-safe) -------------------------------------
ROOT=""
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then
  ROOT=$(git -C "$CLAUDE_PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null) \
    || ROOT="$CLAUDE_PROJECT_DIR"
fi
if [ -z "$ROOT" ] && [ -n "$SESSION_CWD" ] && [ -d "$SESSION_CWD" ]; then
  ROOT=$(git -C "$SESSION_CWD" rev-parse --show-toplevel 2>/dev/null)
fi
if [ -z "$ROOT" ]; then
  ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
fi
# Nothing to gate if we cannot locate a repo root.
[ -n "$ROOT" ] && [ -d "$ROOT" ] || exit 0

QDIR="$ROOT/.quetrex"
LEDGER="$QDIR/verify-ledger.jsonl"
ATTEMPTS_FILE="$QDIR/verify-attempts"
ESCALATION="$QDIR/ESCALATION"

# --- helpers ---------------------------------------------------------------

# Emit a Stop/SubagentStop block and exit 0 (the only honored form).
block() {
  jq -cn --arg r "$1" '{decision:"block",reason:$r}'
  exit 0
}

# Last-20-lines of a captured output.
tail20() { printf '%s' "$1" | tail -n 20; }

# True when the working tree has uncommitted changes to CODE. The gate's own
# runtime artifacts under .quetrex/ (ledger, counter, escalation) are excluded —
# otherwise the ledger the gate itself writes would make every tree look dirty
# and defeat the fast-skip path.
tree_dirty() {
  local s
  s=$(git -C "$ROOT" status --porcelain 2>/dev/null | grep -v '\.quetrex/')
  [ -n "$s" ]
}

# Exit code + tail markers that mean "toolchain/deps not installed", NOT a real
# code failure. Such a command is skipped rather than counted as red.
is_env_error() { # $1=exit code  $2=output
  [ "$1" -eq 127 ] && return 0
  printf '%s' "$2" | grep -qiE \
    'command not found|: not found|Missing script|No such file or directory|ENOENT|executable not found|could not determine executable|is not recognized as' \
    && return 0
  return 1
}

# Was the last recorded ledger cycle all-green? (used for the fast-skip path)
last_ledger_green() {
  [ -f "$LEDGER" ] || return 1
  # The ledger is append-only; a cycle ends at a green run or a red break.
  # Treat "the most recent line is exit 0 AND no red appears after the last
  # green-reset marker" simply as: the last line's exit is 0.
  local last
  last=$(tail -n 1 "$LEDGER" 2>/dev/null)
  [ -n "$last" ] || return 1
  [ "$(printf '%s' "$last" | jq -r '.exit // 1' 2>/dev/null)" = "0" ]
}

# --- resolve the verification chain ----------------------------------------
# Populates the array CHAIN with ordered command strings.
CHAIN=()

resolve_from_verify_json() {
  local f="$QDIR/verify.json"
  [ -f "$f" ] || return 1
  jq -e '.verify | type == "array" and length > 0' "$f" >/dev/null 2>&1 || return 1
  while IFS= read -r line; do
    [ -n "$line" ] && CHAIN+=("$line")
  done < <(jq -r '.verify[]' "$f" 2>/dev/null)
  [ "${#CHAIN[@]}" -gt 0 ]
}

resolve_from_claude_md() {
  local f="$ROOT/.claude/CLAUDE.md"
  [ -f "$f" ] || return 1
  # Extract commands from fenced code blocks that fall under a heading whose
  # text contains "Verification". Awk state machine: track "in verification
  # section" and "inside a fenced block".
  local extracted
  extracted=$(awk '
    /^#{1,6}[[:space:]]/ {
      insec = (tolower($0) ~ /verification/) ? 1 : 0
      next
    }
    /^[[:space:]]*```/ { infence = !infence; next }
    (insec && infence) {
      line = $0
      sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line)
      if (line == "" || line ~ /^#/) next          # skip blanks/comments
      sub(/^\$[[:space:]]*/, "", line)             # strip leading "$ " prompt
      print line
    }
  ' "$f" 2>/dev/null)
  while IFS= read -r line; do
    [ -n "$line" ] && CHAIN+=("$line")
  done < <(printf '%s\n' "$extracted")
  [ "${#CHAIN[@]}" -gt 0 ]
}

resolve_autodetect() {
  local pkg="$ROOT/package.json"
  if [ -f "$pkg" ]; then
    local key
    for key in typecheck type-check tsc lint build test; do
      if jq -e --arg k "$key" '.scripts[$k] // empty' "$pkg" >/dev/null 2>&1; then
        CHAIN+=("npm run $key")
      fi
    done
    [ "${#CHAIN[@]}" -gt 0 ] && return 0
  fi
  if [ -f "$ROOT/Makefile" ] || [ -f "$ROOT/makefile" ]; then
    local mk; mk="$ROOT/Makefile"; [ -f "$mk" ] || mk="$ROOT/makefile"
    grep -qE '^(lint|build|test|check):' "$mk" 2>/dev/null && {
      grep -qE '^lint:'  "$mk" && CHAIN+=("make lint")
      grep -qE '^build:' "$mk" && CHAIN+=("make build")
      grep -qE '^test:'  "$mk" && CHAIN+=("make test")
      grep -qE '^check:' "$mk" && CHAIN+=("make check")
      return 0
    }
  fi
  if [ -f "$ROOT/pyproject.toml" ] || [ -f "$ROOT/setup.cfg" ]; then
    CHAIN+=("python -m pytest -q"); return 0
  fi
  if [ -f "$ROOT/go.mod" ]; then
    CHAIN+=("go build ./..." "go test ./..."); return 0
  fi
  if [ -f "$ROOT/Cargo.toml" ]; then
    CHAIN+=("cargo build" "cargo test"); return 0
  fi
  return 1
}

resolve_from_verify_json || resolve_from_claude_md || resolve_autodetect || {
  # No chain resolvable anywhere -> nothing to gate.
  exit 0
}

# --- fast-skip path --------------------------------------------------------
# If the working tree is clean AND the last ledger cycle was green, nothing has
# changed that could have regressed the build — allow finish without paying for
# a full rebuild (SPEED). Any dirt, a missing ledger, or a prior red -> verify.
if ! tree_dirty && last_ledger_green; then
  exit 0
fi

# --- deps preflight --------------------------------------------------------
# If the chain drives a Node package manager but deps are not installed, we
# cannot verify. Skip cleanly rather than block on a missing toolchain.
needs_node=0
for cmd in "${CHAIN[@]}"; do
  case "$cmd" in
    npm\ *|npx\ *|pnpm\ *|yarn\ *|node\ *) needs_node=1 ;;
  esac
done
if [ "$needs_node" -eq 1 ] && [ ! -d "$ROOT/node_modules" ] && [ -f "$ROOT/package.json" ]; then
  echo "verify-gate: node dependencies not installed (no node_modules); skipping verification." >&2
  exit 0
fi

mkdir -p "$QDIR"

# --- run the chain ---------------------------------------------------------
RED=0
FAILED_CMD=""
FAILED_TAIL=""
FAILED_CODE=0
RAN_ANY=0

for cmd in "${CHAIN[@]}"; do
  out=$( ( cd "$ROOT" && eval "$cmd" ) 2>&1 ); code=$?
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  t20=$(tail20 "$out")

  # Append to the append-only ledger (best-effort; failure to log never blocks).
  jq -cn \
    --arg ts "$ts" --arg cmd "$cmd" --arg cwd "$ROOT" \
    --argjson exit "$code" --arg tail "$t20" \
    '{ts:$ts,cmd:$cmd,cwd:$cwd,exit:$exit,tail:$tail}' >> "$LEDGER" 2>/dev/null

  if [ "$code" -eq 0 ]; then
    RAN_ANY=1
    continue
  fi

  # Distinguish "toolchain not installed" from a genuine code failure.
  if is_env_error "$code" "$out"; then
    echo "verify-gate: '$cmd' could not run (toolchain/deps missing, exit $code); skipping." >&2
    continue
  fi

  RED=1
  RAN_ANY=1
  FAILED_CMD="$cmd"
  FAILED_CODE="$code"
  FAILED_TAIL="$t20"
  break
done

# If every command was un-runnable (all env errors), we verified nothing —
# cannot gate. Allow finish; the merge gate independently re-reads the ledger.
if [ "$RAN_ANY" -eq 0 ]; then
  exit 0
fi

# --- decision --------------------------------------------------------------
if [ "$RED" -eq 0 ]; then
  echo 0 > "$ATTEMPTS_FILE" 2>/dev/null   # reset self-heal counter on green
  rm -f "$ESCALATION" 2>/dev/null         # green clears any prior escalation
  exit 0                                   # PROVEN green by exit codes -> finish
fi

# RED path — bounded self-heal.
n=0
[ -f "$ATTEMPTS_FILE" ] && n=$(cat "$ATTEMPTS_FILE" 2>/dev/null)
case "$n" in ''|*[!0-9]*) n=0 ;; esac
n=$((n + 1))
echo "$n" > "$ATTEMPTS_FILE" 2>/dev/null

if [ "$n" -lt "$MAX_ATTEMPTS" ]; then
  block "$(printf 'VERIFY FAILED (attempt %d/%d): `%s` exited %d.\nYou cannot finish while the verification chain is red. Fix the cause and it will re-run on your next stop.\n\n--- last 20 lines ---\n%s' \
    "$n" "$MAX_ATTEMPTS" "$FAILED_CMD" "$FAILED_CODE" "$FAILED_TAIL")"
fi

# Cap reached -> escalate. Persist a marker the merge gate reads so red code
# physically cannot merge even once the agent is finally allowed to stop.
touch "$ESCALATION" 2>/dev/null
block "$(printf 'ESCALATE: `%s` is STILL red (exit %d) after %d self-heal attempts.\nSTOP self-healing now. Do NOT report this task as done. Surface this failure to the user verbatim, including the output below, and wait for direction.\n\n--- last 20 lines ---\n%s' \
  "$FAILED_CMD" "$FAILED_CODE" "$MAX_ATTEMPTS" "$FAILED_TAIL")"
