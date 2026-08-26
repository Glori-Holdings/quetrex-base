#!/bin/bash
# qx-armed.sh — the ONE shared arming predicate every floor script gates on
# (ONE-COPY round 2, design A). Sourced, never executed directly. Defines
# two functions:
#
#   qx_repo_armed <root>
#   qx_normalize_path <path>
#
# <root> should already be a resolved git toplevel (or empty/unresolved).
# Returns 0 (armed) or 1 (unarmed/unresolvable). Never prints, never exits
# the caller, never throws — every git call is silenced and its failure
# treated as "signal absent, keep checking the rest", so a missing git, a
# bare repo, a shallow clone, or a repo with zero commits all fail closed to
# "try the next signal", never to a stack trace or a hang.
#
# THREE INDEPENDENT SIGNALS. Any ONE of them arms the repo:
#   (1) the WORKING-TREE file .quetrex/project.json exists as a regular file
#       — the cheapest check, and the only signal a brand-new /quetrex-setup:init
#       (not yet committed) can produce.
#   (2) .quetrex/project.json is present in the committed tree at HEAD
#       (`git cat-file -e HEAD:.quetrex/project.json`) — so deleting the
#       WORKING-TREE copy of a file that is already committed does not, by
#       itself, disarm anything. This is what closes SEC-ONECOPY-1: `rm`,
#       `mv`, `truncate`, `python3 -c "import os; os.remove(...)"`,
#       `bash -c "rm ..."`, `find .quetrex -delete`, `printf >|`, `sed -i`,
#       `install`, `ln -sf /dev/null`, `dd`, `rsync`, a glob
#       (`.quetrex/*.json`, `.qu*`), or a path resolved relative to a `cd`
#       INTO `.quetrex` itself — every one of these only ever touches the
#       WORKING TREE, and none of them can make this signal go false once
#       project.json is committed.
#   (3) .quetrex/project.json is present at the tip of the repo's default
#       branch — tried in this order: refs/remotes/origin/HEAD, origin/main,
#       origin/master, main, master. The FIRST of these that resolves to a
#       real ref is treated as "the default branch tip", and ONLY that one
#       ref is inspected for project.json (a repo with no local `main` but a
#       resolvable `origin/main` is judged on origin/main; a repo with none
#       of the five falls back to signals (1)/(2) alone). This closes the
#       branch-local variant of the same hole: checking out a scratch branch,
#       `git rm`-ing project.json, and committing THERE never touches HEAD of
#       main and never touches the working tree of main.
#
# WHY NOT "enumerate every command shape that can remove one file" (the
# round-2-remediation instinct): SEC-ONECOPY-1 catalogued an open-ended list
# of shell idioms that reach the same working-tree file, and deny-guard's own
# _kg_check_path stays in place as a floor (belt-and-suspenders — it still
# actively DENIES the common shapes before they even run). But the fix that
# actually closes the CLASS is to stop every other floor script from
# depending solely on working-tree file state for its arming decision: once
# project.json is committed, no combination of commands run against the
# WORKING TREE can turn this predicate false for that repo — only an actual
# commit that removes it from HEAD (and, if pushed, from the default branch)
# can. That is a deliberate, disclosed narrowing of what "disarm" means: it
# becomes a real git operation with its own history, not an ephemeral
# one-liner with no trace.
# PERF-ONECOPY-2 (round 4 reviewer, Medium): deny-guard.sh calls
# target_armed() — which calls qx_repo_armed() — once per command
# segment/`cd`, so a multi-step command re-probes the SAME root repeatedly
# within one hook invocation. THE MEMOIZATION FOR THAT LIVES IN
# deny-guard.sh ITSELF (see its own _dg_qx_repo_armed_cached), not here:
# this predicate is a live, uncached probe of real filesystem/git state by
# design, and test/onecopy-armed-construction.test.sh sources this file
# directly and calls qx_repo_armed on the SAME root multiple times as it
# deliberately mutates that root's working tree and commits between calls
# (AC1 unarmed -> AC2 armed via working-tree file -> AC3 still-armed after
# deleting that file once committed) — caching here made AC2/AC3 return
# AC1's stale answer. A hook's OWN single invocation is safe to cache
# because nothing it inspects can change mid-invocation (a PreToolUse hook
# runs strictly before the tool it is judging executes anything), but this
# shared file has no such guarantee about its callers and must stay pure.
qx_repo_armed() {
  _qxa_root="$1"
  [ -n "$_qxa_root" ] || return 1

  # (1) working-tree file — cheapest check, tried first.
  [ -f "$_qxa_root/.quetrex/project.json" ] && return 0

  # (2) tracked at HEAD.
  git -C "$_qxa_root" cat-file -e 'HEAD:.quetrex/project.json' >/dev/null 2>&1 && return 0

  # (3) tracked at the default branch tip — first candidate ref that
  # resolves wins; only that one ref is inspected for project.json.
  _qxa_ref=""
  for _qxa_cand in refs/remotes/origin/HEAD origin/main origin/master main master; do
    if git -C "$_qxa_root" rev-parse --verify --quiet "$_qxa_cand" >/dev/null 2>&1; then
      _qxa_ref="$_qxa_cand"
      break
    fi
  done
  if [ -n "$_qxa_ref" ]; then
    git -C "$_qxa_root" cat-file -e "${_qxa_ref}:.quetrex/project.json" >/dev/null 2>&1 && return 0
  fi

  return 1
}

# qx_normalize_path <path> -- collapses "./" and "a/../b" SYNTACTICALLY (no
# filesystem access, no realpath dependency -- the target frequently does
# not exist yet). Moved here (round 2, reviewer C2) from
# .claude/hooks/protected-files-guard.sh, which defined it first (SEC-4,
# 2026-08-21) to close the same class of gap here: ".quetrex/./project.json"
# and ".quetrex//project.json" do not literally contain the exact suffix
# text deny-guard.sh's _kg_check_path matched, and previously slipped past
# unnormalized. ONE COPY: this is now the only definition; protected-files-
# guard.sh sources this file (see its own header) instead of carrying its
# own copy. bash 3.2-safe (no negative array indices -- this repo ships on
# macOS's stock /usr/bin/bash).
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
