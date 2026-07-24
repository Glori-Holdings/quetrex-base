#!/usr/bin/env bash
#
# quetrex-install-project-gates.sh — deploy the committed per-project build gates.
#
# Copies the global verify-gate / merge-gate / secret-scan hook scripts (plus
# deny-guard and enforce-branch, so every PreToolUse path resolves after a
# fresh clone) and the seven fat pipeline agents into a project repo's OWN
# .claude/, wires them into that repo's COMMITTED .claude/settings.json, and
# ensures .quetrex/verify.json exists. This is what makes the build gates
# fire both locally AND in any Anthropic cloud routine that clones the repo —
# a cloud routine only ever sees what is committed, never the operator's
# global ~/.claude.
#
# Usage:
#   quetrex-install-project-gates.sh <project-repo-root>
#
# Contract:
#   - Idempotent: re-running never duplicates a wired hook entry.
#   - Non-destructive: never removes or overwrites any hook/setting/permission
#     that isn't one of the specific quetrex entries this script owns.
#   - Scoped: only ever reads from the operator's global ~/.claude and only
#     ever writes under <project-repo-root>. Never touches ~/.claude itself,
#     never writes outside the given root.
#
# Exit non-zero with a message on stderr on any failure (missing source
# scripts/agents, non-git root, unwritable target, invalid resulting JSON).

set -eo pipefail

# Source of the global install this script deploys FROM. Overridable only so
# this script can be exercised in isolation without touching a real machine's
# ~/.claude; in normal operation this is always $HOME.
SRC_HOME="${QUETREX_GATES_SRC_HOME:-$HOME}"
GLOBAL_HOOKS_DIR="$SRC_HOME/.claude/hooks"
GLOBAL_AGENTS_DIR="$SRC_HOME/.claude/agents"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TEMPLATE_FILE="$(cd "$SELF_DIR/.." && pwd -P)/templates/verify.json"

fail() {
  echo "quetrex-install-project-gates: $*" >&2
  exit 1
}

[ "$#" -eq 1 ] || fail "usage: quetrex-install-project-gates.sh <project-repo-root>"

ROOT_ARG="$1"
[ -n "$ROOT_ARG" ] || fail "project repo root argument is empty"
[ -d "$ROOT_ARG" ] || fail "project repo root does not exist: $ROOT_ARG"

# Canonicalize so every later comparison/guard is against an absolute path.
ROOT="$(cd "$ROOT_ARG" && pwd -P)"
{ [ -d "$ROOT/.git" ] || [ -f "$ROOT/.git" ]; } || fail "not a git repo (no .git): $ROOT"

HOOKS_DIR="$ROOT/.claude/hooks"
AGENTS_DIR="$ROOT/.claude/agents"
SETTINGS_FILE="$ROOT/.claude/settings.json"
QUETREX_DIR="$ROOT/.quetrex"
VERIFY_FILE="$QUETREX_DIR/verify.json"

# --- guard: every write target must live under $ROOT ------------------------
for target in "$HOOKS_DIR" "$AGENTS_DIR" "$SETTINGS_FILE" "$QUETREX_DIR"; do
  case "$target" in
    "$ROOT"/*) ;;
    *) fail "refusing to write outside project root ($ROOT): $target" ;;
  esac
done

# --- 1. gate + guard hook scripts -------------------------------------------
# verify-gate/merge-gate/secret-scan are the gates themselves; deny-guard and
# enforce-branch are copied too so the PreToolUse[Bash] wiring below resolves
# in a fresh clone that has never run the global installer against this repo.
GATE_SCRIPTS="verify-gate.sh merge-gate.sh secret-scan.sh deny-guard.sh enforce-branch.sh"

mkdir -p "$HOOKS_DIR"
COPIED_HOOKS=""
MISSING_HOOKS=""
for script in $GATE_SCRIPTS; do
  src="$GLOBAL_HOOKS_DIR/$script"
  if [ -f "$src" ]; then
    cp "$src" "$HOOKS_DIR/$script"
    chmod +x "$HOOKS_DIR/$script"
    COPIED_HOOKS="$COPIED_HOOKS $script"
  else
    MISSING_HOOKS="$MISSING_HOOKS $script"
  fi
done
if [ -n "$MISSING_HOOKS" ]; then
  fail "missing required hook script(s) in $GLOBAL_HOOKS_DIR:$MISSING_HOOKS — run the quetrex-base installer first"
fi

# --- 2. fat pipeline agents ---------------------------------------------
FAT_AGENTS="architect.md developer.md qa.md reviewer.md security-reviewer.md git-workflow.md database-architect.md"

mkdir -p "$AGENTS_DIR"
COPIED_AGENTS=""
MISSING_AGENTS=""
for agent in $FAT_AGENTS; do
  src="$GLOBAL_AGENTS_DIR/$agent"
  if [ -f "$src" ]; then
    cp "$src" "$AGENTS_DIR/$agent"
    COPIED_AGENTS="$COPIED_AGENTS $agent"
  else
    MISSING_AGENTS="$MISSING_AGENTS $agent"
  fi
done
if [ -n "$MISSING_AGENTS" ]; then
  fail "missing required agent definition(s) in $GLOBAL_AGENTS_DIR:$MISSING_AGENTS — run the quetrex-base installer first"
fi

# --- 3. wire .claude/settings.json (merge, never clobber) ------------------
# Build the JSON with a temp node script (JSON.parse/JSON.stringify) — never
# with echo/heredoc JSON — so existing settings are read structurally and
# only the specific quetrex hook entries are added.
command -v node >/dev/null 2>&1 || fail "node is required to wire $SETTINGS_FILE"

NODE_SCRIPT="$(mktemp -t quetrex-wire-settings)"
trap 'rm -f "$NODE_SCRIPT"' EXIT

cat > "$NODE_SCRIPT" <<'NODEEOF'
const fs = require("fs");
const path = require("path");

const settingsPath = process.argv[2];

let settings = {};
if (fs.existsSync(settingsPath)) {
  const raw = fs.readFileSync(settingsPath, "utf8");
  if (raw.trim() !== "") {
    try {
      settings = JSON.parse(raw);
    } catch (e) {
      console.error(`existing settings.json is not valid JSON: ${settingsPath}`);
      process.exit(1);
    }
  }
  if (settings === null || typeof settings !== "object" || Array.isArray(settings)) {
    console.error(`existing settings.json is not a JSON object: ${settingsPath}`);
    process.exit(1);
  }
}

settings.hooks = (settings.hooks && typeof settings.hooks === "object" && !Array.isArray(settings.hooks))
  ? settings.hooks
  : {};

function basenameOf(command) {
  const m = String(command).match(/([^/"]+\.sh)"?\s*$/);
  return m ? m[1] : command;
}

// Command form fixed per contract: bash "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/<x>.sh"
// (the literal ${CLAUDE_PROJECT_DIR:-.} is shell syntax resolved by Claude Code's
// hook runner at invocation time, not by this node script — hence the \$ escape).
function hookEntry(name, timeout) {
  return {
    command: `bash "\${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/${name}"`,
    timeout,
  };
}

function ensureNoMatcherGroup(event, entry) {
  if (!Array.isArray(settings.hooks[event])) settings.hooks[event] = [];
  const arr = settings.hooks[event];
  let group = arr.find((g) => g && typeof g === "object" && g.matcher === undefined);
  if (!group) {
    group = { hooks: [] };
    arr.push(group);
  }
  if (!Array.isArray(group.hooks)) group.hooks = [];
  const name = basenameOf(entry.command);
  const already = group.hooks.some((h) => h && typeof h.command === "string" && basenameOf(h.command) === name);
  if (already) return 0;
  group.hooks.push({ type: "command", command: entry.command, timeout: entry.timeout });
  return 1;
}

function ensureMatcherGroup(event, matcher, entries) {
  if (!Array.isArray(settings.hooks[event])) settings.hooks[event] = [];
  const arr = settings.hooks[event];
  let group = arr.find((g) => g && typeof g === "object" && g.matcher === matcher);
  if (!group) {
    group = { matcher, hooks: [] };
    arr.push(group);
  }
  if (!Array.isArray(group.hooks)) group.hooks = [];
  let added = 0;
  for (const entry of entries) {
    const name = basenameOf(entry.command);
    const already = group.hooks.some((h) => h && typeof h.command === "string" && basenameOf(h.command) === name);
    if (already) continue;
    group.hooks.push({ type: "command", command: entry.command, timeout: entry.timeout });
    added++;
  }
  return added;
}

let changed = 0;
changed += ensureNoMatcherGroup("Stop", hookEntry("verify-gate.sh", 900));
changed += ensureNoMatcherGroup("SubagentStop", hookEntry("verify-gate.sh", 600));
changed += ensureMatcherGroup("PreToolUse", "Bash", [
  hookEntry("deny-guard.sh", 30),
  hookEntry("secret-scan.sh", 30),
  hookEntry("enforce-branch.sh", 30),
  hookEntry("merge-gate.sh", 60),
]);
changed += ensureMatcherGroup("PreToolUse", "Write|Edit", [
  hookEntry("secret-scan.sh", 30),
]);

fs.mkdirSync(path.dirname(settingsPath), { recursive: true });
fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + "\n");

// Re-parse the file we just wrote to positively confirm it is valid JSON.
JSON.parse(fs.readFileSync(settingsPath, "utf8"));

console.log(`WIRED_HOOK_CHANGES=${changed}`);
NODEEOF

WIRE_OUTPUT="$(node "$NODE_SCRIPT" "$SETTINGS_FILE")" || fail "failed to wire $SETTINGS_FILE"
rm -f "$NODE_SCRIPT"
trap - EXIT
WIRED_HOOK_CHANGES="$(printf '%s\n' "$WIRE_OUTPUT" | sed -n 's/^WIRED_HOOK_CHANGES=//p')"
[ -n "$WIRED_HOOK_CHANGES" ] || WIRED_HOOK_CHANGES=0

# --- 4. .quetrex/verify.json (seed once from the template, never overwrite) --
mkdir -p "$QUETREX_DIR"
if [ -f "$VERIFY_FILE" ]; then
  VERIFY_STATUS="already present"
else
  [ -f "$TEMPLATE_FILE" ] || fail "verify.json template not found: $TEMPLATE_FILE"
  cp "$TEMPLATE_FILE" "$VERIFY_FILE"
  VERIFY_STATUS="written from template"
fi

# --- summary -----------------------------------------------------------
echo "quetrex-install-project-gates: wired project build gates in $ROOT"
echo "  hooks copied:  ${COPIED_HOOKS# }"
echo "  agents copied: ${COPIED_AGENTS# }"
echo "  settings.json: $SETTINGS_FILE ($WIRED_HOOK_CHANGES new hook entr$([ "$WIRED_HOOK_CHANGES" = "1" ] && echo y || echo ies) wired)"
echo "  verify.json:   $VERIFY_FILE ($VERIFY_STATUS)"
