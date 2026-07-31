#!/usr/bin/env bash
# verify-gate.sh — Stop + SubagentStop hook. THE core non-negotiable gate.
#
# PILLAR #1 (EXCELLENT CODE): an agent must NOT be able to finish while the
# project's verification chain is red. This hook binds the finish decision to
# the REAL exit codes of the project's verify commands — never to chat prose
# like "tests passing". If ANY command exits non-zero it emits
#   {"decision":"block","reason":"<failing tail>"}
# on exit 0 (the ONLY form Stop/SubagentStop honor), so the agent is handed the
# failure and told to fix it. A bounded self-heal counter caps the loop at
# QUETREX_VERIFY_MAX (default 3); on the cap it writes .quetrex/ESCALATION and
# blocks one final time telling the agent to STOP self-healing and surface to
# the user — so red code can never be silently reported as done.
#
# NON-NEGOTIABLE: there is NO way for red to pass and NO way to skip a fresh
# verification and coast on a stale-green ledger. Specifically:
#   - There is NO fast-skip. Every Stop/SubagentStop runs the chain and writes a
#     fresh ledger cycle. A clean working tree does NOT let a prior green stand
#     in for the current state (a green ledger line can be stale — from an older
#     commit, or written before the current change landed). Correctness beats the
#     cost of a rebuild; the right-size router already trims orchestration.
#   - There is NO env-error laundering. A command that exits non-zero is RED,
#     full stop — including exit 127 / "command not found" / ENOENT / "No such
#     file or directory". A real test or build failure that happens to mention a
#     missing file is a genuine failure, not a toolchain excuse. Missing tooling
#     or deps therefore surface as an honest block: the agent installs/fixes
#     (bounded self-heal) or, at the cap, escalates to the user.
#   - There is NO fail-open on a missing `jq`. With jq, block() emits a
#     well-formed {"decision":"block",...} on exit 0. WITHOUT jq it does not
#     hand-roll JSON escaping (a failing build's stderr carries tabs/CRs/ANSI
#     that would malform the payload, and a malformed payload is DROPPED and
#     read as ALLOW); it prints the reason to stderr and exits 2 — the hook
#     contract's other blocking channel, which has no JSON to malform. Either
#     way a missing dependency can never silently allow a red finish.
#   - There is NO fail-open on a hook timeout. The whole chain runs against an
#     internal wall-clock budget (QUETREX_VERIFY_BUDGET, default well under the
#     external Stop/SubagentStop hook timeout) with each command capped via
#     `timeout`/`gtimeout` (or a kill-watchdog fallback). Exhausting the budget
#     is RED, blocked with a clear time-budget reason — the chain can never
#     run long enough to be killed by the external timeout before it emits.
#
# Single source of truth for the chain (in priority order):
#   1. $ROOT/.quetrex/verify.json  -> .verify[]   (canonical; written by init)
#      On SubagentStop, if .verifyQuick[] is present and non-empty it is used
#      instead (a QUICK per-subagent chain) — a strict SUBSET that still blocks
#      red; it never weakens the gate below the full chain when unconfigured.
#      Subset-ness is MECHANICALLY ENFORCED here, not assumed: every
#      verifyQuick entry must be a byte-for-byte member of verify[]. verify.json
#      is a customer-editable file, so an unchecked verifyQuick would be an
#      arbitrary REPLACEMENT for the chain (`verifyQuick:["true"]` passes every
#      SubagentStop). On any mismatch the quick chain is discarded, the FULL
#      verify[] chain runs, and the block reason says why.
#   2. $ROOT/.claude/CLAUDE.md      "## Verification" fenced command block
#   3. autodetect (package.json scripts / Makefile / pyproject / go.mod / Cargo)
# If none resolves, there is nothing to gate -> allow finish (exit 0).
#
# Worktree-safe root: $CLAUDE_PROJECT_DIR first, then `git rev-parse` from the
# session cwd. All artifacts live under $ROOT/.quetrex/.
#
# The ONLY conditions that allow finish without a block:
#   - not a git repo / no verify chain resolvable anywhere (nothing to gate), or
#   - the chain resolved AND every command exited 0 (PROVEN green by exit codes).
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
EVENT=$(jqget '.hook_event_name')

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

# The commit this verification run is proving. Recorded on every ledger line so
# the merge gate can COMMIT-PIN a green: a green line for an OLDER commit must
# never authorize a merge of a NEWER HEAD (closes the stale-green hole). Empty
# only if HEAD is unresolvable (e.g. a repo with no commits yet).
HEAD_SHA=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)

# On SubagentStop we may run a QUICK subset chain if the project defines one.
# QUICK_NOTE is set when a declared verifyQuick was REJECTED for not being a
# subset of verify[]; it is appended to any block reason so the operator sees
# why the full chain ran.
QUICK=0
QUICK_NOTE=""
[ "$EVENT" = "SubagentStop" ] && QUICK=1

# --- fail-closed time budget -------------------------------------------------
# The chain below runs synchronously inside a Stop (900s) / SubagentStop
# (600s) hook timeout (wired in quetrex-install-project-gates.sh). If the
# chain runs long enough for the hook to be killed mid-run, no block is ever
# emitted -> the finish is silently allowed with the tree unproven (fail-open
# via timeout). To fail CLOSED instead, every verify command below runs under
# an internal time budget kept safely under the external hook timeout, with
# headroom; exhausting it is treated as RED, not skipped. QUETREX_VERIFY_BUDGET
# (seconds) overrides the default for either event, and lets a single tiny
# value prove the fail-closed path (e.g. QUETREX_VERIFY_BUDGET=2 with a
# `sleep 5` command in the chain produces a block).
BUDGET_DEFAULT=840
[ "$EVENT" = "SubagentStop" ] && BUDGET_DEFAULT=540
BUDGET_TOTAL="${QUETREX_VERIFY_BUDGET:-$BUDGET_DEFAULT}"
case "$BUDGET_TOTAL" in ''|*[!0-9]*) BUDGET_TOTAL="$BUDGET_DEFAULT" ;; esac
[ "$BUDGET_TOTAL" -gt 0 ] 2>/dev/null || BUDGET_TOTAL="$BUDGET_DEFAULT"

# --- helpers ---------------------------------------------------------------

# Emit a Stop/SubagentStop block and exit 0 (the only honored form).
# FAIL-CLOSED even when jq is unavailable: if jq were the only path and it is
# missing, the jq call would fail silently, NOTHING would reach stdout, and
# `exit 0` would still run -> Stop/SubagentStop treat "exit 0 + no decision
# JSON" as ALLOW, so every red build would finish as allowed.
#
# The no-jq fallback deliberately emits NO JSON. A hand-rolled escaper is a
# fail-open in disguise: the string being escaped is the tail of a FAILING
# BUILD's stderr, which routinely carries tabs, carriage returns, ANSI escapes
# and other raw control bytes that are illegal unescaped inside a JSON string.
# One of those produces malformed JSON, the runtime drops the undecodable
# payload, and "exit 0 + no decision" is read as ALLOW — exactly the red-finish
# this function exists to prevent. So instead of trying (and silently failing)
# to build JSON without jq, the fallback uses the OTHER blocking channel the
# hook contract provides: exit 2 is a blocking error whose stderr is fed back
# to the agent. There is no JSON to malform, so it cannot degrade to allow.
# jq stays the primary path because it produces the richer `reason` form.
block() {
  local reason="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg r "$reason" '{decision:"block",reason:$r}'
    exit 0
  fi
  printf '%s\n' "$reason" >&2
  exit 2
}

# Last-20-lines of a captured output.
tail20() { printf '%s' "$1" | tail -n 20; }

# --- resolve the verification chain ----------------------------------------
# Populates the array CHAIN with ordered command strings.
CHAIN=()

resolve_from_verify_json() {
  local f="$QDIR/verify.json"
  [ -f "$f" ] || return 1
  # Prefer .verifyQuick[] on SubagentStop when it is present and non-empty;
  # otherwise the full .verify[] chain. Never weaken to quick when unconfigured.
  #
  # SUBSET IS ENFORCED, NOT ASSUMED. verify.json lives in the CUSTOMER's repo,
  # so verifyQuick is an untrusted input on the finish path. Without this check
  # `"verifyQuick": ["true"]` — or any command not in the full chain — would
  # pass every SubagentStop, turning the quick chain into an arbitrary
  # replacement for the gate rather than a narrowing of it. A quick chain may
  # only ever be a SUBSET of verify[]: every entry must be a member of
  # verify[], byte-for-byte. On ANY mismatch (a foreign command, a non-array
  # verify, a missing verify) we do NOT trust it — we run the FULL verify[]
  # chain instead and say so in the block reason, so the misconfiguration is
  # visible rather than silently weakening the gate.
  local sel='.verify'
  if [ "$QUICK" -eq 1 ] \
     && jq -e '.verifyQuick | type == "array" and length > 0' "$f" >/dev/null 2>&1; then
    if jq -e '
          ((.verify // null) | type) == "array"
          and ((.verifyQuick - .verify) | length) == 0
        ' "$f" >/dev/null 2>&1; then
      sel='.verifyQuick'
    else
      local foreign
      foreign=$(jq -r '
          (.verifyQuick - ((.verify // []) | if type == "array" then . else [] end))
          | map("`" + (. | tostring) + "`") | join(", ")
        ' "$f" 2>/dev/null)
      QUICK_NOTE=$(printf '\n\nNOTE: .quetrex/verify.json declares a `verifyQuick` chain that is NOT a subset of `verify` (offending entr(y/ies): %s). A quick chain may only NARROW the full chain, never introduce commands it does not contain, so verifyQuick was IGNORED and the FULL `verify` chain was run. Fix verify.json so every verifyQuick entry appears verbatim in verify.' \
        "${foreign:-<unparseable>}")
    fi
  fi
  jq -e "$sel | type == \"array\" and length > 0" "$f" >/dev/null 2>&1 || return 1
  while IFS= read -r line; do
    [ -n "$line" ] && CHAIN+=("$line")
  done < <(jq -r "$sel[]" "$f" 2>/dev/null)
  [ "${#CHAIN[@]}" -gt 0 ]
}

resolve_from_claude_md() {
  local f="$ROOT/.claude/CLAUDE.md"
  [ -f "$f" ] || return 1
  # Extract commands from fenced code blocks that fall under a heading whose
  # text contains "Verification". Awk state machine: track "in verification
  # section" and "inside a fenced block".
  #
  # RULE ORDER IS LOAD-BEARING. The fence toggle MUST be evaluated first, and
  # the heading rule MUST be gated on !infence. A shell comment inside the
  # fenced block starts with `#` and therefore matches the heading pattern; if
  # the heading rule ran first it would set insec=0 and `next`, silently
  # ENDING the section mid-chain and truncating every command below the
  # comment. That is a fail-open: a subset of the chain runs, reports green,
  # and is written to the ledger, which merge-gate.sh then reads as
  # authoritative for the WHOLE chain. With the fence evaluated first and the
  # heading rule gated on !infence, an in-fence `#` line falls through to the
  # emit rule, which skips it as a comment and keeps the section open.
  local extracted
  extracted=$(awk '
    /^[[:space:]]*```/ { infence = !infence; next }
    (!infence && $0 ~ /^#{1,6}[[:space:]]/) {
      insec = (tolower($0) ~ /verification/) ? 1 : 0
      next
    }
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

mkdir -p "$QDIR"

# --- run the chain ---------------------------------------------------------
# Always run — no fast-skip, no stale-green. Every non-zero exit is RED. There
# is no env-error laundering: a command that exits non-zero fails the gate even
# if its output mentions ENOENT / "No such file or directory" / "command not
# found". Missing tooling/deps are handed to the agent to fix (bounded), not
# excused into a green finish.
RED=0
FAILED_CMD=""
FAILED_TAIL=""
FAILED_CODE=0
TIMED_OUT=0

# Run a single command under a wall-clock cap so a hang cannot silently burn
# through the external hook timeout. Prefers GNU `timeout`/`gtimeout`; if
# neither is installed, falls back to a background watchdog that SIGKILLs
# the command when its slice of the budget elapses — the chain must never be
# allowed to run unbounded regardless of what's on PATH. Sets CMD_OUT/CMD_CODE.
run_with_cap() {
  local cmd="$1" cap="$2"
  local tmo=""
  if command -v timeout >/dev/null 2>&1; then tmo="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then tmo="gtimeout"
  fi
  if [ -n "$tmo" ]; then
    CMD_OUT=$( ( cd "$ROOT" && "$tmo" -k 5 "${cap}s" bash -c "$cmd" ) 2>&1 )
    CMD_CODE=$?
  else
    local outfile
    outfile=$(mktemp "${TMPDIR:-/tmp}/quetrex-verify-out.XXXXXX" 2>/dev/null) || outfile="$QDIR/.verify-out.$$"
    ( cd "$ROOT" && bash -c "$cmd" ) >"$outfile" 2>&1 &
    local cpid=$!
    ( sleep "$cap"; kill -9 "$cpid" 2>/dev/null ) &
    local wpid=$!
    wait "$cpid" 2>/dev/null; CMD_CODE=$?
    kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
    CMD_OUT=$(cat "$outfile" 2>/dev/null)
    rm -f "$outfile" 2>/dev/null
  fi
}

BUDGET_START=$(date +%s)

for cmd in "${CHAIN[@]}"; do
  now=$(date +%s)
  remaining=$((BUDGET_TOTAL - (now - BUDGET_START)))
  if [ "$remaining" -le 0 ]; then
    # The budget was already exhausted by prior commands in this chain -> the
    # gate fails CLOSED rather than skipping the rest of the chain unproven.
    code=124
    out="TIMEOUT: the ${BUDGET_TOTAL}s verification time budget (QUETREX_VERIFY_BUDGET) was exhausted before this command could run."
    TIMED_OUT=1
  else
    run_with_cap "$cmd" "$remaining"
    code="$CMD_CODE"
    out="$CMD_OUT"
    if [ "$code" -eq 124 ] || [ "$code" -eq 137 ]; then
      TIMED_OUT=1
      out="${out}
TIMEOUT: this command exceeded its ${remaining}s share of the ${BUDGET_TOTAL}s verification time budget (QUETREX_VERIFY_BUDGET) and was killed."
    fi
  fi
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  t20=$(tail20 "$out")

  # Append to the append-only ledger (best-effort; failure to log never blocks).
  # `sha` pins this result to the exact commit it was proven against — the merge
  # gate requires the latest GREEN line for each chain command to carry the
  # CURRENT HEAD sha, so a stale green from an earlier commit cannot pass.
  jq -cn \
    --arg ts "$ts" --arg cmd "$cmd" --arg cwd "$ROOT" \
    --arg sha "$HEAD_SHA" \
    --argjson exit "$code" --arg tail "$t20" \
    '{ts:$ts,cmd:$cmd,cwd:$cwd,sha:$sha,exit:$exit,tail:$tail}' >> "$LEDGER" 2>/dev/null

  if [ "$code" -eq 0 ]; then
    continue
  fi

  # ANY non-zero exit is a genuine failure. Record it and stop the chain.
  RED=1
  FAILED_CMD="$cmd"
  FAILED_CODE="$code"
  FAILED_TAIL="$t20"
  break
done

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

# A time-budget kill is called out explicitly so the agent (and the human on
# escalation) knows this was a fail-closed timeout, not a normal assertion
# failure, and knows to split/speed up the chain rather than "fix a bug".
TIMEOUT_NOTE=""
if [ "$TIMED_OUT" -eq 1 ]; then
  TIMEOUT_NOTE=" This is a TIME-BUDGET kill: verification exceeded the ${BUDGET_TOTAL}s time budget (QUETREX_VERIFY_BUDGET) — treat as red; split or speed up the chain."
fi

if [ "$n" -lt "$MAX_ATTEMPTS" ]; then
  block "$(printf 'VERIFY FAILED (attempt %d/%d): `%s` exited %d.%s\nYou cannot finish while the verification chain is red. Fix the cause and it will re-run on your next stop.\n\n--- last 20 lines ---\n%s%s' \
    "$n" "$MAX_ATTEMPTS" "$FAILED_CMD" "$FAILED_CODE" "$TIMEOUT_NOTE" "$FAILED_TAIL" "$QUICK_NOTE")"
fi

# Cap reached -> escalate. Persist a marker the merge gate reads so red code
# physically cannot merge even once the agent is finally allowed to stop.
touch "$ESCALATION" 2>/dev/null
block "$(printf 'ESCALATE: `%s` is STILL red (exit %d) after %d self-heal attempts.%s\nSTOP self-healing now. Do NOT report this task as done. Surface this failure to the user verbatim, including the output below, and wait for direction.\n\n--- last 20 lines ---\n%s%s' \
  "$FAILED_CMD" "$FAILED_CODE" "$MAX_ATTEMPTS" "$TIMEOUT_NOTE" "$FAILED_TAIL" "$QUICK_NOTE")"
