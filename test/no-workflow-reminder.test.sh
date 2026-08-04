#!/usr/bin/env bash
# test/no-workflow-reminder.test.sh — proves the retired workflow-reminder
# UserPromptSubmit nudge is fully gone: the script file is deleted AND its
# registration in hooks/hooks.json is removed AND its injected text does not
# survive anywhere else in the tree.
#
# Run: bash test/no-workflow-reminder.test.sh
#
# WHY THIS EXISTS. workflow-reminder.sh injected a standing nudge to prefer
# the Workflow tool (local multi-agent orchestration) on every prompt —
# indefensible for a cloud-first product (see .claude/lib/cloud-build-routine.md
# / task-build.md rewrite). Removing a hook registration is a blocking-behavior
# change same as adding one, so it ships with a proving test: this one would
# fail (go RED) if the script file were restored, or if hooks.json ever
# re-registered a workflow-reminder command on UserPromptSubmit again.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS_JSON="$REPO_ROOT/hooks/hooks.json"
REMINDER_SCRIPT="$REPO_ROOT/.claude/hooks/workflow-reminder.sh"

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

# --- 1. the script file itself is deleted ------------------------------------
if [ ! -e "$REMINDER_SCRIPT" ]; then
  pass "workflow-reminder.sh no longer exists at .claude/hooks/workflow-reminder.sh"
else
  fail "workflow-reminder.sh still exists at $REMINDER_SCRIPT"
fi

# --- 2. hooks.json no longer mentions workflow-reminder at all ---------------
if [ -f "$HOOKS_JSON" ]; then
  HITS="$(grep -c 'workflow-reminder' "$HOOKS_JSON" 2>/dev/null || true)"
  HITS="${HITS:-0}"
  if [ "$HITS" -eq 0 ]; then
    pass "hooks/hooks.json contains zero references to workflow-reminder"
  else
    fail "hooks/hooks.json still references workflow-reminder ($HITS hit(s))"
  fi
else
  fail "hooks/hooks.json not found at $HOOKS_JSON"
fi

# --- 3. hooks.json still parses as valid JSON after the edit -----------------
if command -v node >/dev/null 2>&1; then
  if node -e "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'))" "$HOOKS_JSON" >/dev/null 2>&1; then
    pass "hooks/hooks.json parses as valid JSON"
  else
    fail "hooks/hooks.json does not parse as valid JSON"
  fi
else
  echo "SKIP: node not installed — cannot JSON-validate hooks.json"
fi

# --- 4. no UserPromptSubmit hook group registers a workflow-reminder command -
# Regression guard: this is the check that would go RED again if someone
# reintroduced a UserPromptSubmit registration of workflow-reminder.sh, even
# under a renamed key or reworded matcher.
if [ -f "$HOOKS_JSON" ] && command -v node >/dev/null 2>&1; then
  RESULT="$(node -e '
    const fs = require("fs");
    const h = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const groups = (h.hooks && h.hooks.UserPromptSubmit) || [];
    let found = false;
    for (const g of groups) {
      for (const hook of (g && g.hooks) || []) {
        if (hook && typeof hook.command === "string" && hook.command.includes("workflow-reminder")) {
          found = true;
        }
      }
    }
    process.stdout.write(found ? "FOUND" : "ABSENT");
  ' "$HOOKS_JSON")"
  if [ "$RESULT" = "ABSENT" ]; then
    pass "UserPromptSubmit registers no workflow-reminder command"
  else
    fail "UserPromptSubmit still registers a workflow-reminder command"
  fi
fi

# --- 5. the injected reminder text is absent from the tracked tree -----------
# Grep the injected text fragment repo-wide (git-tracked files only, so a
# throwaway local scratch file can't produce a false positive). Assembled from
# fragments, and this file itself is excluded from the sweep, so the needle
# describing what must be gone never triggers a self-match here.
if command -v git >/dev/null 2>&1; then
  NEEDLE="PREFER the Work""flow tool"
  HITS="$(cd "$REPO_ROOT" && git grep -I --no-color -F "$NEEDLE" -- . ':(exclude)test/no-workflow-reminder.test.sh' 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${HITS:-0}" -eq 0 ]; then
    pass "the injected reminder text is absent from the tracked tree"
  else
    fail "the injected reminder text still appears in the tracked tree"
  fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "no-workflow-reminder.test.sh: all checks passed"
  exit 0
else
  echo "no-workflow-reminder.test.sh: FAILURES above"
  exit 1
fi
