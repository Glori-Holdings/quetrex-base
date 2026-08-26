#!/usr/bin/env bash
# test/init-staging.test.sh — DEFECT 4, the silently-unarmed repo.
#
# Run: bash test/init-staging.test.sh
#
# WHAT HAPPENED (QDM-4, confirmed on the live repo). The cloud build reached its
# terminal stage and then STALLED, paging the operator on his phone to approve
# `gh pr create` — a step that is supposed to be fully automatic.
# Glori-Holdings/quetrex-demo's `.claude/settings.json` had no `permissions` key
# at all, even though `/quetrex-setup:init` step 4e computes exactly that union and
# init.md's own prose (`## 4e`) explains why the pipeline hangs without it.
#
# THE MECHANISM. init.md step 6 staged every arming artifact with
#     git -C "$REPO_ROOT" add <path> 2>/dev/null || true
# `2>/dev/null` throws the diagnostic away and `|| true` throws the exit code
# away, so `git add` failing stages NOTHING and init still reports success. The
# common trigger is a `.gitignore` that blanket-ignores a path init must commit
# (`.quetrex/*` is the documented case; a repo that gitignores local Claude
# settings is the settings.json case) — `git add` exits 1 with "The following
# paths are ignored by one of your .gitignore files" and the whole failure
# vanishes. A silently unarmed repo has NO gates at all, which is strictly worse
# than a visible error.
#
# WHAT IS ASSERTED. The step-6 staging block is extracted from the REAL
# init.md and EXECUTED against throwaway git fixtures — prose alone is what let
# this ship, so nothing here is a grep for intent.
#   AC4-ALLOW-1: a normal repo -> exit 0, and .quetrex/project.json AND
#                .claude/settings.json are actually in the index afterwards.
#   AC4-ALLOW-2: running it a second time on the same repo is still exit 0 (an
#                already-staged / unchanged path is a no-op, not an error) —
#                init must stay idempotent, so "fail loud" cannot be bought by
#                making the normal path brittle.
#   AC4-BLOCK-1: a repo whose .gitignore blanket-ignores `.quetrex/*` -> the
#                block exits NON-ZERO and names .quetrex/project.json.
#   AC4-BLOCK-2: a repo whose .gitignore ignores `.claude/settings.json` -> the
#                block exits NON-ZERO and names .claude/settings.json. This is
#                the exact QDM-4 shape: the permissions grant never lands and
#                the unattended pipeline hangs at `gh pr create`.
#   AC4-SRC:     no REQUIRED arming artifact is staged behind `|| true` any
#                more. Behavioural coverage above proves two paths; this proves
#                the whole set, so a third artifact cannot quietly keep the
#                swallow.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INIT_MD="$REPO_ROOT/plugins/quetrex-setup/commands/init.md"

if [ ! -f "$INIT_MD" ]; then
  echo "NOT OK - init.md not found at $INIT_MD"
  echo "init-staging.test.sh: FAILURES above"
  exit 1
fi
if ! command -v git >/dev/null 2>&1; then
  echo "SKIP: git not installed — the staging block cannot be executed"
  exit 0
fi

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qx-init-staging.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

STAGE_ANCHOR='Stage the arming artifacts — fail loud, never silently'
STAGE_BLOCK="$(awk -v anchor="$STAGE_ANCHOR" '
  !found && index($0, anchor) { found = 1; next }
  found && !infence && /^```bash/ { infence = 1; next }
  found && infence && /^```/ { exit }
  found && infence { print }
' "$INIT_MD")"

if [ -z "$STAGE_BLOCK" ]; then
  fail "setup: could not extract the step-6 staging block from $INIT_MD (anchor: '$STAGE_ANCHOR') — the staging step is not separately runnable, so nothing below can be proven by execution"
else
  pass "setup: extracted the step-6 staging block from init.md ($(printf '%s\n' "$STAGE_BLOCK" | wc -l | tr -d ' ') lines)"
fi

# mk_repo <dir> [gitignore-content]
mk_repo() {
  local d="$1" ign="${2:-}"
  mkdir -p "$d/.claude" "$d/.quetrex"
  git init --quiet "$d"
  git -C "$d" config user.name t
  git -C "$d" config user.email t@e
  echo "# fixture" > "$d/README.md"
  git -C "$d" add README.md
  git -C "$d" commit --quiet -m init
  printf '{"projectCode":"QDM","branchPrefix":"claude/"}\n' > "$d/.quetrex/project.json"
  printf '{"permissions":{"allow":["Bash(git push:*)","Bash(gh pr:*)"]}}\n' > "$d/.claude/settings.json"
  printf '# fixture\n\n## Verification\n\n```\nnpm test\n```\n' > "$d/.claude/CLAUDE.md"
  printf '{"verify":["npm test"]}\n' > "$d/.quetrex/verify.json"
  printf '.env\n' > "$d/.worktreeinclude"
  [ -n "$ign" ] && printf '%s\n' "$ign" > "$d/.gitignore"
  return 0
}

# run_stage <repo-dir> -> writes combined output to $WORK/out.txt, echoes exit code
run_stage() {
  local d="$1"
  (
    REPO_ROOT="$d"
    BRANCH_PREFIX="claude/"
    export REPO_ROOT BRANCH_PREFIX
    bash -c "$STAGE_BLOCK"
  ) > "$WORK/out.txt" 2>&1
  printf '%s' "$?"
}

if [ -n "$STAGE_BLOCK" ]; then
  # --- AC4-ALLOW-1 ----------------------------------------------------------
  R_OK="$WORK/repo-ok"
  mk_repo "$R_OK"
  RC_OK="$(run_stage "$R_OK")"
  STAGED_OK="$(git -C "$R_OK" diff --cached --name-only 2>/dev/null)"
  if [ "$RC_OK" = "0" ]; then
    pass "AC4-ALLOW-1: a normal repo stages cleanly (exit 0)"
  else
    fail "AC4-ALLOW-1: the staging block exited $RC_OK on a perfectly normal repo — fail-loud must not break the happy path. Output: [$(cat "$WORK/out.txt")]"
  fi
  MISSING_STAGED=""
  for want in .quetrex/project.json .claude/settings.json .claude/CLAUDE.md .quetrex/verify.json .worktreeinclude; do
    printf '%s\n' "$STAGED_OK" | grep -qxF "$want" || MISSING_STAGED="$MISSING_STAGED $want"
  done
  if [ -z "$MISSING_STAGED" ]; then
    pass "AC4-ALLOW-1: every arming artifact is actually in the index afterwards (project.json, settings.json, CLAUDE.md, verify.json, .worktreeinclude)"
  else
    fail "AC4-ALLOW-1: these arming artifacts were NOT staged:$MISSING_STAGED (index held: [$(printf '%s' "$STAGED_OK" | tr '\n' ' ')])"
  fi

  # --- AC4-ALLOW-2: idempotent re-run ---------------------------------------
  RC_OK2="$(run_stage "$R_OK")"
  if [ "$RC_OK2" = "0" ]; then
    pass "AC4-ALLOW-2: a second run over the same repo is still exit 0 — staging stays idempotent"
  else
    fail "AC4-ALLOW-2: the second run exited $RC_OK2 — an already-staged, unchanged path must be a no-op, not a failure. Output: [$(cat "$WORK/out.txt")]"
  fi

  # --- AC4-BLOCK-1: .quetrex/* blanket-ignored ------------------------------
  R_B1="$WORK/repo-quetrex-ignored"
  mk_repo "$R_B1" '.quetrex/*'
  RC_B1="$(run_stage "$R_B1")"
  OUT_B1="$(cat "$WORK/out.txt")"
  STAGED_B1="$(git -C "$R_B1" diff --cached --name-only 2>/dev/null)"
  if [ "$RC_B1" != "0" ]; then
    pass "AC4-BLOCK-1: a repo that blanket-ignores .quetrex/* makes the staging block exit $RC_B1 instead of reporting success over an empty index"
  else
    fail "AC4-BLOCK-1: the staging block exited 0 on a repo where the binding could not be staged (index held: [$(printf '%s' "$STAGED_B1" | tr '\n' ' ')]). init would report success and the repo would have NO gates. Output: [$OUT_B1]"
  fi
  if printf '%s' "$OUT_B1" | grep -qF '.quetrex/project.json' && printf '%s' "$OUT_B1" | grep -qF '/quetrex-setup:init'; then
    pass "AC4-BLOCK-1: the failure names the artifact (.quetrex/project.json) and the remediation (/quetrex-setup:init)"
  else
    fail "AC4-BLOCK-1: the failure output does not name both the artifact and the remediation — a loud failure nobody can act on is barely better than a silent one. Output: [$OUT_B1]"
  fi

  # --- AC4-BLOCK-2: .claude/settings.json ignored (the QDM-4 shape) ---------
  R_B2="$WORK/repo-settings-ignored"
  mk_repo "$R_B2" '.claude/settings.json'
  RC_B2="$(run_stage "$R_B2")"
  OUT_B2="$(cat "$WORK/out.txt")"
  if [ "$RC_B2" != "0" ] && printf '%s' "$OUT_B2" | grep -qF '.claude/settings.json'; then
    pass "AC4-BLOCK-2: a repo that cannot stage .claude/settings.json fails loudly and names it — the permissions grant can never go missing silently again"
  else
    fail "AC4-BLOCK-2: exit=$RC_B2 and the output does not name .claude/settings.json. This is the QDM-4 root cause: the permissions.allow grant never lands, and the unattended cloud build then stalls at 'gh pr create' waiting for a human. Output: [$OUT_B2]"
  fi
fi

# --- AC4-SRC: no required arming artifact is staged behind `|| true` --------
SWALLOWED=""
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  case "$hit" in
    *".quetrex/project.json"*|*".claude/settings.json"*|*".quetrex/verify.json"*|*".claude/CLAUDE.md"*|*".worktreeinclude"*)
      SWALLOWED="$SWALLOWED
    $hit" ;;
  esac
done <<SRCEOF
$(grep -n 'git .*add' "$INIT_MD" | grep -- '|| true' || true)
SRCEOF

if [ -z "$SWALLOWED" ]; then
  pass "AC4-SRC: no required arming artifact in init.md is staged behind '|| true'"
else
  fail "AC4-SRC: init.md still swallows the exit code when staging required arming artifact(s):$SWALLOWED
    Each of these can fail while init reports success, leaving the repo unarmed."
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "init-staging.test.sh: all checks passed"
  exit 0
else
  echo "init-staging.test.sh: FAILURES above"
  exit 1
fi
