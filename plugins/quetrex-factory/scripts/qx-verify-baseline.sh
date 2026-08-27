#!/usr/bin/env bash
# qx-verify-baseline.sh — PRE-EXISTING RED baseline + green ratchet.
#
# SOURCED ONLY, by plugins/quetrex-factory/scripts/verify-gate.sh. Never run
# directly and never registered as a hook.
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS (measured 2026-08-27, QDM-14).
#
# verify-gate.sh runs the chain on every Stop and SubagentStop with no skip
# path. On a greenfield task the first chain command cannot exist until a
# developer writes the script that defines it, so the gate blocked turn 1,
# blocked turn 2, hit its self-heal cap on turn 3 and wrote .quetrex/ESCALATION
# — killing the build before the architect finished. The gate could not tell
# "the agent broke it" from "the code does not exist yet".
#
# This helper answers exactly that question, by MEASUREMENT rather than by
# pattern-matching a command's output (which the gate's header rightly bans as
# error laundering): it re-runs the failing command against the BASE of the
# current work and reports whether it was already failing there.
#
# ---------------------------------------------------------------------------
# WHAT CAN AND CANNOT COME OF A WRONG ANSWER.
#
# A pre-existing verdict changes ONE thing: whether the agent is allowed to
# END ITS TURN. It never changes what may ship. The ledger line written for a
# pre-existing red carries the command's REAL non-zero exit and
# `preexisting:true` — it is not a green — and merge-gate.sh GATE 3 still
# refuses any merge without a green FULL-chain ledger pinned to HEAD. So even
# a completely forged .quetrex/verify-baseline.json merges nothing. That
# asymmetry is the whole safety argument for this file; preserve it in any
# change here.
#
# THE RATCHET closes the obvious drift: the moment a command is observed
# exiting 0 in this repo it is recorded in `greenSince` and is NEVER treated
# as pre-existing again, whatever the base says. Work may start on red
# tooling; it may not quietly go back to red once it has been proven.
#
# ---------------------------------------------------------------------------
# KNOWN, ACCEPTED RESIDUAL (documented, not hidden). The base run happens in a
# detached worktree at the base commit, with the repo's top-level GIT-IGNORED
# entries symlinked in (node_modules, .env*, build caches — the same problem
# .worktreeinclude exists to solve). If a command nevertheless fails at base
# for an environmental reason that does NOT apply to the current tree, a
# genuine regression could be recorded as pre-existing. The consequence is
# bounded to "the agent gets to finish its turn"; the merge boundary is
# unaffected, and the report line names the base sha so a human can see what
# was measured.

# qx_baseline_init <root> <qdir> <head_sha>
#   Resolves the base of the current work. Sets:
#     QXB_MODE      branch | none
#     QXB_BASE_SHA  the commit failures are measured against ('' when none)
#     QXB_BASE_DESC human-readable description for the report line
#   MODE none means "no usable baseline" — the caller must behave exactly as
#   it did before this file existed (fail closed).
qx_baseline_init() {
  QXB_ROOT="$1"; QXB_QDIR="$2"; QXB_HEAD_SHA="${3:-}"
  QXB_MODE="none"; QXB_BASE_SHA=""; QXB_BASE_DESC=""
  QXB_FILE="$QXB_QDIR/verify-baseline.json"
  QXB_WT=""           # lazily created base worktree
  QXB_WT_TRIED=0
  # Initialised here, unconditionally, and NOT only on the paths that call
  # qxb__load_cache. verify-gate.sh runs under `set -u`: leaving these unbound
  # on the MODE=none path made the first qxb__has_line reference kill the hook
  # outright — and a dead hook emits no block JSON, which the runtime reads as
  # ALLOW. A fail-open, produced by the very guard meant to fail closed.
  # Measured by AC5 of test/verify-gate-baseline-ratchet.test.sh.
  QXB_GREEN=""; QXB_PRE=""

  # A repo with no resolvable HEAD has no base to measure against.
  case "$QXB_HEAD_SHA" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) : ;;
    *) return 0 ;;
  esac

  local default_ref="" cur_branch mb
  # The default branch, in descending order of authority. origin/HEAD is what
  # the remote itself says; the rest are the conventional fallbacks for a
  # fixture or a clone with no origin/HEAD set.
  default_ref="$(git -C "$QXB_ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
  if [ -z "$default_ref" ]; then
    local c
    for c in refs/remotes/origin/main refs/remotes/origin/master refs/heads/main refs/heads/master; do
      if git -C "$QXB_ROOT" rev-parse -q --verify "$c" >/dev/null 2>&1; then
        default_ref="$c"; break
      fi
    done
  fi
  [ -n "$default_ref" ] || return 0

  cur_branch="$(git -C "$QXB_ROOT" branch --show-current 2>/dev/null)"
  mb="$(git -C "$QXB_ROOT" merge-base HEAD "$default_ref" 2>/dev/null)"

  if [ -n "$mb" ] && [ "$mb" != "$QXB_HEAD_SHA" ]; then
    # Ordinary case: work on a branch that diverged from the default branch.
    QXB_MODE="branch"; QXB_BASE_SHA="$mb"
    QXB_BASE_DESC="the base this branch diverged from (${mb:0:8})"
    qxb__load_cache
    return 0
  fi

  # HEAD is the default branch, or shares its tip: there is NO earlier base to
  # measure against, so no failure here can be shown to pre-date this session.
  # MODE stays "none" and verify-gate.sh behaves exactly as it did before this
  # file existed — fail closed.
  #
  # AN EARLIER DRAFT DID MORE HERE AND WAS WRONG. It added a "default-clean"
  # mode: on the default branch with a clean tree, treat every red as
  # pre-existing on the grounds that the agent authored nothing. That is a
  # fail-OPEN, and test/verify-gate.test.sh caught it immediately — AC4(i),
  # AC4(ii), AC6(i..iii) and ADV-A/D/E/F/G/H/I are all fixtures that commit a
  # deliberately red chain on a clean main and REQUIRE a block. Several of them
  # exist specifically as anti-reintroduction controls for the
  # main-checkout-deferral fail-open (SEC-1, high) that was deleted outright in
  # 2026-08-21. Re-excusing red on main under a new name would have walked
  # straight back into it.
  #
  # The defect this file exists to fix is a BRANCH defect: a greenfield build
  # runs on claude/<TASK>, diverged from a base whose tooling does not exist
  # yet. That is covered above and needs nothing here.
  return 0
}

# --- cache -----------------------------------------------------------------
# {"base":"<sha>","preexisting":{"<cmd>":true|false},"greenSince":["<cmd>"]}
#
# `preexisting` is keyed to one base sha and is discarded when the base moves.
# `greenSince` is the RATCHET and survives every base change — dropping it
# would let a rebase re-open a command that has already been proven.
qxb__load_cache() {
  [ -f "$QXB_FILE" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  QXB_GREEN="$(jq -r '(.greenSince // []) | .[]' "$QXB_FILE" 2>/dev/null)"
  local cached_base
  cached_base="$(jq -r '.base // ""' "$QXB_FILE" 2>/dev/null)"
  [ "$cached_base" = "$QXB_BASE_SHA" ] || return 0
  QXB_PRE="$(jq -r '(.preexisting // {}) | to_entries[] | select(.value == true) | .key' "$QXB_FILE" 2>/dev/null)"
}

qxb__has_line() {  # qxb__has_line <haystack-newline-list> <needle>
  [ -n "$1" ] || return 1
  printf '%s\n' "$1" | grep -Fxq -- "$2"
}

qxb__save() {  # qxb__save <key: preexisting|greenSince> <cmd> [true|false]
  command -v jq >/dev/null 2>&1 || return 0
  local tmp cur
  cur="$QXB_FILE"
  [ -f "$cur" ] || printf '{}' > "$cur" 2>/dev/null || return 0
  tmp="$(mktemp "${TMPDIR:-/tmp}/qxb.XXXXXX" 2>/dev/null)" || return 0
  if [ "$1" = "greenSince" ]; then
    jq --arg c "$2" --arg b "$QXB_BASE_SHA" \
      '.base=$b | .greenSince=((.greenSince // []) + [$c] | unique)
       | .preexisting=((.preexisting // {}) | del(.[$c]))' \
      "$cur" > "$tmp" 2>/dev/null && cat "$tmp" > "$cur" 2>/dev/null
  else
    jq --arg c "$2" --arg b "$QXB_BASE_SHA" --argjson v "${3:-true}" \
      'if (.base // "") == $b then . else {base:$b, greenSince:(.greenSince // [])} end
       | .preexisting=((.preexisting // {}) + {($c): $v})' \
      "$cur" > "$tmp" 2>/dev/null && cat "$tmp" > "$cur" 2>/dev/null
  fi
  rm -f "$tmp" 2>/dev/null
}

# qx_baseline_mark_green <cmd>
#   Called for every command that exits 0. Arms the ratchet permanently.
qx_baseline_mark_green() {
  [ "$QXB_MODE" = "none" ] && return 0
  qxb__has_line "$QXB_GREEN" "$1" && return 0
  QXB_GREEN="${QXB_GREEN:+$QXB_GREEN
}$1"
  qxb__save greenSince "$1"
}

# qxb__base_worktree — materialize (once) a detached worktree at the base sha,
# with the repo's top-level git-ignored entries symlinked in so the base run
# sees the same environment as the live run.
#
# Sets the GLOBAL $QXB_WT and returns 0/1. It deliberately does NOT echo the
# path for a `$(...)` caller: command substitution runs in a subshell, so the
# assignments to QXB_WT / QXB_WT_TRIED would be discarded and every failing
# command would create — and leak — its own worktree.
qxb__base_worktree() {
  [ -n "$QXB_WT" ] && return 0
  [ "$QXB_WT_TRIED" -eq 1 ] && return 1
  QXB_WT_TRIED=1
  local wt
  wt="$(mktemp -d "${TMPDIR:-/tmp}/qx-baseline.XXXXXX" 2>/dev/null)" || return 1
  rmdir "$wt" 2>/dev/null
  git -C "$QXB_ROOT" worktree add --detach -q "$wt" "$QXB_BASE_SHA" >/dev/null 2>&1 || {
    rm -rf "$wt" 2>/dev/null; return 1; }

  # Symlink top-level ignored entries (node_modules, .env*, caches). Bounded to
  # the top level on purpose: it is enough to give the base run an environment,
  # and it cannot walk into a large tree.
  local e base
  for e in "$QXB_ROOT"/* "$QXB_ROOT"/.[!.]*; do
    [ -e "$e" ] || continue
    base="$(basename "$e")"
    case "$base" in .git|.quetrex) continue ;; esac
    [ -e "$wt/$base" ] && continue
    git -C "$QXB_ROOT" check-ignore -q "$base" 2>/dev/null || continue
    ln -s "$e" "$wt/$base" 2>/dev/null
  done

  QXB_WT="$wt"
  return 0
}

# qx_baseline_cleanup — remove the base worktree if one was created.
qx_baseline_cleanup() {
  [ -n "${QXB_WT:-}" ] || return 0
  git -C "$QXB_ROOT" worktree remove --force "$QXB_WT" >/dev/null 2>&1
  rm -rf "$QXB_WT" 2>/dev/null
  QXB_WT=""
}

# qx_baseline_is_preexisting <cmd> <cap-seconds>
#   0 -> this command was ALREADY failing at the base of the current work.
#   1 -> it was not (or cannot be shown to have been): the caller must treat
#        the failure as the agent's, exactly as before.
qx_baseline_is_preexisting() {
  local cmd="$1" cap="${2:-120}"

  # THE RATCHET, checked first and unconditionally. A command ever observed
  # green in this repo is never pre-existing again.
  qxb__has_line "$QXB_GREEN" "$cmd" && return 1

  [ "$QXB_MODE" = "none" ] && return 1

  # Cached verdict for this exact base.
  qxb__has_line "$QXB_PRE" "$cmd" && return 0

  # Measure it: run the command at the base commit.
  local wt code
  qxb__base_worktree || return 1
  wt="$QXB_WT"
  [ -n "$wt" ] && [ -d "$wt" ] || return 1

  local tmo=""
  if command -v timeout >/dev/null 2>&1; then tmo="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then tmo="gtimeout"; fi
  if [ -n "$tmo" ]; then
    ( cd "$wt" && "$tmo" -k 5 "${cap}s" bash -c "$cmd" ) >/dev/null 2>&1
    code=$?
  else
    ( cd "$wt" && bash -c "$cmd" ) >/dev/null 2>&1
    code=$?
  fi

  # A base run that was itself KILLED by the cap proves nothing either way —
  # fail closed and let the caller treat the failure as genuine.
  if [ "$code" -eq 124 ] || [ "$code" -eq 137 ]; then
    return 1
  fi

  if [ "$code" -ne 0 ]; then
    QXB_PRE="${QXB_PRE:+$QXB_PRE
}$cmd"
    qxb__save preexisting "$cmd" true
    return 0
  fi
  qxb__save preexisting "$cmd" false
  return 1
}
