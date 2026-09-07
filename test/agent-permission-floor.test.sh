#!/usr/bin/env bash
# test/agent-permission-floor.test.sh — QA-authored, independent of the
# developer's own suite. Pins QUE-P1/AC2: the four reasoning agents
# (architect, database-architect, reviewer, security-reviewer) run on
# `model: fable` + `effort: high`, and the two agents that write code
# unattended (developer, qa) run on `permissionMode: auto`, never
# `bypassPermissions`. No test in the shipped suite (plugin.test.js,
# floor-one-copy.test.sh, qa-wiring-independent.test.sh) asserts any of
# this frontmatter — a regression back to `bypassPermissions` on developer
# or qa, or back to `opus` on a reasoning agent, would ship with a fully
# green `npm test`. This is a security_surface item (permission-floor
# narrowing) per .quetrex/plan/QUE-P1.json, so it gets its own pin.
#
# FAIL-FIRST: the assertions below are run first against the pre-change
# agent files at the fixed baseline SHA this task branched from
# (7e69a624e9053a2f3589c1d677ef4228510630f7, NOT main) to prove they fail
# against the old shape before proving they pass against the new one.
#
# Run: bash test/agent-permission-floor.test.sh

set -uo pipefail

TOOLROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENTS_DIR="$TOOLROOT/plugins/quetrex-factory/agents"
BASELINE_SHA="7e69a624e9053a2f3589c1d677ef4228510630f7"

if ! command -v git >/dev/null 2>&1; then
  echo "SKIP: git not installed — the fail-first baseline is read via git show"
  exit 0
fi

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

REASONING_AGENTS="architect database-architect reviewer security-reviewer"
AUTO_AGENTS="developer qa"

# -----------------------------------------------------------------------------
# FAIL-FIRST: prove the pre-change baseline does NOT already satisfy these
# assertions, so a green run below is measuring a real change, not a
# tautology.
# -----------------------------------------------------------------------------
BASELINE_FABLE_COUNT=0
for agent in $REASONING_AGENTS; do
  content="$(git -C "$TOOLROOT" show "$BASELINE_SHA:plugins/quetrex-factory/agents/$agent.md" 2>/dev/null)"
  if printf '%s\n' "$content" | grep -qx 'model: fable'; then
    BASELINE_FABLE_COUNT=$((BASELINE_FABLE_COUNT + 1))
  fi
done
if [ "$BASELINE_FABLE_COUNT" -eq 0 ]; then
  pass "FAIL-FIRST: baseline $BASELINE_SHA has 0 of 4 reasoning agents on model: fable (this task's change is real)"
else
  fail "FAIL-FIRST: baseline $BASELINE_SHA already has $BASELINE_FABLE_COUNT reasoning agent(s) on model: fable — not a real prior state"
fi

BASELINE_BYPASS_COUNT=0
for agent in $AUTO_AGENTS; do
  content="$(git -C "$TOOLROOT" show "$BASELINE_SHA:plugins/quetrex-factory/agents/$agent.md" 2>/dev/null)"
  if printf '%s\n' "$content" | grep -q 'permissionMode: bypassPermissions'; then
    BASELINE_BYPASS_COUNT=$((BASELINE_BYPASS_COUNT + 1))
  fi
done
if [ "$BASELINE_BYPASS_COUNT" -eq 2 ]; then
  pass "FAIL-FIRST: baseline $BASELINE_SHA has both developer.md and qa.md on permissionMode: bypassPermissions (the floor this task narrows)"
else
  fail "FAIL-FIRST: baseline $BASELINE_SHA had $BASELINE_BYPASS_COUNT/2 agents on bypassPermissions — reproduction assumption wrong"
fi

# -----------------------------------------------------------------------------
# CURRENT STATE: the shipped agent files must carry the narrowed shape.
# -----------------------------------------------------------------------------
for agent in $REASONING_AGENTS; do
  f="$AGENTS_DIR/$agent.md"
  if [ ! -f "$f" ]; then
    fail "$agent.md not found at $f"
    continue
  fi
  m="$(grep -c '^model: fable$' "$f")"
  e="$(grep -c '^effort: high$' "$f")"
  if [ "$m" -eq 1 ] && [ "$e" -eq 1 ]; then
    pass "$agent.md: model: fable (x1) + effort: high (x1)"
  else
    fail "$agent.md: expected model:fable x1 + effort:high x1, got model:fable x$m, effort:high x$e"
  fi
  if grep -q '^model: opus$' "$f"; then
    fail "$agent.md: still declares model: opus"
  else
    pass "$agent.md: no model: opus line"
  fi
done

for agent in $AUTO_AGENTS; do
  f="$AGENTS_DIR/$agent.md"
  if [ ! -f "$f" ]; then
    fail "$agent.md not found at $f"
    continue
  fi
  a="$(grep -c '^permissionMode: auto$' "$f")"
  if [ "$a" -eq 1 ]; then
    pass "$agent.md: permissionMode: auto"
  else
    fail "$agent.md: expected exactly 1 'permissionMode: auto' line, got $a"
  fi
  if grep -q 'bypassPermissions' "$f"; then
    fail "$agent.md: still mentions bypassPermissions"
  else
    pass "$agent.md: no bypassPermissions mention"
  fi
done

# git-workflow.md is explicitly OUT of scope for this narrowing — it must
# keep its acceptEdits mode unchanged.
GW_FILE="$AGENTS_DIR/git-workflow.md"
if [ -f "$GW_FILE" ] && grep -q 'acceptEdits' "$GW_FILE"; then
  pass "git-workflow.md: acceptEdits unchanged (out of scope for this narrowing)"
else
  fail "git-workflow.md: expected acceptEdits to remain present"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "agent-permission-floor.test.sh: all checks passed"
  exit 0
else
  echo "agent-permission-floor.test.sh: FAILURES above"
  exit 1
fi
