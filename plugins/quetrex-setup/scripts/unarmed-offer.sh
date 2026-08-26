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
# (plugins/quetrex-factory/scripts/<the shared helper>.sh). session-state.sh's
# copy of this predicate sources that helper via a path two levels up — which
# resolves only because the `quetrex` plugin bundles the WHOLE repo tree for
# its own agent manifest. quetrex-setup's installed cache root has no such
# sibling tree (a git-subdir install pulls in only plugins/quetrex-setup/), so
# that relative path does not exist here. The one-line arming predicate is
# therefore reimplemented inline. AC12 is the no-loss floor for this: both
# implementations are required to agree on a 5-fixture matrix (armed, unarmed,
# .quetrex/ present with no project.json, non-git directory, linked worktree
# of an armed repo) so this copy can never silently drift from the shared
# helper it cannot reach.
set -uo pipefail

qx_repo_armed() { [ -n "${1:-}" ] && [ -f "$1/.quetrex/project.json" ]; }

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
