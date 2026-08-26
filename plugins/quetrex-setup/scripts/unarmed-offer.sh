#!/usr/bin/env bash
# unarmed-offer.sh — SessionStart hook (quetrex-setup; sources: startup, resume,
# compact). The ONE line offered to the operator of a repo that has never run
# /quetrex-setup:init.
#
# WHY THIS SHIPS HERE, NOT IN `quetrex`. quetrex-setup is enabled MACHINE-WIDE
# (every repo, every session) so the operator always has /quetrex-setup:login,
# :init and :update available. `quetrex` (the pipeline command layer) is
# enabled only PER REPO by :init — an unarmed repo therefore never loads
# `quetrex` at all, and this is the only place left that can tell the operator
# an unarmed repo exists. It must stay a single, cheap, silent-by-default line:
# it runs on EVERY SessionStart in EVERY repo on the machine.
#
# CONTRACT (mirrors .claude/hooks/session-state.sh's, which now owns only the
# ARMED half of this same decision):
#   * SessionStart ignores blocking entirely — this hook always exits 0.
#   * ARMED repo (.quetrex/project.json present) -> 0 bytes. session-state.sh
#     (shipped in `quetrex`, loaded only once armed) covers that repo instead.
#   * Not a git repo at all -> 0 bytes. There is nothing to offer to arm.
#   * UNARMED git repo -> exactly the one line below, on every source
#     (startup/resume/compact — this hook fires once per source, never per
#     turn, so that is not a spam concern).
#
# CANNOT SOURCE THE SHARED ARMING-PREDICATE HELPER that quetrex-factory ships
# (plugins/quetrex-factory/scripts/qx-armed.sh). session-state.sh's copy of
# this predicate sources that helper via a path two levels up — which
# resolves only because the `quetrex` plugin bundles the WHOLE repo tree for
# its own agent manifest. quetrex-setup's installed cache root has no such
# sibling tree (a git-subdir install pulls in only plugins/quetrex-setup/), so
# that relative path does not exist here. The predicate is therefore
# REIMPLEMENTED INLINE, and (REV-GLOBAL-2) it must carry ALL THREE of
# qx-armed.sh's independent signals, not just the cheapest one — a repo
# where .quetrex/project.json was committed and then deleted from the
# working tree only (SEC-ONECOPY-1's exact class) is still ARMED by the
# shared helper, and this copy must agree:
#   (1) the WORKING-TREE file .quetrex/project.json exists.
#   (2) .quetrex/project.json is tracked at HEAD
#       (`git cat-file -e HEAD:.quetrex/project.json`).
#   (3) .quetrex/project.json is tracked at the default branch tip — the
#       SAME candidate order qx-armed.sh tries: refs/remotes/origin/HEAD,
#       origin/main, origin/master, main, master; the first ref that
#       resolves wins and only that one ref is inspected.
# AC12 is the no-loss floor for this: both implementations are required to
# agree on a fixture matrix (armed, unarmed, .quetrex/ present with no
# project.json, non-git directory, linked worktree of an armed repo, and —
# added for REV-GLOBAL-2 — committed-then-working-tree-deleted) so this copy
# can never silently drift from the shared helper it cannot reach.
set -uo pipefail

qx_repo_armed() {
  local root="${1:-}"
  [ -n "$root" ] || return 1

  # (1) working-tree file — cheapest check, tried first.
  [ -f "$root/.quetrex/project.json" ] && return 0

  # (2) tracked at HEAD.
  git -C "$root" cat-file -e 'HEAD:.quetrex/project.json' >/dev/null 2>&1 && return 0

  # (3) tracked at the default branch tip — first candidate ref that
  # resolves wins; only that one ref is inspected for project.json. Same
  # order as qx-armed.sh's qx_repo_armed.
  local ref="" cand
  for cand in refs/remotes/origin/HEAD origin/main origin/master main master; do
    if git -C "$root" rev-parse --verify --quiet "$cand" >/dev/null 2>&1; then
      ref="$cand"
      break
    fi
  done
  if [ -n "$ref" ]; then
    git -C "$root" cat-file -e "${ref}:.quetrex/project.json" >/dev/null 2>&1 && return 0
  fi

  return 1
}

INPUT=""
if [ ! -t 0 ]; then INPUT=$(cat); fi

HAVE_JQ=0
command -v jq >/dev/null 2>&1 && HAVE_JQ=1

jqget() {
  [ "$HAVE_JQ" -eq 1 ] || return 0
  printf '%s' "$INPUT" | jq -r "$1 // empty" 2>/dev/null
}

# The source may be passed as an ARGUMENT by the settings registration or read
# from the hook payload — the argument wins so one script serves every
# registered source even where the payload is unavailable or jq is absent.
SOURCE="${1:-}"
[ -z "$SOURCE" ] && SOURCE=$(jqget '.source')
SESSION_CWD=$(jqget '.cwd')
[ -z "$SESSION_CWD" ] && SESSION_CWD=$(printf '%s' "$INPUT" | tr -d '\n' | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

# --- resolve repo root (worktree-safe; mirrors session-state.sh / verify-gate.sh)
ROOT=""
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "${CLAUDE_PROJECT_DIR:-}" ]; then
  ROOT=$(git -C "$CLAUDE_PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null) \
    || ROOT="$CLAUDE_PROJECT_DIR"
fi
if [ -z "$ROOT" ] && [ -n "$SESSION_CWD" ] && [ -d "$SESSION_CWD" ]; then
  ROOT=$(git -C "$SESSION_CWD" rev-parse --show-toplevel 2>/dev/null)
fi
[ -z "$ROOT" ] && ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
# Not a git repo at all (no CLAUDE_PROJECT_DIR/cwd/cwd-fallback resolved a
# toplevel) -> nothing to offer. This is what keeps case (c) of AC9 at 0 bytes.
[ -n "$ROOT" ] && [ -d "$ROOT" ] || exit 0

if ! qx_repo_armed "$ROOT"; then
  printf '%s\n' "Quetrex: this repo is not armed (no .quetrex/project.json). Offer the user /quetrex-setup:init; if they say yes, run it."
fi
exit 0
