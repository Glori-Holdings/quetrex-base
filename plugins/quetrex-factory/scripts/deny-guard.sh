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
#
# ABBREVIATED LONG OPTIONS ARE THE OPTION (finding f1/f3). Matching the
# spelled-out `--delete` was a three-character bypass of the whole ref-deletion
# rule: git's parse-options resolves any UNAMBIGUOUS prefix. Measured against
# git 2.54.0 and a real bare remote:
#   git push origin --delete|--delet|--dele|--del|--de <ref>  -> ref DELETED, exit 0
#   git push origin --d <ref>       -> refused, "ambiguous option: d"
#   git push --mirror|--mirro|--m origin                      -> refs DELETED
#   git push --prune|--pru origin refs/heads/*                -> refs DELETED
#   git reset --hard|--har|--ha|--h -> worktree reset
#   git clean --force|--forc|--for|--fo|--f -> files removed
# So every long-option match in this file is a PREFIX match (opt_is), never an
# equality test. Over-matching a prefix git itself calls ambiguous costs
# nothing: git refuses to run those, so nothing legitimate is lost.
#
# FORCE IS A REFSPEC SYNTAX, NOT ONLY A FLAG. `git push origin +main:main`
# force-updates main and names no flag at all, so a guard that decides "is this
# a force push?" from FLAGS alone waves it through. MEASURED against real git
# and a real bare remote (remote main = A->B, local `rewrite` = A->C):
#   git push origin  rewrite:main -> ! [rejected] (non-fast-forward), exit 1
#   git push origin +rewrite:main -> + 43ca87a...9dac8d5 (forced update), exit 0
# and B was afterwards NOT an ancestor of the remote main. `+refs/heads/*:
# refs/heads/*` does that to every branch at once. Both the parsed push arm and
# the piped-shell backstop therefore judge a `+` refspec on its DESTINATION ref
# (refspec_dst) through the same disposable_ref() predicate the delete arm uses.
# --force-with-lease has no refspec spelling, so `+` is always the unsafe form.

set -o pipefail

# --- read hook input -------------------------------------------------------
input=""
if [ ! -t 0 ]; then input=$(cat); fi
[ -z "$input" ] && exit 0

JQ_OK=0
if command -v jq >/dev/null 2>&1 && printf '%s' "$input" | jq . >/dev/null 2>&1; then
  JQ_OK=1
fi

# NOTE (SEC-ONECOPY-1): command extraction now happens BEFORE the armed-only
# gate below (it used to happen after). The kill-switch check that follows
# the armed gate needs $cmd, and function definitions must precede their
# call site in a script executed top-to-bottom — so deny() and cmd parsing
# both move up. Behavior for every EXISTING rule in this file is unchanged:
# the armed-only exit below still runs before any of them.
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

# --- quote-aware segmentation (moved up: SEC-ONECOPY-1's kill-switch check,
# below, needs this before the main rule set is defined) -------------------
# Emits one pipeline segment per line. Quote characters are dropped but their
# CONTENTS are preserved verbatim, and separators inside quotes do NOT split —
# so `grep -rn "git reset --hard" docs/` is one segment whose first token is
# `grep`, while `rm -rf "/"` still presents `/` as an argument.
#
# An UNQUOTED `#` at the start of a word begins a shell comment, and everything
# after it is not a command. Dropping it here is not cosmetic: with the comment
# left in, `echo '...' | bash # note` handed `bash` the arguments `#` and `note`,
# so check_tokens took the branch for "a shell invoked with a script" instead of
# "text piped into a bare shell" and NEVER SET PIPE_TO_SHELL — one trailing
# comment switched the whole piped-shell backstop off (finding f2).
split_segments() {
  s="$1"; out=""; inq=""; i=0; n=${#s}; prev=" "
  while [ "$i" -lt "$n" ]; do
    ch="${s:$i:1}"
    if [ -n "$inq" ]; then
      if [ "$ch" = "$inq" ]; then inq=""; else out="$out$ch"; fi
    else
      case "$ch" in
        '#') case "$prev" in
               ' '|'	') break ;;          # word-initial: the rest is a comment
               *) out="$out$ch" ;;          # mid-word (`issue#42`): a literal
             esac ;;
        "'"|'"') inq="$ch" ;;
        ';'|'&'|'|'|'('|')'|'{'|'}'|'`') out="$out
" ;;
        *) out="$out$ch" ;;
      esac
    fi
    prev="$ch"
    i=$((i + 1))
  done
  printf '%s\n' "$out"
}

# --- armed-only gate (ONE-COPY), PER-INVOCATION (C5 FIX, review finding) --
# Standard SESSION resolver (mirrors session-state.sh): CLAUDE_PROJECT_DIR ->
# the payload's .cwd -> a plain `git rev-parse` from this process's own cwd.
# This is the FALLBACK target only — see C5 below for why it can no longer
# be the ONLY target this file judges arming against.
_cwd=$(printf '%s' "$input" | tr -d '
' | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
if [ "$JQ_OK" -eq 1 ]; then
  _jq_cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
  [ -n "$_jq_cwd" ] && _cwd="$_jq_cwd"
fi
# SEC-QUE1-1 (2026-09-01): same jq-primary/sed-fallback extraction, for the
# payloads own transcript_path -- see _kg_is_transcript_literal below for
# why this matters (a candidate that names the LIVE transcript by an exact
# match, without ever spelling ".claude/projects" in its own text).
_transcript_path=$(printf '%s' "$input" | tr -d '
' | sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
if [ "$JQ_OK" -eq 1 ]; then
  _jq_tp=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
  [ -n "$_jq_tp" ] && _transcript_path="$_jq_tp"
fi
_session_root=""
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "${CLAUDE_PROJECT_DIR:-}" ]; then
  _session_root=$(git -C "$CLAUDE_PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null) || _session_root="$CLAUDE_PROJECT_DIR"
fi
if [ -z "$_session_root" ] && [ -n "$_cwd" ] && [ -d "$_cwd" ]; then
  _session_root=$(git -C "$_cwd" rev-parse --show-toplevel 2>/dev/null)
fi
[ -z "$_session_root" ] && _session_root=$(git rev-parse --show-toplevel 2>/dev/null)

# C5 (review finding, medium): this file used to resolve arming ONCE, from
# the SESSION's own repo, and gate every rule on that single answer —
# so `git -C <armed-repo> push --force origin main`, run from an unarmed
# session cwd, sailed through (measured: DENY at 40feac8, silent ALLOW at
# 2ffde3a). enforce-branch.sh, changed in the SAME commit, already resolves
# per-invocation (its own -C/cd tracking, enforce-branch.sh:220-231) — two
# hooks in one change disagreed about which repo's arming governs.
#
# THE FIX. resolve_root_for/target_armed below resolve the TARGET repo an
# individual git invocation (or a bare `rm`, judged by the last `cd` in this
# same command) actually names, exactly the way enforce-branch already
# does — falling back to the session root only when nothing more specific
# was named. check_rm() and check_git() each call target_armed() on their
# OWN resolved target before evaluating any rule; LAST_CD is a script-global
# updated by check_tokens whenever a segment's head is `cd`, so a `cd
# <armed-repo> && git push --force` two segments into one command is judged
# against <armed-repo>, not the session.
LAST_CD=""

# --- qx_repo_armed: the ONE shared arming predicate (ONE-COPY round 2) -----
# Sibling file in this same scripts/ directory, so `dirname "${BASH_SOURCE[0]}"`
# resolves it identically in the repo checkout, the standalone quetrex-factory
# plugin's installed cache, and nested inside quetrex's bundled copy — same
# shape verify-gate.sh already uses to source verify-gate-quick-chain.sh.
QX_ARMED_HELPER="$(dirname "${BASH_SOURCE[0]}")/qx-armed.sh"
if ! source "$QX_ARMED_HELPER" 2>/dev/null || ! command -v qx_repo_armed >/dev/null 2>&1 \
   || ! command -v qx_normalize_path >/dev/null 2>&1; then
  # Sourcing failed (helper missing/unreadable in some non-standard install
  # layout) — degrade to the pre-shared-helper, working-tree-file-only
  # check rather than let the whole hook error out. Never a stack trace.
  qx_repo_armed() { [ -n "$1" ] && [ -f "$1/.quetrex/project.json" ]; }
  # SEC-QUE1-1 FOLLOWUP (2026-09-01): qx_normalize_path is called from
  # _kg_check_path (and resolve_root_for) UNCONDITIONALLY once reached — it
  # is not optional the way an extra safety check would be. EXECUTED,
  # before this fix: with qx-armed.sh unreachable, every call landed on an
  # UNDEFINED function -- bash printed "qx_normalize_path: command not
  # found" to stderr and the command substitution silently returned an
  # EMPTY string, so the path being checked collapsed to "", matched
  # nothing, and the write/command that should have been denied was
  # ALLOWED. A missing helper must never fail OPEN, and this hook must
  # never surface a raw interpreter error as if something else broke — see
  # the DEFENSIVE FLOOR check right below this block, which is the actual
  # belt-and-suspenders floor; THIS fallback exists so that floor is
  # normally never even needed.
  #
  # ONE-COPY, THIRD COPY (mirrors the split_segments_quote_aware /
  # normalize_segment convention this repo already uses across
  # merge-gate.sh, protected-files-guard.sh and verify-gate-quick-chain.sh
  # — see the QX-CMDSCAN BEGIN/END sentinel comment in those files): this
  # is now the SECOND fallback copy of qx_normalize_path (qx-armed.sh is
  # the canonical, sourced definition; protected-files-guard.sh carries an
  # identical inline fallback for the same "sourcing can fail" reason).
  # test/qx-normalize-path-parity.test.sh extracts all three copies by
  # function-name boundary (tolerant of indentation — only the DEDENTED
  # body is compared) and asserts them byte-identical pairwise, so a future
  # fix to one copy cannot silently leave the others on an older, weaker
  # one. bash 3.2-safe (no negative array indices), same as the original.
  qx_normalize_path() {
    local p="$1" part leading_slash="" last_idx joined
    local -a parts=() out=()
    case "$p" in /*) leading_slash="/" ;; esac
    IFS='/' read -ra parts <<< "$p"
    for part in "${parts[@]}"; do
      case "$part" in
        .|'') continue ;;
        ..)
          last_idx=$((${#out[@]} - 1))
          if [ "$last_idx" -ge 0 ] && [ "${out[$last_idx]}" != ".." ]; then
            unset "out[$last_idx]"
            out=(${out[@]+"${out[@]}"})
          else
            out+=("..")
          fi
          ;;
        *) out+=("$part") ;;
      esac
    done
    ( IFS='/'; joined="${out[*]:-}"; printf '%s%s' "$leading_slash" "$joined" )
  }
fi

# DEFENSIVE FLOOR (SEC-QUE1-1 FOLLOWUP): the fallback above should make this
# unreachable in practice, but a hook that GATES writes must never depend on
# "should" — if either required helper is somehow still unavailable here
# (a stub, a future refactor that removes the fallback, a corrupted
# install), FAIL CLOSED with one clean, labelled deny line. Never let
# execution reach a call to an undefined function: that prints a raw
# interpreter stack trace to the operator (this repos own rule: a hook must
# never surface one) AND, because `$(undefined_fn ...)` silently expands to
# an empty string rather than aborting the script, every downstream path
# check would silently match nothing and ALLOW the exact write this hook
# exists to deny -- fail OPEN on a missing dependency, the one failure mode
# a safety floor can never have.
if ! command -v qx_repo_armed >/dev/null 2>&1 || ! command -v qx_normalize_path >/dev/null 2>&1; then
  deny "deny-guard.sh: a required internal helper (qx_repo_armed or qx_normalize_path) is unavailable in this process, so this command cannot be safely evaluated. Refusing to run it unchecked rather than risk a silent bypass. This should never happen in a normal install -- if it does, report it."
fi

# PERF-ONECOPY-2 (round 4 reviewer, Medium): target_armed() below is called
# once per command SEGMENT (each `cd`, each redirection check), and
# qx_repo_armed does up to 7 real git subprocesses per call on an unarmed
# repo with none of it memoized — so a multi-segment command (a cd-chain,
# several rm/git checks in one Bash tool call) re-probed the SAME resolved
# root from scratch every single time. Measured with a git-invocation-
# counting shim: `echo hello` against an unarmed target went 13 git calls
# (two full un-memoized probes) -> 7 (one); a 4-segment cd-chain went 37 ->
# 7. Cache is keyed by resolved root and lives ONLY for this process's
# lifetime — a fresh PreToolUse hook invocation is a fresh process with
# fresh (empty) arrays, so nothing is ever written to disk, nothing can
# leak between invocations, and nothing can go stale WITHIN one invocation
# either: a PreToolUse hook runs strictly before the tool it is judging
# executes anything, so the real git/filesystem state this predicate
# inspects cannot change between two calls in the same run. THIS CACHE
# LIVES HERE, NOT in qx-armed.sh's own qx_repo_armed — that shared file is
# sourced directly (and its live, uncached answer relied on) by
# test/onecopy-armed-construction.test.sh, which deliberately mutates a
# single fixture's armed state across several qx_repo_armed calls in ONE
# process; caching at that shared layer returned stale answers there. bash
# 3.2-safe (no associative arrays — see qx_normalize_path's own note in
# qx-armed.sh): parallel indexed arrays with a linear scan, cheap because
# one invocation only ever names a handful of distinct roots.
_DG_ARMED_CACHE_ROOTS=()
_DG_ARMED_CACHE_RESULTS=()
_dg_qx_repo_armed_cached() {
  _dgc_root="$1"
  [ -n "$_dgc_root" ] || return 1
  _dgc_i=0
  while [ "$_dgc_i" -lt "${#_DG_ARMED_CACHE_ROOTS[@]}" ]; do
    if [ "${_DG_ARMED_CACHE_ROOTS[$_dgc_i]}" = "$_dgc_root" ]; then
      [ "${_DG_ARMED_CACHE_RESULTS[$_dgc_i]}" = "0" ]
      return $?
    fi
    _dgc_i=$((_dgc_i + 1))
  done
  qx_repo_armed "$_dgc_root"
  _dgc_rc=$?
  _DG_ARMED_CACHE_ROOTS+=("$_dgc_root")
  _DG_ARMED_CACHE_RESULTS+=("$_dgc_rc")
  return "$_dgc_rc"
}

# qx_resolve_cd <cd-target> <current-anchor-or-empty> -- resolves a `cd`
# TOKEN into an absolute (syntactically normalized) effective directory, so
# LAST_CD and _kill_cd below always hold a fully-resolved anchor rather than
# a raw, possibly-relative token. <current-anchor-or-empty> is the effective
# directory BEFORE this cd (empty means "still the session cwd"), so a
# SECOND cd in the same command joins against the FIRST cd's result, not
# against the original session cwd (D3, round-2 reviewer).
qx_resolve_cd() {
  _qxrc_t="$1"; _qxrc_base="${2:-$_cwd}"
  case "$_qxrc_t" in
    "~") _qxrc_t="$HOME" ;;
    "~/"*) _qxrc_t="$HOME/${_qxrc_t#\~/}" ;;
  esac
  case "$_qxrc_t" in
    /*) qx_normalize_path "$_qxrc_t" ;;
    *) qx_normalize_path "${_qxrc_base:+$_qxrc_base/}$_qxrc_t" ;;
  esac
}

resolve_root_for() {  # resolve_root_for <explicit-dir-or-empty> [<anchor-override>]
  _rrf_d="$1"
  # D3 (round-2 reviewer): a RELATIVE explicit target (from -C or --git-dir)
  # must anchor against the EFFECTIVE directory at the point it appears in
  # the command -- LAST_CD once any `cd` has been tracked, never always the
  # ORIGINAL session cwd. `cd <A>/.. && git -C armed push --force` names
  # "armed" relative to <A>/.., not to wherever the session started; the
  # bare-`rm`/no-`-C` case still passes its own (already-resolved-absolute)
  # LAST_CD as $1 directly, so this default is only ever consulted for an
  # explicit, still-relative -C/--git-dir value.
  _rrf_anchor="${2:-${LAST_CD:-$_cwd}}"
  if [ -n "$_rrf_d" ]; then
    case "$_rrf_d" in
      "~") _rrf_d="$HOME" ;;
      "~/"*) _rrf_d="$HOME/${_rrf_d#\~/}" ;;
    esac
    case "$_rrf_d" in
      /*) : ;;
      *) [ -n "$_rrf_anchor" ] && _rrf_d="$_rrf_anchor/$_rrf_d" ;;
    esac
    _rrf_d=$(qx_normalize_path "$_rrf_d")
    # An invocation that NAMES its directory is about that directory and no
    # other (mirrors enforce-branch.sh:238-241): a nonexistent explicit
    # target has nothing to protect, so it resolves to empty rather than
    # silently falling back to the session root and judging one repo by
    # another repo's arming.
    if [ ! -d "$_rrf_d" ]; then
      printf ''
      return 0
    fi
    _rrf_top=$(git -C "$_rrf_d" rev-parse --show-toplevel 2>/dev/null)
    if [ -z "$_rrf_top" ]; then
      # D2 (round-2 reviewer): `--git-dir=<X>` names the internal git
      # METADATA directory, not the work tree -- `git -C <X> rev-parse
      # --show-toplevel` genuinely fails there ("fatal: this operation must
      # be run in a work tree"), which previously made the whole target
      # unresolvable. `git --git-dir=<X> rev-parse --show-toplevel` is NOT a
      # safe substitute: without an explicit --work-tree it silently
      # resolves against THIS PROCESS's OWN cwd, not <X>'s repo at all
      # (measured). The standard, non-bare layout is exactly
      # <worktree>/.git, so strip that suffix textually -- no extra git
      # invocation, no cwd ambiguity -- as a best-effort fallback.
      case "$_rrf_d" in
        */.git) _rrf_top=$(git -C "${_rrf_d%/.git}" rev-parse --show-toplevel 2>/dev/null) ;;
      esac
    fi
    printf '%s' "$_rrf_top"
  else
    printf '%s' "$_session_root"
  fi
}

target_armed() {  # target_armed <explicit-dir-or-empty> [<anchor-override>]
  # SEC-ONECOPY-3 (Critical, round 2): this used to be the ONLY signal this
  # function judged — the TARGET's arming, alone — so naming ANY dir that
  # fails to resolve to an armed repo (a non-repo dir, a nonexistent dir,
  # `/`, `$HOME`, `..`, an unarmed sibling checkout) turned the whole rule
  # off, even from a fully armed session: `cd /tmp && rm -rf /`,
  # `git -C /nonexistent push --force origin main`, etc. all went from DENY
  # to ALLOW (measured against 2ffde3a / 40feac8 in .quetrex/security-findings.json).
  #
  # THE FIX (design A, round-2 orchestrator decision): the per-invocation
  # target is an ADDITION, never a replacement. Gate iff the SESSION root is
  # armed OR the resolved target is armed. The session's own arming is
  # therefore unconditionally one of the two signals and is never displaced
  # by a target that fails to resolve to something armed — only when the
  # SESSION is itself unarmed AND the named target resolves to a different,
  # also-unarmed repo (or resolves to nothing at all) does the gate stand
  # down, which is exactly the pre-C5 baseline for an unarmed session.
  _dg_qx_repo_armed_cached "$_session_root" && return 0
  _ta_root=$(resolve_root_for "$1" "$2")
  [ -n "$_ta_root" ] && _dg_qx_repo_armed_cached "$_ta_root"
}

# --- SEC-ONECOPY-1: the arming file is the whole floor's kill switch -------
# Every rule below (and every OTHER floor script) is gated on
# .quetrex/project.json existing. Nothing stopped the gated agent from
# `rm -f`/`mv`/`cp`-overwriting/redirecting-into/`git rm`-ing/`git checkout
# <ref> --`-restoring that one file (or the whole .quetrex directory) to
# silently disarm deny-guard, secret-scan, enforce-branch, merge-gate,
# verify-gate, edit-gate and protected-files-guard for the rest of the
# session. This check runs ONLY while the TARGET repo IS armed (C5: judged
# per-segment via target_armed(), never just the session's own repo — an
# unarmed repo has no gates at all, by the same rule everything else here
# already follows, so /quetrex-setup:init creating project.json for the first
# time is unaffected).
#
# SCOPED UNLOCK (2026-08-26, mirrors .claude/hooks/protected-files-guard.sh's
# own SEC-6 fix — the two guards must never disagree). This used to be
# bypassable by a bare QUETREX_UNLOCK_FLOOR=1 checked ONCE, up front, before
# check_quetrex_killswitch even ran (`if [ "$QUETREX_UNLOCK_FLOOR" != "1" ];
# then check_quetrex_killswitch ...; fi`) — so an AMBIENT blanket value (a
# terminal that exported it once for an unrelated earlier command, or the
# `env` block in `.claude/settings.json`, which is passed to every hook
# subprocess) silently unlocked EVERY kill-switch target for the rest of the
# session, with no per-target scoping at all. THE FIX: the gate below now
# calls check_quetrex_killswitch UNCONDITIONALLY, and each protected path is
# judged individually, inside _kg_check_path, against dg_is_unlocked_for()
# — the unlock value must NAME the exact basename(s) of the arming file(s)
# actually being targeted (`QUETREX_UNLOCK_FLOOR=project.json`, or a
# colon/comma-separated list for a command that touches more than one, e.g.
# `QUETREX_UNLOCK_FLOOR=project.json:verify.json` for `rm -rf .quetrex`,
# which removes both at once). A bare "1" — or any value that does not name
# the actual target(s) — authorizes NOTHING; it denies, and the deny message
# says so explicitly, naming the scoped form the operator actually needs.
#
# RESIDUAL, DISCLOSED (not enumerated further — see the header's own
# documented-residual style): this matches the literal path text handed to
# the shell before expansion, the same limitation disposable_ref() below
# already has for $VARIABLES; `git clean` is not checked because
# .quetrex/project.json is a TRACKED file and git clean never removes
# tracked files (verified: `git ls-files .quetrex/` lists it).
# _kg_is_transcript_literal <normalized-path> -- SEC-QUE1-1 (2026-09-01):
# 0 iff <normalized-path> is a Claude Code session transcript
# (~/.claude/projects/<slug>/<session>.jsonl) -- the ONE channel this whole
# safety floor treats as unforgeable proof a HUMAN, not the agent, is
# speaking (protected-files-guard.sh's qxva_* scans and merge-gate.sh's own
# QX_HUMAN_ORIGIN_PY both key on a rows origin.kind=="human" read straight
# out of that file). Nothing protected the file ITSELF before this fix: an
# agent could append one forged row and self-grant its own approval for
# every floor script this file gates. Checked by path-tail (any candidate
# whose text contains the ".claude/projects/<...>/<...>.jsonl" shape) AND,
# separately, by an exact match against THIS calls own payload
# transcript_path (_transcript_path, extracted above) after the same
# normalization -- so a candidate that resolves to the live transcript
# without spelling ".claude/projects" in its own text is still caught.
# UNCONDITIONAL: see _kg_deny_transcript below -- there is no unlock for
# this, unlike _kg_is_protected_literal below it.
_kg_is_transcript_literal() {
  case "$1" in
    *.claude/projects/*.jsonl) return 0 ;;
  esac
  if [ -n "$_transcript_path" ]; then
    _kgtl_norm_tp=$(qx_normalize_path "$_transcript_path")
    [ -n "$_kgtl_norm_tp" ] && [ "$1" = "$_kgtl_norm_tp" ] && return 0
  fi
  return 1
}

# _kg_is_protected_literal <normalized-path> -- 0 iff it IS one of the
# protected shapes. Factored out of _kg_check_path (round 2, reviewer C2)
# so the glob-expansion branch below can re-run the exact same literal test
# against each real filesystem match.
_kg_is_protected_literal() {
  case "$1" in
    */.quetrex/project.json|.quetrex/project.json) return 0 ;;
    */.quetrex/verify.json|.quetrex/verify.json) return 0 ;;
    */.quetrex|.quetrex) return 0 ;;
    */.quetrex/\*|.quetrex/\*) return 0 ;;   # `rm -rf .quetrex/*`
  esac
  return 1
}

# _kg_target_for_path <normalized-path> -- the basename(s) (space-separated)
# an unlock must name to authorize a write/removal that resolves to <path>.
# The two single-file shapes each need only their own basename; the
# whole-directory and glob-wildcard shapes remove BOTH arming files at once,
# so the unlock must name both — naming only one is not enough (see
# dg_is_unlocked_for below, which requires every space-separated item here).
_kg_target_for_path() {
  case "$1" in
    */.quetrex/project.json|.quetrex/project.json) printf 'project.json' ;;
    */.quetrex/verify.json|.quetrex/verify.json) printf 'verify.json' ;;
    */.quetrex|.quetrex|*/.quetrex/\*|.quetrex/\*) printf 'project.json verify.json' ;;
  esac
}

# --- scoped unlock (SEC-6-style; mirrors protected-files-guard.sh's own
# is_unlocked/deny). No function in this file uses `local` (existing house
# style, see opt_is/check_rm/check_git above), so these follow suit with a
# unique variable-name prefix instead.
dg_unlock_names() {  # dg_unlock_names <target-basename> -- true iff named
  _dun_target="${1:-}"
  _dun_val="${QUETREX_UNLOCK_FLOOR:-}"
  [ -n "$_dun_target" ] && [ -n "$_dun_val" ] || return 1
  _dun_items=()
  IFS=':,' read -ra _dun_items <<< "$_dun_val"
  for _dun_item in "${_dun_items[@]}"; do
    [ "$_dun_item" = "$_dun_target" ] && return 0
  done
  return 1
}

dg_is_unlocked_for() {  # dg_is_unlocked_for <space-separated-required-basenames>
  for _diu_req in $1; do
    dg_unlock_names "$_diu_req" || return 1
  done
  return 0
}

# dg_scoped_hint <space-separated-required-basenames> -- the exact
# QUETREX_UNLOCK_FLOOR value an operator must set, joined with ':' for a
# multi-target requirement.
dg_scoped_hint() {
  printf 'QUETREX_UNLOCK_FLOOR=%s' "$(printf '%s' "$1" | tr ' ' ':')"
}

_kg_deny_transcript() {  # _kg_deny_transcript <verb-description> <matched-path>
  # UNCONDITIONAL. Unlike _kg_deny_path below, this never reads or mentions
  # QUETREX_UNLOCK_FLOOR -- there is no legitimate reason for an agent to
  # write a transcript, so there is no door to unlock.
  deny "Refusing to let '$1' target '$2', a Claude Code session transcript under ~/.claude/projects/. A transcript is the ONLY channel this safety floor treats as unforgeable proof that a HUMAN, not the agent, is speaking -- an agent must never be able to write, plant, or edit a row in one. Denied unconditionally: there is no QUETREX_UNLOCK_FLOOR for this and no approval channel."
}

_kg_deny_path() {  # _kg_deny_path <verb-description> <matched-protected-path>
  _kg_target=$(_kg_target_for_path "$2")
  _kg_ambient="${QUETREX_UNLOCK_FLOOR:-}"
  _kg_reason="Refusing to let '$1' target .quetrex/project.json or .quetrex/verify.json (or the .quetrex directory) in an armed repo — project.json is what arms the entire safety floor (deny-guard, secret-scan, enforce-branch, merge-gate, verify-gate, edit-gate, protected-files-guard), and verify.json is what defines the verify chain that actually gates the tree. Removing, moving, or overwriting either would silently disable or swap out the gate for the rest of this session."
  if [ -n "$_kg_ambient" ]; then
    _kg_reason="$_kg_reason A QUETREX_UNLOCK_FLOOR value (\"$_kg_ambient\") was already present in the environment -- an ambient or blanket value (a bare \"1\", a stale export from an earlier command, or a settings.json env block) no longer authorizes anything here; it did not name this exact file. To make this change anyway, the operator (not the agent) must set $(dg_scoped_hint "$_kg_target") in the environment of the command that performs the edit, for an intentional, operator-approved re-init."
  else
    _kg_reason="$_kg_reason To make this change anyway, the operator (not the agent) must set $(dg_scoped_hint "$_kg_target") in the environment of the command that performs the edit, for an intentional, operator-approved re-init."
  fi
  deny "$_kg_reason"
}

_kg_check_path() {
  # Matched by SUFFIX, never by an exact root-prefixed string: a command's
  # own path argument is the raw text handed to the shell, while a resolved
  # root came back through `git rev-parse --show-toplevel`, which
  # canonicalizes symlinks (macOS's /tmp -> /private/tmp being the everyday
  # case). Requiring byte-identity between the two silently missed every
  # absolute-path vector under a symlinked tmp/worktree root — caught by
  # this file's own test fixture (mktemp -d lands under /var/folders/...,
  # a symlink target). A path-tail match sidesteps the mismatch entirely
  # and is the same shape protected-files-guard.sh's own PROT_PATH_ERE
  # already uses for the floor scripts.
  #
  # C6 (review finding, medium): .quetrex/verify.json is protected the SAME
  # way as project.json, alongside it. verify-gate.sh now BLOCKS an armed
  # repo that has neither verify.json nor a CLAUDE.md Verification fence
  # (see that file's own C6 fix) — so removing verify.json out from under
  # an armed repo is not the silent no-op it used to be, but it is still a
  # one-command way to force every future Stop into that block, or (if a
  # CLAUDE.md fence also happens to exist) to silently swap the chain that
  # actually gates the tree. Same scoped-unlock mechanism as project.json
  # (dg_is_unlocked_for / dg_unlock_names above), just its own basename
  # ("verify.json") rather than "project.json".
  #
  # C2 (round-2 reviewer): a RELATIVE candidate is now anchored against the
  # tracked cd (_kill_cd — the same context target_armed() already judges
  # arming against) BEFORE matching, and normalized (collapsing `//` and
  # `/./`) via the shared qx_normalize_path. Without this, `cd .quetrex &&
  # rm -f project.json` presented the bare, unanchored `project.json` to the
  # matcher, which only recognizes a `.quetrex/`-prefixed suffix; and
  # `.quetrex/./project.json` / `.quetrex//project.json` did not literally
  # match either suffix text.
  p="${1%/}"
  case "$p" in
    /*) : ;;
    *) [ -n "$_kill_cd" ] && p="$_kill_cd/$p" ;;
  esac
  p=$(qx_normalize_path "$p")

  if _kg_is_transcript_literal "$p"; then
    _kg_deny_transcript "$2" "$p"
  fi

  if _kg_is_protected_literal "$p"; then
    _kg_t=$(_kg_target_for_path "$p")
    dg_is_unlocked_for "$_kg_t" || _kg_deny_path "$2" "$p"
  fi

  # GLOB SAFETY (round-2 reviewer C2): a candidate carrying an unexpanded
  # glob metacharacter names no protected path LITERALLY, but would, once a
  # real shell expands it, remove exactly the file(s)/directory this check
  # exists to protect — `rm -f .quetrex/project.js*` and `rm -rf .qu*` are
  # both measured ALLOW without this. Expanded for real, against the actual
  # filesystem, anchored the SAME way an interactive shell would resolve it
  # (the session cwd, since a glob is evaluated by the shell at the point it
  # appears — this hook never tracks a cd's effect on globbing beyond what
  # _kill_cd already anchored above). Every real match is re-checked once,
  # non-recursively (a resolved match is always absolute, so it can never
  # re-enter this branch).
  #
  # PERF-ONECOPY-1 (round 4 reviewer, High): qx_normalize_path is a
  # command-substitution call — a fork — and this loop used to call it once
  # per filesystem match with NO prefilter, so an ordinary `rm -rf *`/`chmod
  # -R 755 vendor/*`/`cp build/* out/` in a large, entirely unrelated
  # directory forked once per entry (measured: 39.3s over 20000 entries,
  # 38.4s of which is the fork itself — 0.07s at e384c11, before this glob
  # branch existed). _kg_is_protected_literal can ONLY return 0 for a path
  # with a `.quetrex` path component (every one of its suffix patterns names
  # one), so a match that never contains that substring cannot possibly be
  # protected and normalizing it is pure waste. Prefilter with a `case`
  # (built-in, no fork) BEFORE the expensive normalize+match — this is the
  # exact remediation the finding names. The normalize call is still made
  # for anything that DOES contain `.quetrex`, so `.quetrex/./project.json`-
  # shaped matches (already covered by C2) are unaffected.
  case "$p" in
    *[\*\?\[]*)
      _kg_glob_target="$p"
      case "$_kg_glob_target" in
        /*) : ;;
        *) [ -n "$_cwd" ] && _kg_glob_target="$_cwd/$_kg_glob_target" ;;
      esac
      shopt -s nullglob 2>/dev/null
      for _kg_expanded in $_kg_glob_target; do
        case "$_kg_expanded" in
          *.quetrex*) : ;;
          *) continue ;;
        esac
        _kg_norm2=$(qx_normalize_path "$_kg_expanded")
        if _kg_is_protected_literal "$_kg_norm2"; then
          _kg_t2=$(_kg_target_for_path "$_kg_norm2")
          if ! dg_is_unlocked_for "$_kg_t2"; then
            shopt -u nullglob 2>/dev/null
            _kg_deny_path "$2 (glob '$1')" "$_kg_norm2"
          fi
        fi
      done
      shopt -u nullglob 2>/dev/null
      ;;
  esac
  return 0
}

check_quetrex_killswitch() {
  _kcmd="$1"
  _kill_cd=""   # C5: this scanner's OWN cd-tracking, mirroring LAST_CD below
  while IFS= read -r _kseg; do
    [ -n "$_kseg" ] || continue
    set -f
    _ktoks=()
    for _ktok in $_kseg; do _ktoks+=("$_ktok"); done
    set +f
    _kn=${#_ktoks[@]}
    [ "$_kn" -gt 0 ] || continue

    # 1) a redirection can attach to ANY command, not just a recognized verb —
    #    `echo x > .quetrex/project.json`, `cat a >> .quetrex/project.json`.
    #    C5: gated on the CURRENT directory context (the last `cd` seen in
    #    this command, else the session root), never the session alone.
    if target_armed "$_kill_cd"; then
      for ((_ki = 0; _ki < _kn; _ki++)); do
        _kt="${_ktoks[$_ki]}"
        case "$_kt" in
          '>'|'>>'|[0-9]'>'|[0-9]'>>'|'&>'|'&>>'|'>|')
            if [ $((_ki + 1)) -lt "$_kn" ]; then
              _kg_check_path "${_ktoks[$((_ki + 1))]}" "a shell redirect"
            fi ;;
          *'>'*)
            _krest="${_kt#*>}"; _krest="${_krest#>}"
            [ -n "$_krest" ] && _kg_check_path "$_krest" "a shell redirect" ;;
        esac
      done
    fi

    # 2) identify the head command, skipping env assignments / benign wrappers
    #    (same stripping shape as check_tokens below).
    _ki=0
    while [ "$_ki" -lt "$_kn" ]; do
      case "${_ktoks[$_ki]}" in
        [A-Za-z_]*=*) _ki=$((_ki + 1)) ;;
        sudo|doas|nohup|command|builtin|exec|time|nice|ionice|env) _ki=$((_ki + 1)) ;;
        *) break ;;
      esac
    done
    [ "$_ki" -lt "$_kn" ] || continue
    _khead="${_ktoks[$_ki]##*/}"
    _ki=$((_ki + 1))

    case "$_khead" in
      cd)
        # D3 (round-2 reviewer): resolve the cd token to an absolute,
        # normalized effective directory immediately, joined against the
        # PRIOR _kill_cd (not always the session cwd) — see qx_resolve_cd
        # above deny-guard's armed-only gate. A second `cd` in the same
        # command (`cd .quetrex; cd ..`) now composes correctly.
        [ "$_ki" -lt "$_kn" ] && _kill_cd=$(qx_resolve_cd "${_ktoks[$_ki]}" "$_kill_cd")
        continue ;;
    esac

    case "$_khead" in
      rm|unlink|truncate|tee|mv|cp|chmod)
        target_armed "$_kill_cd" || continue
        for ((_kj = _ki; _kj < _kn; _kj++)); do
          case "${_ktoks[$_kj]}" in -*) continue ;; esac
          _kg_check_path "${_ktoks[$_kj]}" "$_khead"
        done ;;
      find)
        # C2 hygiene (round-2 reviewer): `find .quetrex -name project.json
        # -delete` names no protected path as a literal ARGUMENT the way
        # rm/mv do — the search ROOT and the `-name` PATTERN are separate
        # tokens. Collect the first non-flag token as the search root and
        # any -name/-iname value; if -delete appears, check the root alone
        # (catches `find .quetrex ... -delete` outright — .quetrex ITSELF
        # is a protected shape) and root+name joined (catches a root other
        # than .quetrex whose -name value would still resolve onto it).
        target_armed "$_kill_cd" || continue
        _kfind_root=""; _kfind_root_seen=0; _kfind_name=""; _kfind_delete=0
        for ((_kj = _ki; _kj < _kn; _kj++)); do
          _kt="${_ktoks[$_kj]}"
          case "$_kt" in
            -delete) _kfind_delete=1 ;;
            -name|-iname)
              _kj=$((_kj + 1))
              [ "$_kj" -lt "$_kn" ] && _kfind_name="${_ktoks[$_kj]}" ;;
            -*) : ;;
            *) [ "$_kfind_root_seen" -eq 0 ] && { _kfind_root="$_kt"; _kfind_root_seen=1; } ;;
          esac
        done
        if [ "$_kfind_delete" -eq 1 ]; then
          [ -n "$_kfind_root" ] && _kg_check_path "$_kfind_root" "find -delete"
          [ -n "$_kfind_name" ] && _kg_check_path "${_kfind_root:+$_kfind_root/}$_kfind_name" "find -delete"
        fi ;;
      git)
        _kgitdir=""; _kworktree=""
        while [ "$_ki" -lt "$_kn" ]; do
          case "${_ktoks[$_ki]}" in
            -C) _kgitdir="${_ktoks[$((_ki + 1))]:-}"; _ki=$((_ki + 2)) ;;
            --git-dir=*) _kgitdir="${_ktoks[$_ki]#--git-dir=}"; _ki=$((_ki + 1)) ;;
            # D2 (round-2 reviewer): the SPACE-separated forms used to only
            # be SKIPPED (2 tokens consumed, value discarded) — captured now,
            # same as the `=`-joined forms.
            --git-dir) _kgitdir="${_ktoks[$((_ki + 1))]:-}"; _ki=$((_ki + 2)) ;;
            --work-tree=*) _kworktree="${_ktoks[$_ki]#--work-tree=}"; _ki=$((_ki + 1)) ;;
            --work-tree) _kworktree="${_ktoks[$((_ki + 1))]:-}"; _ki=$((_ki + 2)) ;;
            -c|--namespace|--exec-path) _ki=$((_ki + 2)) ;;
            -*) _ki=$((_ki + 1)) ;;
            *) break ;;
          esac
        done
        [ "$_ki" -lt "$_kn" ] || continue
        # D2: --work-tree, when given, NAMES the work tree directly and is
        # authoritative over --git-dir (which may point at a bare .git dir
        # elsewhere entirely). D3: anchor the (possibly still-relative)
        # explicit dir against _kill_cd, never unconditionally the session
        # cwd — resolve_root_for's anchor-override param carries that.
        target_armed "${_kworktree:-${_kgitdir:-$_kill_cd}}" "$_kill_cd" || continue
        _ksub="${_ktoks[$_ki]}"; _ki=$((_ki + 1))
        case "$_ksub" in
          rm)
            for ((_kj = _ki; _kj < _kn; _kj++)); do
              case "${_ktoks[$_kj]}" in -*) continue ;; esac
              _kg_check_path "${_ktoks[$_kj]}" "git rm"
            done ;;
          checkout|restore)
            _kdd=0
            for ((_kj = _ki; _kj < _kn; _kj++)); do
              if [ "${_ktoks[$_kj]}" = "--" ]; then _kdd=1; continue; fi
              [ "$_kdd" -eq 1 ] && _kg_check_path "${_ktoks[$_kj]}" "git $_ksub"
            done ;;
        esac ;;
    esac
  done <<< "$(split_segments "$_kcmd")"
}

# SCOPED UNLOCK (2026-08-26): this used to be a blanket bypass
# (`if [ "$QUETREX_UNLOCK_FLOOR" != "1" ]; then ... fi`) that skipped the
# whole kill-switch scan whenever ANY value happened to be in the
# environment. The scan now always runs; each protected target is judged
# individually, inside _kg_check_path, against dg_is_unlocked_for() -- see
# the SEC-ONECOPY-1 comment above check_quetrex_killswitch's definition.
check_quetrex_killswitch "$cmd"

# --- long-option PREFIX matching -------------------------------------------
# opt_is <arg> <full-long-option> — true when <arg> is `--` plus a non-empty
# PREFIX of <full-long-option>, i.e. exactly the set of spellings git's
# parse-options resolves to that option. `--de`, `--del`, `--dele`, `--delet`
# and `--delete` all satisfy opt_is "$a" --delete. Any `=value` suffix is cut
# first, so `--force=x` is still --force. The candidate is used QUOTED as a
# case pattern, so a `*` or `?` inside attacker text is matched literally and
# cannot widen the comparison.
opt_is() {
  _oi_a="${1%%=*}"
  case "$_oi_a" in --?*) : ;; *) return 1 ;; esac
  case "$2" in "$_oi_a"*) return 0 ;; esac
  return 1
}

# --- rm ---------------------------------------------------------------------
check_rm() {
  # C5: gate on the TARGET repo's arming — the last `cd` seen earlier in
  # this same command, else the session root. A bare `rm` has no `-C`
  # equivalent of its own.
  target_armed "$LAST_CD" || return 0
  shift                      # drop 'rm'
  recursive=0
  paths=""
  for a in "$@"; do
    case "$a" in
      -R|-r) recursive=1 ;;
      # GNU rm goes through getopt_long, which abbreviates too: `rm --r -f /`
      # is a recursive delete of /.
      --*) opt_is "$a" --recursive && recursive=1 ;;
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

# The ref a refspec UPDATES is its DESTINATION — everything after the colon.
#   +src:dst              -> dst        (`+main:main`, `+HEAD:main`)
#   +ref                  -> ref        (`+main`, src and dst are the same name)
#   +refs/heads/*:refs/heads/*  -> refs/heads/*   (a wildcard is not a name the
#                                 carve-out can clear, so it fails CLOSED)
# A ref name cannot contain a colon, so the first colon is the only colon.
refspec_dst() {
  d="${1#+}"
  case "$d" in
    *:*) d="${d#*:}" ;;
  esac
  printf '%s' "$d"
}

check_git() {
  shift                      # drop 'git'
  # skip git's own global options so `git -C /worktree push --force` is seen
  # — capturing -C (and --git-dir=) specifically, mirroring enforce-branch.sh
  # (C5): a `-C <dir>` (or `--git-dir=<dir>`) NAMES this invocation's target,
  # and that target — not the session's own repo — is what governs arming.
  gitdir=""; worktree=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -C)
        if [ "$#" -ge 2 ]; then gitdir="$2"; shift 2; else return 0; fi ;;
      --git-dir=*) gitdir="${1#--git-dir=}"; shift ;;
      # D2 (round-2 reviewer): the SPACE-separated forms used to only be
      # SKIPPED (2 args consumed, value discarded) — captured now, same as
      # the `=`-joined forms.
      --git-dir)
        if [ "$#" -ge 2 ]; then gitdir="$2"; shift 2; else return 0; fi ;;
      --work-tree=*) worktree="${1#--work-tree=}"; shift ;;
      --work-tree)
        if [ "$#" -ge 2 ]; then worktree="$2"; shift 2; else return 0; fi ;;
      -c|--namespace|--exec-path)
        if [ "$#" -ge 2 ]; then shift 2; else return 0; fi ;;
      -*) shift ;;
      *) break ;;
    esac
  done
  [ "$#" -gt 0 ] || return 0
  # C5: gate on the TARGET repo's arming — this invocation's own -C/
  # --git-dir/--work-tree, else the last `cd` seen earlier in this same
  # command, else the session root. D2: --work-tree, when given, NAMES the
  # work tree directly and is authoritative over --git-dir (which may point
  # at a bare .git dir elsewhere entirely). D3: a still-relative explicit
  # dir is anchored against LAST_CD (resolve_root_for's default), never
  # unconditionally the session cwd — passed explicitly here for clarity.
  target_armed "${worktree:-${gitdir:-$LAST_CD}}" "$LAST_CD" || return 0
  sub="$1"; shift
  case "$sub" in
    reset)
      for a in "$@"; do
        # `--h`, `--ha`, `--har` are all `--hard` to git (measured, 2.54.0).
        opt_is "$a" --hard && deny "git reset --hard is blocked — stash or commit first."
      done
      ;;
    clean)
      for a in "$@"; do
        case "$a" in
          # `--f` is already `--force` to git clean (measured, 2.54.0).
          --*) opt_is "$a" --force && deny "git clean -f is blocked (irreversible)." ;;
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
          # standard post-rebase remedy. They are explicitly NOT blocked. Their
          # own abbreviations fall through the --* arm below and match nothing
          # destructive, so they stay allowed as well.
          --force-with-lease|--force-with-lease=*|--force-if-includes) : ;;
          --*)
            # PREFIX, never equality — see the header. `--del`/`--de` really
            # delete; `--m` really mirrors; `--pru` really prunes.
            if opt_is "$a" --delete; then
              delete=1
            elif opt_is "$a" --mirror; then
              deny "\`git push --mirror\` is blocked. It force-updates the remote to match this repo and DELETES every remote ref that is absent locally — the broadest ref deletion git offers, and one that names no ref for the disposable-namespace carve-out (quetrex-spec/*, *-gates) to clear. Push the specific refs you mean instead."
            elif opt_is "$a" --prune; then
              deny "\`git push --prune\` is blocked. It DELETES every remote ref the pushed refspec does not match, naming no ref for the disposable-namespace carve-out (quetrex-spec/*, *-gates) to clear. Push the specific refs you mean, and retire anything else through a PR + branch protection."
            elif opt_is "$a" --force; then
              deny "Unconditional force-push is blocked — use --force-with-lease, or a PR + branch protection."
            # options that take a SEPARATE value, so the value is never mistaken
            # for a remote or a refspec. Only the separated form consumes the
            # next argument: `--push-option=x` carries its own value.
            elif case "$a" in *=*) false ;; *) opt_is "$a" --push-option || opt_is "$a" --receive-pack || opt_is "$a" --exec || opt_is "$a" --repo ;; esac; then
              skip_next=1
            fi ;;
          -o) skip_next=1 ;;
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
      # FORCE BY REFSPEC. `+` is git's OTHER force syntax and it names no flag
      # at all, so every flag test above is blind to it. MEASURED against real
      # git and a real bare remote, remote main = A->B, local `rewrite` = A->C:
      #   git push origin  rewrite:main  -> ! [rejected] rewrite -> main
      #                                     (non-fast-forward), exit 1
      #   git push origin +rewrite:main  ->  + 43ca87a...9dac8d5 rewrite -> main
      #                                     (forced update), exit 0
      # and B was no longer an ancestor of the remote main — history destroyed
      # by a command carrying no --force anywhere. `+refs/heads/*:refs/heads/*`
      # does it to every branch at once.
      #
      # There is no safe-form carve-out to preserve here: --force-with-lease has
      # no refspec equivalent, so `+` is ALWAYS the unconditional force. The
      # only carve-out is the same one the delete arm gets, judged the same way
      # — on the ref itself, via disposable_ref() — because quetrex-spec/* and
      # *-gates are republished by construction. A dst the guard cannot resolve
      # (a wildcard, an unexpanded $VAR) is NOT disposable and fails closed.
      for p in $pos_first $pos_rest; do
        case "$p" in
          +:*) : ;;             # force-delete: already judged by the loop above
          +*)
            fdst=$(refspec_dst "$p")
            disposable_ref "$fdst" || deny "Force-updating the remote ref '$fdst' is blocked. A leading \`+\` on a refspec ('$p') IS a force-push — git reports it as '(forced update)' and it overwrites the remote exactly as \`--force\` does, with no --force flag present. Unconditional force-push is blocked — use --force-with-lease (which has no refspec form, so drop the \`+\` and pass the flag), or a PR + branch protection. Only the pipeline's disposable namespaces may be force-updated this way: quetrex-spec/* and *-gates." ;;
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
    # C5: track the most recent `cd` target for this command, mirroring
    # enforce-branch.sh's LAST_CD — a later `rm`/`git` (no -C of its own)
    # in a LATER segment of the SAME command is judged against it.
    # D3 (round-2 reviewer): resolve to an absolute, normalized effective
    # directory immediately, joined against the PRIOR LAST_CD (not always
    # the session cwd) — see qx_resolve_cd. A second `cd` in the same
    # command now composes correctly instead of each one being judged
    # against the ORIGINAL session cwd independently.
    cd) [ "$#" -ge 2 ] && LAST_CD=$(qx_resolve_cd "$2" "$LAST_CD") ;;
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

PIPE_TO_SHELL=0

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
# C5: gated on target_armed(LAST_CD) — the directory context established by
# the PARSED portion of this command (a `cd` before the `| bash`), else the
# session root. The piped text itself carries no -C/cd syntax of its own to
# resolve a target from, so this is the best available signal, same as
# every other rule in this file.
if [ "$PIPE_TO_SHELL" -eq 1 ] && target_armed "$LAST_CD"; then
  c=" $(printf '%s' "$cmd" | tr -s '[:space:]' ' ') "
  # EVERY RULE BELOW IS DECIDED ON PARSED TOKENS, NOT ON THE COMMAND TEXT.
  #
  # The force, reset and clean arms used to be `case "$c" in *"push --force"*`
  # style substring tests over the whole flattened string, which is this repo's
  # known failure class and the same one the delete arm was already converted
  # away from. Measured against this hook before the change:
  #   ALLOW  echo 'git push origin --force main' | bash
  #             — the substring test needed `push` and `--force` ADJACENT, and
  #               the remote sits between them in perfectly ordinary git
  #   ALLOW  echo 'git push --force origin main # --force-with-lease' | bash
  #             — the safe-form carve-out was judged on the WHOLE TEXT, so
  #               naming the safe form in a COMMENT disabled the force backstop
  #   ALLOW  echo 'git push --fo origin main' | bash
  #   ALLOW  echo 'git reset --har' | bash
  #   ALLOW  echo 'git clean --force' | bash
  #             — no abbreviation handling at all, while the PARSED path gets
  #               all three right via opt_is (see the header: an unambiguous
  #               prefix IS the option to git)
  #   ALLOW  echo 'git push origin +main:main' | bash
  #             — the refspec force form, unguarded here as well
  # So the token loop below carries the force/reset/clean decisions too: the
  # safe-form exemption is applied PER TOKEN (a comment can never reach it,
  # because `#` ends the command), long options go through opt_is exactly as
  # the parsed path does, and a `+` refspec is judged on its destination ref.
  #
  # Ref DELETION, same backstop.
  #
  # THE CARVE-OUT IS EVALUATED AGAINST THE REF, NEVER AGAINST THE COMMAND TEXT
  # (finding f2). This arm used to read `case "$c" in *"quetrex-spec/"*|*"-gates"*) : ;;`
  # BEFORE looking at the push at all, so any occurrence of either namespace
  # ANYWHERE in the flattened text disabled the whole backstop:
  #   echo 'git push origin --delete trunk # see quetrex-spec/notes' | bash
  #   echo 'git push origin --delete trunk' | bash # my-gates
  # both ran. That is this repo's known failure class — matching command TEXT
  # rather than the actual invocation. So tokenise the text, collect the refs
  # the push would actually remove, and hand each one to the same
  # disposable_ref() predicate the parsed path uses. A delete that names no ref
  # the guard can resolve fails CLOSED.
  bs_push=0; bs_del=0; bs_seen=0; bs_first=""; bs_rest=""
  bs_reset=0; bs_clean=0
  BS_TARGETS=""; BS_COLON=""; BS_FORCE=""
  bs_flush() {
    if [ "$bs_del" -eq 1 ]; then
      if [ -n "$bs_rest" ]; then
        BS_TARGETS="$BS_TARGETS$bs_rest"
      elif [ -n "$bs_first" ]; then
        # A delete naming ONE positional is malformed git; inspect it rather
        # than assume it was a harmless remote name (same rule as check_git).
        BS_TARGETS="$BS_TARGETS $bs_first"
      else
        BS_TARGETS="$BS_TARGETS ?"   # names nothing resolvable: not clearable
      fi
    fi
    bs_push=0; bs_del=0; bs_seen=0; bs_first=""; bs_rest=""
    bs_reset=0; bs_clean=0
  }
  set -f                     # no globbing while word-splitting the text
  for tok in $c; do
    tok="${tok//\"/}"; tok="${tok//\'/}"   # quotes are noise once flattened
    case "$tok" in
      '#'*) break ;;                        # a comment ends the command
      *'|'*|*';'*|*'&'*) bs_flush; continue ;;
    esac
    # Which git subcommand are we inside? Latched independently, so a segment
    # that runs several (`git push origin main && git clean -f`) is judged on
    # each of them — the old whole-text scan caught those and this must not
    # narrow that.
    case "$tok" in
      push|git-push)   bs_push=1;  continue ;;
      reset|git-reset) bs_reset=1; continue ;;
      clean|git-clean) bs_clean=1; continue ;;
    esac
    # `--h`, `--ha`, `--har` are all `--hard` to git — the same opt_is the
    # parsed path uses, instead of a `*"reset --hard"*` substring test.
    if [ "$bs_reset" -eq 1 ]; then
      opt_is "$tok" --hard && deny "git reset --hard is blocked — stash or commit first. This text is piped into a shell, so it really is about to run."
    fi
    # `--f` is already `--force` to git clean, and the long form was missing
    # from the old short-flag-only substring list entirely.
    if [ "$bs_clean" -eq 1 ]; then
      case "$tok" in
        --*) opt_is "$tok" --force && deny "git clean -f is blocked (irreversible). This text is piped into a shell, so it really is about to run." ;;
        -*)  case "$tok" in *f*) deny "git clean -f is blocked (irreversible). This text is piped into a shell, so it really is about to run." ;; esac ;;
      esac
    fi
    [ "$bs_push" -eq 1 ] || continue
    case "$tok" in
      # The SAFE forms, exempted PER TOKEN. Judged here the token cannot be a
      # comment (`#` broke the loop above) and cannot be an unrelated word
      # elsewhere in the line — which is exactly how the old whole-text
      # carve-out was disabled by `# --force-with-lease`.
      --force-with-lease|--force-with-lease=*|--force-if-includes) : ;;
      --*)
        if opt_is "$tok" --delete; then
          bs_del=1
        elif opt_is "$tok" --mirror; then
          deny "\`git push --mirror\` is blocked. This text is piped into a shell, so it really is about to run: --mirror DELETES every remote ref that is absent locally, and names no ref for the disposable-namespace carve-out (quetrex-spec/*, *-gates) to clear."
        elif opt_is "$tok" --prune; then
          deny "\`git push --prune\` is blocked. This text is piped into a shell, so it really is about to run: --prune DELETES every remote ref the pushed refspec does not match, and names no ref for the disposable-namespace carve-out (quetrex-spec/*, *-gates) to clear."
        elif opt_is "$tok" --force; then
          deny "Unconditional force-push is blocked — use --force-with-lease, or a PR + branch protection. This text is piped into a shell, so it really is about to run."
        fi ;;
      -*) case "$tok" in *f*) deny "Unconditional force-push is blocked — use --force-with-lease, or a PR + branch protection. This text is piped into a shell, so it really is about to run." ;; esac
          case "$tok" in *d*) bs_del=1 ;; esac ;;
      :*|+:*) BS_COLON="$BS_COLON $tok" ;;
      # a leading + IS a force-push and names no flag — see check_git's push arm
      +*) BS_FORCE="$BS_FORCE $tok" ;;
      # a redirection is not a refspec — git refuses < and > in a ref name
      *'>'*|*'<'*) : ;;
      *) if [ "$bs_seen" -eq 0 ]; then bs_seen=1; bs_first="$tok"; else bs_rest="$bs_rest $tok"; fi ;;
    esac
  done
  bs_flush
  for p in $BS_COLON; do
    disposable_ref "$p" || deny "Deleting the remote ref '$p' is blocked. This text is piped into a shell, so it really is about to run: \`git push <remote> :<ref>\` is a ref DELETION. Only quetrex-spec/* and *-gates may be deleted this way."
  done
  for p in $BS_FORCE; do
    fdst=$(refspec_dst "$p")
    disposable_ref "$fdst" || deny "Force-updating the remote ref '$fdst' is blocked. This text is piped into a shell, so it really is about to run: a leading \`+\` on a refspec ('$p') IS a force-push — git reports '(forced update)' and it overwrites the remote exactly as \`--force\` does, with no --force flag present. Only quetrex-spec/* and *-gates may be force-updated this way."
  done
  for p in $BS_TARGETS; do
    disposable_ref "$p" || deny "Deleting the remote ref '$p' is blocked. This text is piped into a shell, so it really is about to run: \`git push --delete <ref>\` removes the branch outright, which is strictly less recoverable than the force-push this guard already denies. Only quetrex-spec/* and *-gates may be deleted this way — and that carve-out is judged on the REF, so naming either namespace elsewhere in the command (a comment, a path) does not clear it."
  done
  set +f
fi

exit 0
