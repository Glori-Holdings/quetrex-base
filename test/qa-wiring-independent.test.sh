#!/usr/bin/env bash
# test/qa-wiring-independent.test.sh — INDEPENDENT QA adversarial coverage
# for ONE-COPY item (e): every ${CLAUDE_PLUGIN_ROOT}/scripts/*.sh named by
# plugins/quetrex-factory/hooks/hooks.json exists under
# plugins/quetrex-factory/scripts/ and passes bash -n, and every agent
# listed in .claude-plugin/plugin.json's "agents" array exists on disk.
#
# Run: bash test/qa-wiring-independent.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS_JSON="$REPO_ROOT/plugins/quetrex-factory/hooks/hooks.json"
SCRIPTS_DIR="$REPO_ROOT/plugins/quetrex-factory/scripts"
PLUGIN_JSON="$REPO_ROOT/.claude-plugin/plugin.json"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq is not installed"
  exit 0
fi
for f in "$HOOKS_JSON" "$PLUGIN_JSON"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: expected file not found: $f"
    exit 1
  fi
done

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

# =============================================================================
# hooks.json: every ${CLAUDE_PLUGIN_ROOT}/scripts/*.sh command target exists
# and passes bash -n. Also assert no ~/.claude or ${CLAUDE_PROJECT_DIR} leak.
# =============================================================================
COMMANDS=$(jq -r '.hooks | to_entries[] | .value[] | .hooks[] | select(.type=="command") | .command' "$HOOKS_JSON")
CMD_COUNT=$(printf '%s\n' "$COMMANDS" | grep -c '.' || true)
if [ "$CMD_COUNT" -ge 1 ]; then
  ok "hooks.json: found $CMD_COUNT registered command hook(s)"
else
  notok "hooks.json: expected >= 1 registered command hook, found $CMD_COUNT"
fi

while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  if printf '%s' "$cmd" | grep -q '~/.claude'; then
    notok "hooks.json command references ~/.claude (forbidden): $cmd"
  else
    ok "hooks.json command does not reference ~/.claude: $cmd"
  fi
  if printf '%s' "$cmd" | grep -q '\${CLAUDE_PROJECT_DIR}'; then
    notok "hooks.json command references \${CLAUDE_PROJECT_DIR} (forbidden): $cmd"
  else
    ok "hooks.json command does not reference \${CLAUDE_PROJECT_DIR}: $cmd"
  fi

  if [[ "$cmd" =~ \$\{CLAUDE_PLUGIN_ROOT\}/scripts/([A-Za-z0-9_.-]+\.sh) ]]; then
    SCRIPT_NAME="${BASH_REMATCH[1]}"
    SCRIPT_PATH="$SCRIPTS_DIR/$SCRIPT_NAME"
    if [ -f "$SCRIPT_PATH" ]; then
      ok "hooks.json target exists on disk: scripts/$SCRIPT_NAME"
    else
      notok "hooks.json target MISSING on disk: expected $SCRIPT_PATH (command: $cmd)"
    fi
    if bash -n "$SCRIPT_PATH" 2>/tmp/qa-wiring.synerr.$$; then
      ok "scripts/$SCRIPT_NAME: bash -n passes"
    else
      notok "scripts/$SCRIPT_NAME: bash -n FAILED: $(cat /tmp/qa-wiring.synerr.$$)"
    fi
    rm -f /tmp/qa-wiring.synerr.$$
  else
    notok "hooks.json command does not resolve to a \${CLAUDE_PLUGIN_ROOT}/scripts/*.sh target: $cmd"
  fi
done <<< "$COMMANDS"

# Cross-check the reverse direction too: every *.sh actually present in
# scripts/ is either registered by hooks.json OR is a known sourced-only /
# router helper (verify-gate-quick-chain.sh and qx-verify-baseline.sh are both
# sourced by verify-gate.sh, not registered directly; qx-armed.sh is sourced by deny-guard.sh,
# secret-scan.sh, enforce-branch.sh, merge-gate.sh and verify-gate.sh
# — ONE-COPY round 2's shared arming predicate — not registered directly
# either; format.sh and right-size-router.sh ARE registered above and
# covered by the forward check).
if [ -d "$SCRIPTS_DIR" ]; then
  for f in "$SCRIPTS_DIR"/*.sh; do
    base=$(basename "$f")
    if printf '%s\n' "$COMMANDS" | grep -q "scripts/$base"; then
      ok "scripts/$base: registered in hooks.json"
    elif [ "$base" = "verify-gate-quick-chain.sh" ] || [ "$base" = "qx-armed.sh" ] \
         || [ "$base" = "qx-verify-baseline.sh" ]; then
      ok "scripts/$base: known sourced-only helper (not directly registered) — OK"
    else
      notok "scripts/$base: exists on disk but is NOT registered in hooks.json and is not a known sourced-only helper — dead file or missing wiring"
    fi
  done
else
  notok "scripts dir missing entirely: $SCRIPTS_DIR"
fi

# =============================================================================
# plugin.json: every agent path exists on disk
# =============================================================================
AGENT_PATHS=$(jq -r '.agents[]?' "$PLUGIN_JSON")
AGENT_COUNT=$(printf '%s\n' "$AGENT_PATHS" | grep -c '.' || true)
if [ "$AGENT_COUNT" -ge 1 ]; then
  ok "plugin.json: found $AGENT_COUNT declared agent(s)"
else
  notok "plugin.json: expected >= 1 declared agent, found $AGENT_COUNT"
fi

while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  ABS="$REPO_ROOT/${rel#./}"
  if [ -f "$ABS" ]; then
    ok "plugin.json agent exists: $rel"
  else
    notok "plugin.json agent MISSING: $rel (resolved $ABS)"
  fi
done <<< "$AGENT_PATHS"

# Reverse check: .claude/agents/ holds zero .md files (one-copy — agents
# amendment supersedes the plan's original AC11; all 9 now live only under
# plugins/quetrex-factory/agents/).
if [ -d "$REPO_ROOT/.claude/agents" ]; then
  STRAY=$(find "$REPO_ROOT/.claude/agents" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
  if [ "$STRAY" -eq 0 ]; then
    ok ".claude/agents/ holds 0 .md files (one-copy: agents live only under plugins/quetrex-factory/agents/)"
  else
    notok ".claude/agents/ holds $STRAY .md file(s) — one-copy violation, agents duplicated outside the plugin subtree"
  fi
else
  ok ".claude/agents/ does not exist — one-copy satisfied trivially"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "qa-wiring-independent.test.sh: all checks passed"
else
  echo "qa-wiring-independent.test.sh: FAILURES above"
fi
exit "$FAIL"
