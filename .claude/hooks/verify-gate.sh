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
#      An OPTIONAL sibling field, `requiredEnv`, declares per-command env
#      dependencies: {"requiredEnv": {"<exact command string from verify[]>":
#      ["VAR_NAME", ...]}}. See "DECLARATIVE ENV SKIP" below.
#   2. $ROOT/.claude/CLAUDE.md      "## Verification" fenced command block
#   3. autodetect (package.json scripts / Makefile / pyproject / go.mod / Cargo)
# If none resolves, there is nothing to gate -> allow finish (exit 0).
#
# Worktree-safe root: $CLAUDE_PROJECT_DIR first, then `git rev-parse` from the
# session cwd. All artifacts live under $ROOT/.quetrex/.
#
# The ONLY conditions that allow finish without a block:
#   - not a git repo / no verify chain resolvable anywhere (nothing to gate), or
#   - the ROOT is the MAIN checkout and pipeline work lives in a linked
#     worktree (see "NO MAIN-CHECKOUT RUNS" below) -> nothing runs, or
#   - the chain resolved AND every command either exited 0 or was declaratively
#     SKIPPED for a genuinely-absent required env var (PROVEN green by exit
#     codes; a skip is never itself a pass — see "DECLARATIVE ENV SKIP").
#
# Contract: Stop/SubagentStop hooks BLOCK via {"decision":"block","reason":...}
# printed on EXIT 0. Printing block JSON then exiting non-zero DISCARDS the JSON.
# This script therefore always `exit 0` after emitting, and emits nothing to
# stdout when it allows the finish.
#
# QUIET OUTPUT (no raw interpreter stack traces to the operator). A failing
# command's full captured stdout+stderr is written to $ROOT/.quetrex/verify-gate.log
# (mode 600, one run's worth per invocation) and NEVER interpolated into the
# block reason. The reason is a short, labelled summary (what ran, which
# checkout/branch, whether it BLOCKS) that references the log by path, capped
# at 3 lines, so an agent's closing message can report the summary and the log
# path without ever pasting a stack trace back at the operator.
#
# NO MAIN-CHECKOUT RUNS. If ROOT is the repo's MAIN checkout (not a linked
# worktree) and it has >= 1 linked worktree on a branch matching the project's
# `branchPrefix` (from `git show HEAD:.quetrex/project.json` — a COMMITTED
# read, default "claude/") the chain is NOT executed here — the pipeline's
# real work lives in that worktree, which runs its own gate. A candidate
# worktree is trusted ONLY when it is PROVEN, not merely present: its own
# `.quetrex/verify-ledger.jsonl` must hold at least one line sha-pinned to its
# OWN current HEAD, i.e. its own Stop/SubagentStop gate has genuinely fired
# against the exact state it is in right now. This closes the gated agent's
# own ability to manufacture the skip with a single allow-listed
# `git worktree add -b claude/x decoy` (a fresh worktree has zero ledger
# lines) while still letting a real, already-self-verified pipeline worktree
# be deferred to — the same sha-pinning discipline this file and
# merge-gate.sh already use everywhere else. If NO live worktree satisfies
# every condition, the chain runs HERE instead (fail closed — never guess).
# The hook allows the finish and prints one plain "VERIFY SKIPPED" line naming
# the checkout, the branch, the worktree it deferred to, and that it blocks
# nothing. Set QUETREX_VERIFY_FORCE=1 to force the chain to run in the main
# checkout anyway (e.g. CI; `.github/workflows/verify.yml` runs the chain
# directly and is unaffected since it never has a linked pipeline worktree).
#
# DECLARATIVE ENV SKIP. A command whose verify.json `requiredEnv` entry names a
# variable that is genuinely unavailable in THIS checkout is never executed —
# it is skipped pre-flight and reported with one plain "VERIFY SKIPPED" line
# naming the variable (never its value). This is PRE-FLIGHT and DECLARATIVE
# ONLY: it is never inferred by pattern-matching a command's output (that would
# be exactly the env-error laundering banned above). The ENTIRE requiredEnv
# mapping (and the `verify[]` membership check below) is read from the
# COMMITTED `.quetrex/verify.json` blob at HEAD — `git show HEAD:...` — NEVER
# the working-tree file (SEC-2). Reading the mapping live would let an agent
# pair a genuinely innocuous, reviewable one-line .env.example addition with
# an UNCOMMITTED command-to-variable association that skips an unrelated,
# already-failing command — the association, not the variable, is the part
# that must be visible in a reviewed diff. A skip fires ONLY when ALL of the
# following hold, so `requiredEnv` cannot be used to weaken the gate:
#   1. the command is byte-for-byte a member of the COMMITTED verify[] ARRAY
#      (type-asserted: a STRING `.verify` degrades jq's `index()` to a
#      SUBSTRING search, which would let any command that merely CONTAINS the
#      target as a substring pass this check — the type must be checked, not
#      assumed);
#   2. the variable name also appears as a NAME= key in the COMMITTED blob of
#      a tracked $ROOT/.env.example or $ROOT/.env.sample at HEAD (the repo
#      itself must declare it as required config, visible in a reviewed
#      diff — a tracked PATH with an uncommitted edit to the declaring line
#      does not count either);
#   3. the variable is unset-or-empty in the hook's own environment AND is not
#      a key in any of $ROOT/.env, .env.local, .env.development, .env.test that
#      exist in this checkout (those are dotenv-loaded at runtime, so their
#      presence means the command would have had the value).
# If the committed verify.json cannot be read at all (no HEAD, unreadable),
# NOTHING is treated as declared and no command is ever skipped.
# A skip writes NO ledger line for that command (it is not a pass), and a run
# that skipped anything must NOT clear a prior .quetrex/ESCALATION — only a run
# where every chain command genuinely executed and exited 0 may clear one.

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
CUR_BRANCH=$(git -C "$ROOT" branch --show-current 2>/dev/null)

# --- NO MAIN-CHECKOUT RUNS --------------------------------------------------
# If ROOT is the repo's MAIN checkout and a LINKED worktree is checked out on
# a branch matching the project's branchPrefix, the pipeline's real work lives
# there, not here. Running (and possibly blocking) the chain against main is
# both wasted work and the exact scenario that convinced the operator a
# healthy cloud build had failed. Defer entirely: run nothing, touch no
# ledger/attempts state, allow the finish, and say so in one plain line.
# QUETREX_VERIFY_FORCE=1 forces the chain to run here regardless (CI never
# has a linked pipeline worktree, so it is unaffected either way).
if [ "${QUETREX_VERIFY_FORCE:-0}" != "1" ]; then
  MAIN_GITDIR=$(git -C "$ROOT" rev-parse --path-format=absolute --git-dir 2>/dev/null)
  MAIN_COMMONDIR=$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  if [ -n "$MAIN_GITDIR" ] && [ "$MAIN_GITDIR" = "$MAIN_COMMONDIR" ]; then
    # branchPrefix is read from the COMMITTED blob (SEC-1), never the
    # working-tree file: the working-tree copy is editable by the very agent
    # this skip gates, so an agent could otherwise widen or redirect the
    # prefix match to whatever decoy branch it just created. Fail closed to
    # the built-in default "claude/" if project.json is unreadable at HEAD —
    # the SAME default this hook has always used, not a widening.
    BRANCH_PREFIX="claude/"
    if command -v jq >/dev/null 2>&1; then
      PROJECT_JSON_COMMITTED=$(git -C "$ROOT" show "HEAD:.quetrex/project.json" 2>/dev/null)
      if [ -n "$PROJECT_JSON_COMMITTED" ]; then
        P=$(printf '%s' "$PROJECT_JSON_COMMITTED" | jq -r '.branchPrefix // empty' 2>/dev/null)
        [ -n "$P" ] && BRANCH_PREFIX="$P"
      fi
    fi
    # A candidate must satisfy ALL of the following before it is trusted:
    #
    #   1. LIVE — its directory actually exists on disk (SEC/ADV-A). `git
    #      worktree list` keeps reporting a linked worktree's registration
    #      even after its directory was removed by hand (`rm -rf` instead of
    #      `git worktree remove`) — it is only dropped by an explicit
    #      `git worktree prune`. Deferring to a path that no longer exists
    #      would mean the chain runs NOWHERE.
    #   2. BRANCH-MATCHING — its branch matches the COMMITTED branchPrefix.
    #   3. PROVEN, not merely present (SEC-1). Liveness + a branch-prefix
    #      match alone are attacker-manufacturable: `git worktree add
    #      -b claude/x decoy` is on the Bash allow-list and costs the gated
    #      agent exactly one command. A freshly created worktree has NEVER
    #      had its own Stop/SubagentStop hook fire, so it has ZERO lines in
    #      its own verify-ledger.jsonl. A candidate is therefore trusted only
    #      when its OWN ledger holds at least one line sha-pinned to its OWN
    #      current HEAD — proof its gate has genuinely run against the exact
    #      state it is in right now. The line need not be green: a worktree
    #      whose own gate is actively blocking it is still genuinely running
    #      its own gate, which is exactly what "defer to it" requires. This
    #      is the same sha-pinning discipline this file and merge-gate.sh
    #      already use everywhere else, so a worktree that is torn down or
    #      whose HEAD has moved past its last proof no longer qualifies — it
    #      cannot supply a rubber-stamp for NEW, unproven state, only for
    #      exactly the state it already proved.
    #
    # If NO live worktree satisfies every condition, the loop leaves WT_PATH
    # empty and the chain runs HERE (fail closed — never guess).
    WT_PATH=""; WT_BRANCH=""
    CUR_WT_PATH=""
    while IFS= read -r wtline; do
      case "$wtline" in
        "worktree "*) CUR_WT_PATH="${wtline#worktree }" ;;
        "branch refs/heads/"*)
          if [ -n "$CUR_WT_PATH" ] && [ "$CUR_WT_PATH" != "$ROOT" ] && [ -d "$CUR_WT_PATH" ]; then
            b="${wtline#branch refs/heads/}"
            case "$b" in
              "$BRANCH_PREFIX"*)
                CAND_HEAD=$(git -C "$CUR_WT_PATH" rev-parse HEAD 2>/dev/null)
                CAND_LEDGER="$CUR_WT_PATH/.quetrex/verify-ledger.jsonl"
                if [ -n "$CAND_HEAD" ] && [ -f "$CAND_LEDGER" ] && command -v jq >/dev/null 2>&1 \
                   && jq -e -s --arg sha "$CAND_HEAD" 'any(.[]?; .sha == $sha)' "$CAND_LEDGER" >/dev/null 2>&1; then
                  WT_PATH="$CUR_WT_PATH"
                  WT_BRANCH="$b"
                fi
                ;;
            esac
          fi
          ;;
      esac
      [ -n "$WT_PATH" ] && break
    done < <(git -C "$ROOT" worktree list --porcelain 2>/dev/null)

    if [ -n "$WT_PATH" ]; then
      printf 'VERIFY SKIPPED: verification chain not run in the MAIN checkout %s (branch %s) — pipeline work is in worktree %s (branch %s), which runs its own gate. BLOCKS nothing.\n' \
        "$ROOT" "${CUR_BRANCH:-<detached>}" "$WT_PATH" "$WT_BRANCH"
      exit 0
    fi
  fi
fi

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
      # Kept to a single line (no embedded newlines) so it can be appended to
      # a block reason without breaking the <=3-line quiet-output budget.
      QUICK_NOTE=$(printf ' NOTE: verifyQuick in verify.json is not a subset of verify (offending: %s); ran the FULL verify chain instead.' \
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

# --- full-output log (QUIET fix part a) -------------------------------------
# Every command's FULL captured stdout+stderr is written here, never into the
# block reason. Recreated fresh each run so it always reflects THIS attempt.
# Mode 600 from creation: a failing build's output can contain values it
# echoed (the observed case was a database URL), so this file must never be
# group/world readable and must never be referenced by anything that stages
# files (it stays untracked under $ROOT/.quetrex/, which is gitignored).
LOG="$QDIR/verify-gate.log"
# SEC-3: refuse to write THROUGH a symlink. `: > "$LOG"` follows symlinks, so
# a symlink planted at this path would let the hook truncate, chmod 600, and
# append captured build output to any file the user can write. Unlinking
# whatever is at that path first (symlink or regular file) — before ever
# redirecting into it — makes the mode-600 guarantee unconditional instead of
# dependent on whichever inode happened to be there already; `rm -f` on a
# symlink removes the link itself, never the file it points at.
if [ -e "$LOG" ] || [ -L "$LOG" ]; then
  rm -f "$LOG" 2>/dev/null
fi
( umask 077; : > "$LOG" ) 2>/dev/null
chmod 600 "$LOG" 2>/dev/null

# --- DECLARATIVE ENV SKIP (fix part c) --------------------------------------
# Pre-flight only — NEVER inferred from a command's output. Returns 0 (skip)
# and sets MISSING_ENV_VAR when `cmd` has a requiredEnv entry in verify.json
# and every constraint in the header comment is satisfied; returns 1 (run it)
# otherwise, which is the fail-closed default for anything ambiguous.
MISSING_ENV_VAR=""
should_skip_for_env() {
  local cmd="$1"
  MISSING_ENV_VAR=""
  command -v jq >/dev/null 2>&1 || return 1
  # The ENTIRE requiredEnv mapping is read from the COMMITTED verify.json blob
  # at HEAD (SEC-2) — never the working-tree file — so both "which var" and
  # "which command it is paired with" must appear in a reviewed diff. Fail
  # closed if the committed blob cannot be read at all.
  local committed_verify_json
  committed_verify_json=$(git -C "$ROOT" show "HEAD:.quetrex/verify.json" 2>/dev/null) || return 1
  [ -n "$committed_verify_json" ] || return 1
  # Constraint 1: `cmd` must be a byte-for-byte member of the COMMITTED
  # verify[] ARRAY (type ASSERTED, not assumed: when `.verify` is a STRING,
  # jq's `index()` degrades to a SUBSTRING search, so a command that merely
  # CONTAINS `cmd` as a substring would incorrectly satisfy this check — see
  # ADV-D) AND the committed requiredEnv must declare vars for that exact
  # key. A foreign/typo'd requiredEnv key that happens not to equal any
  # verify[] entry simply cannot skip anything.
  printf '%s' "$committed_verify_json" | jq -e --arg c "$cmd" \
    '(.verify // []) as $v | ($v | type) == "array" and (($v | index($c)) != null)' \
    >/dev/null 2>&1 || return 1
  local vars
  vars=$(printf '%s' "$committed_verify_json" | jq -r --arg c "$cmd" '
      if (.requiredEnv // {}) | type == "object"
      then (.requiredEnv[$c] // []) | if type == "array" then .[] else empty end
      else empty end
    ' 2>/dev/null)
  [ -n "$vars" ] || return 1
  local v declared exfile committed
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    # Only ever treat well-formed shell identifiers as candidates; anything
    # else cannot be safely looked up and must never authorize a skip.
    case "$v" in
      [A-Za-z_]*) : ;;
      *) continue ;;
    esac
    case "$v" in *[!A-Za-z0-9_]*) continue ;; esac
    # Constraint 2: the repo itself must declare this as required config, and
    # that DECLARATION must be visible in a reviewed diff — per security_surface
    # constraint #2. Two escapes closed here:
    #   - a plain existence/grep check on disk is not enough (an UNTRACKED
    #     .env.example is invisible to any reviewer), so tracking is required; and
    #   - checking that the PATH is tracked is not enough either (a tracked file
    #     can still carry an UNCOMMITTED working-tree edit that grep would read
    #     straight off disk — `git ls-files` only proves the PATH is tracked,
    #     not that THIS line is). So the declaring line must be read from the
    #     COMMITTED blob at HEAD, never the live working-tree file. Only HEAD
    #     counts, not the staged index: a staged-but-uncommitted change still
    #     appears in no reviewed diff (nothing has been committed for a
    #     reviewer to see), so `git show :file` is deliberately NOT used here.
    #     Fail CLOSED: if the committed blob cannot be read at all (no HEAD,
    #     file absent at HEAD, git error), it does not count as declared.
    declared=0
    for exfile in .env.example .env.sample; do
      committed=$(git -C "$ROOT" show "HEAD:$exfile" 2>/dev/null) || continue
      if printf '%s\n' "$committed" | grep -qE "^${v}="; then
        declared=1
        break
      fi
    done
    [ "$declared" -eq 1 ] || continue
    # Constraint 3a: unset-or-empty in the hook's own environment.
    local val="${!v-}"
    [ -z "$val" ] || continue
    # Constraint 3b: not a key in any local dotenv file that would be loaded
    # at runtime (their presence means the command would have had the value).
    local envfile skip_this=0
    for envfile in "$ROOT/.env" "$ROOT/.env.local" "$ROOT/.env.development" "$ROOT/.env.test"; do
      if [ -f "$envfile" ] && grep -qE "^${v}=" "$envfile" 2>/dev/null; then
        skip_this=1
        break
      fi
    done
    [ "$skip_this" -eq 0 ] || continue
    MISSING_ENV_VAR="$v"
    return 0
  done <<EOF
$vars
EOF
  return 1
}

# --- run the chain ---------------------------------------------------------
# Always run — no fast-skip, no stale-green. Every non-zero exit is RED. There
# is no env-error laundering: a command that exits non-zero fails the gate even
# if its output mentions ENOENT / "No such file or directory" / "command not
# found". Missing tooling/deps are handed to the agent to fix (bounded), not
# excused into a green finish.
RED=0
SKIPPED=0
SKIP_LINES=""
SKIPPED_CMDS=""
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
  if should_skip_for_env "$cmd"; then
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    {
      printf '=== %s | SKIPPED (requiredEnv %s unavailable) | cmd: %s | cwd: %s ===\n' \
        "$ts" "$MISSING_ENV_VAR" "$cmd" "$ROOT"
    } >> "$LOG" 2>/dev/null
    SKIPPED=1
    SKIP_LINES="${SKIP_LINES}VERIFY SKIPPED: \`${cmd}\` not run in ${ROOT} — required env var ${MISSING_ENV_VAR} is unavailable in this checkout (declared in .env.example, unset here). BLOCKS nothing; the command is never proven and never counted as a pass.
"
    SKIPPED_CMDS="${SKIPPED_CMDS:+$SKIPPED_CMDS, }\`${cmd}\`"
    continue
  fi
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

  # Full, UNTRUNCATED output goes to the log file only — never into the block
  # reason (that is the whole point of the quiet fix; see header comment).
  {
    printf '=== %s | cmd: %s | exit: %s | cwd: %s ===\n' "$ts" "$cmd" "$code" "$ROOT"
    printf '%s\n' "$out"
  } >> "$LOG" 2>/dev/null

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
  # A skip's plain "VERIFY SKIPPED" line(s) are printed ONLY on this allow
  # path — never ahead of a block() call, whose stdout must stay pure JSON
  # (the contract's ONLY honored block form; extra leading text risks being
  # unparseable and read as fail-open). They are deliberately plain text,
  # never JSON, so they can never be misread as a decision object.
  [ -n "$SKIP_LINES" ] && printf '%s' "$SKIP_LINES"
  # A skip is NOT a green: it proves nothing about the skipped command, so a
  # run that skipped anything must not reset the self-heal counter or clear a
  # prior escalation. Only a run where every chain command genuinely executed
  # and exited 0 may do either (CONTAINMENT — see header comment / AC7).
  if [ "$SKIPPED" -eq 0 ]; then
    echo 0 > "$ATTEMPTS_FILE" 2>/dev/null   # reset self-heal counter on green
    rm -f "$ESCALATION" 2>/dev/null         # green clears any prior escalation
  fi
  exit 0                                    # allow finish (no block JSON)
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

# A RED chain can be preceded by earlier commands that were declaratively
# SKIPPED (requiredEnv unavailable). This whole task exists because the
# operator could not tell a real failure from a non-failure, so the block
# reason must say so here too — not just on the (separate, JSON-free) allow
# path. Folded into the reason as a single-line note (never a raw stdout line
# ahead of the block() JSON, which must stay pure — see the allow-path
# comment below) so it stays within the <=3-line quiet-output budget.
SKIP_NOTE=""
if [ -n "$SKIPPED_CMDS" ]; then
  SKIP_NOTE=" NOTE: also SKIPPED before this failure (requiredEnv unavailable, never proven): ${SKIPPED_CMDS}."
fi

# QUIET BLOCK REASONS (fix part a). One labelled summary line — what ran,
# which checkout/branch, whether it blocks — plus a line pointing at the log
# file. The raw command output (FAILED_TAIL) is deliberately NEVER interpolated
# here; it lives only in $LOG, written above for every command that ran.
if [ "$n" -lt "$MAX_ATTEMPTS" ]; then
  block "$(printf 'VERIFY FAILED (attempt %d/%d): `%s` exited %d in %s (branch %s).%s%s%s BLOCKS finish — fix the cause; it re-runs on your next stop.\nFull output: %s' \
    "$n" "$MAX_ATTEMPTS" "$FAILED_CMD" "$FAILED_CODE" "$ROOT" "${CUR_BRANCH:-<detached>}" "$TIMEOUT_NOTE" "$QUICK_NOTE" "$SKIP_NOTE" "$LOG")"
fi

# Cap reached -> escalate. Persist a marker the merge gate reads so red code
# physically cannot merge even once the agent is finally allowed to stop.
touch "$ESCALATION" 2>/dev/null
block "$(printf 'ESCALATE: `%s` is STILL red (exit %d) after %d self-heal attempts in %s (branch %s).%s%s%s BLOCKS finish — STOP self-healing.\nFull output: %s\nReport this one-line summary and the log path to the user; do NOT paste command output into your closing message. Wait for direction.' \
  "$FAILED_CMD" "$FAILED_CODE" "$MAX_ATTEMPTS" "$ROOT" "${CUR_BRANCH:-<detached>}" "$TIMEOUT_NOTE" "$QUICK_NOTE" "$SKIP_NOTE" "$LOG")"
