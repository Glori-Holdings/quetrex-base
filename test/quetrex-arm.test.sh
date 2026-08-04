#!/usr/bin/env bash
# test/quetrex-arm.test.sh — behavioural test for bin/quetrex-arm, the
# deterministic cloud-arming tool called by .claude/commands/init.md (steps
# 4h/4i) in place of the buried, non-executing inline node prose it replaces.
#
# Run: bash test/quetrex-arm.test.sh
#
# Proves:
#   1. Fresh repo: writes all three — enabledPlugins pin (concrete factory
#      version, never `true`), extraKnownMarketplaces.quetrex in the EXACT
#      required shape, and .mcp.json's quetrex-kanban http broker.
#   2. Idempotent: a second run on the same repo makes NO changes (byte-
#      identical settings.json and .mcp.json) and exits 0.
#   3. Non-destructive: a pre-existing unrelated enabledPlugins entry and a
#      pre-existing unrelated mcpServers entry both survive arming.
#   4. Never writes a secret value into .mcp.json — only an http endpoint.
#
# Runs entirely offline: QX_ARM_MARKET_URL points at a local fixture file
# (quetrex-arm accepts any curl-understood URL, including file://), so this
# test never depends on network access.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARM="$REPO_ROOT/bin/quetrex-arm"

if [ ! -f "$ARM" ]; then
  echo "FAIL: bin/quetrex-arm not found at $ARM"
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not installed — quetrex-arm writes JSON with node"
  exit 0
fi

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qx-arm-test.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

KANBAN_URL="https://kanban.example.test"

# A fixture marketplace manifest declaring a concrete quetrex-factory version.
MARKET="$WORK/marketplace.json"
cat > "$MARKET" <<'JSON'
{
  "name": "quetrex",
  "plugins": [
    { "name": "quetrex", "version": "2.0.1" },
    { "name": "quetrex-factory", "version": "1.0.0" }
  ]
}
JSON

run_arm() {
  local repo="$1"
  QX_ARM_MARKET_URL="file://$MARKET" "$ARM" "$repo" "$KANBAN_URL"
}

json_get() {
  # json_get <file> <dot.path> — prints the field, or literal "undefined"
  local file="$1" path="$2"
  node -e '
    const fs=require("fs");
    const [f,p]=process.argv.slice(1);
    let o; try{o=JSON.parse(fs.readFileSync(f,"utf8"))}catch{ process.stdout.write("PARSE_ERROR"); process.exit(0); }
    const v=p.split(".").reduce((a,k)=>(a==null?a:a[k]),o);
    process.stdout.write(v===undefined?"undefined":JSON.stringify(v));
  ' "$file" "$path"
}

# ---------------------------------------------------------------------------
# 0. bin/quetrex-arm itself: executable, valid bash syntax.
# ---------------------------------------------------------------------------
if [ -x "$ARM" ]; then
  pass "bin/quetrex-arm is executable"
else
  fail "bin/quetrex-arm must be executable (chmod +x)"
fi

if bash -n "$ARM"; then
  pass "bin/quetrex-arm passes bash -n syntax check"
else
  fail "bin/quetrex-arm has a bash syntax error"
fi

# ---------------------------------------------------------------------------
# 1. Fresh repo — writes all three.
# ---------------------------------------------------------------------------
REPO1="$WORK/repo1"
mkdir -p "$REPO1"

OUT1="$(run_arm "$REPO1")"; RC1=$?

if [ "$RC1" -eq 0 ]; then
  pass "first run on a fresh repo exits 0"
else
  fail "first run on a fresh repo should exit 0 (got rc=$RC1, output: $OUT1)"
fi

SETTINGS1="$REPO1/.claude/settings.json"
MCP1="$REPO1/.mcp.json"

if [ -f "$SETTINGS1" ] && [ -f "$MCP1" ]; then
  pass "fresh run writes both .claude/settings.json and .mcp.json"
else
  fail "fresh run should write .claude/settings.json and .mcp.json (settings exists=$([ -f "$SETTINGS1" ] && echo yes || echo no), mcp exists=$([ -f "$MCP1" ] && echo yes || echo no))"
fi

QPIN="$(json_get "$SETTINGS1" 'enabledPlugins.quetrex@quetrex')"
if [ "$QPIN" = "true" ]; then
  pass "enabledPlugins['quetrex@quetrex'] === true"
else
  fail "enabledPlugins['quetrex@quetrex'] should be true (got: $QPIN)"
fi

FPIN="$(json_get "$SETTINGS1" 'enabledPlugins.quetrex-factory@quetrex')"
FPIN_UNQUOTED="$(printf '%s' "$FPIN" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(String(JSON.parse(s)))}catch{process.stdout.write(s)}})')"
if [ "$FPIN" != "true" ] && [ "$FPIN" != '"true"' ] && printf '%s' "$FPIN_UNQUOTED" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  pass "enabledPlugins['quetrex-factory@quetrex'] is a concrete version, never true (got: $FPIN_UNQUOTED)"
else
  fail "enabledPlugins['quetrex-factory@quetrex'] must be a concrete X.Y.Z version, never true (got: $FPIN)"
fi

MKT="$(json_get "$SETTINGS1" 'extraKnownMarketplaces.quetrex.source')"
EXPECT_MKT='{"source":"github","repo":"Glori-Holdings/quetrex-plugins"}'
if [ "$MKT" = "$EXPECT_MKT" ]; then
  pass "extraKnownMarketplaces.quetrex.source is the exact expected shape"
else
  fail "extraKnownMarketplaces.quetrex.source mismatch (got: $MKT, want: $EXPECT_MKT)"
fi

MCPTYPE="$(json_get "$MCP1" 'mcpServers.quetrex-kanban.type')"
MCPURL="$(json_get "$MCP1" 'mcpServers.quetrex-kanban.url')"
if [ "$MCPTYPE" = '"http"' ] && [ "$MCPURL" = '"https://kanban.example.test/api/mcp"' ]; then
  pass "mcpServers.quetrex-kanban is an http broker with the correct endpoint"
else
  fail "mcpServers.quetrex-kanban wrong (type=$MCPTYPE url=$MCPURL)"
fi

# ---------------------------------------------------------------------------
# 4. Never writes a secret value into .mcp.json.
# ---------------------------------------------------------------------------
MCP1_KEYS="$(json_get "$MCP1" 'mcpServers.quetrex-kanban')"
if printf '%s' "$MCP1_KEYS" | grep -qiE 'token|secret|key|bearer|password|authorization'; then
  fail ".mcp.json quetrex-kanban entry must never contain a secret-shaped field (got: $MCP1_KEYS)"
else
  pass ".mcp.json quetrex-kanban entry carries no secret-shaped field (endpoint only)"
fi

# ---------------------------------------------------------------------------
# 2. Idempotent — second run makes no changes.
# ---------------------------------------------------------------------------
cp "$SETTINGS1" "$WORK/settings.run1.json"
cp "$MCP1" "$WORK/mcp.run1.json"

OUT2="$(run_arm "$REPO1")"; RC2=$?

if [ "$RC2" -eq 0 ]; then
  pass "second run exits 0"
else
  fail "second run should exit 0 (got rc=$RC2, output: $OUT2)"
fi

if diff -q "$WORK/settings.run1.json" "$SETTINGS1" >/dev/null; then
  pass "second run leaves settings.json byte-identical"
else
  fail "second run must not change settings.json (diff below)"
  diff "$WORK/settings.run1.json" "$SETTINGS1" || true
fi

if diff -q "$WORK/mcp.run1.json" "$MCP1" >/dev/null; then
  pass "second run leaves .mcp.json byte-identical"
else
  fail "second run must not change .mcp.json (diff below)"
  diff "$WORK/mcp.run1.json" "$MCP1" || true
fi

if printf '%s' "$OUT2" | grep -qi 'already current' && printf '%s' "$OUT2" | grep -qi 'already register'; then
  pass "second run reports already-current for both settings.json and .mcp.json"
else
  fail "second run should report already-current for both files (got: $OUT2)"
fi

# ---------------------------------------------------------------------------
# 3. Non-destructive — pre-existing foreign keys survive.
# ---------------------------------------------------------------------------
REPO2="$WORK/repo2"
mkdir -p "$REPO2/.claude"
cat > "$REPO2/.claude/settings.json" <<'JSON'
{
  "enabledPlugins": { "foreign-plugin@somewhere": "9.9.9" },
  "unrelatedTopLevelKey": "keep-me"
}
JSON
cat > "$REPO2/.mcp.json" <<'JSON'
{
  "mcpServers": {
    "other-broker": { "type": "stdio", "command": "some-tool" }
  }
}
JSON

run_arm "$REPO2" >/dev/null; RC3=$?

FOREIGN_PLUGIN="$(json_get "$REPO2/.claude/settings.json" 'enabledPlugins.foreign-plugin@somewhere')"
UNRELATED_KEY="$(json_get "$REPO2/.claude/settings.json" 'unrelatedTopLevelKey')"
OTHER_BROKER="$(json_get "$REPO2/.mcp.json" 'mcpServers.other-broker.command')"

if [ "$RC3" -eq 0 ]; then
  pass "arming a repo with pre-existing foreign keys exits 0"
else
  fail "arming a repo with pre-existing foreign keys should exit 0 (got rc=$RC3)"
fi

if [ "$FOREIGN_PLUGIN" = '"9.9.9"' ]; then
  pass "pre-existing foreign enabledPlugins entry survives arming"
else
  fail "pre-existing foreign enabledPlugins entry must survive (got: $FOREIGN_PLUGIN)"
fi

if [ "$UNRELATED_KEY" = '"keep-me"' ]; then
  pass "pre-existing unrelated top-level settings key survives arming"
else
  fail "pre-existing unrelated top-level settings key must survive (got: $UNRELATED_KEY)"
fi

if [ "$OTHER_BROKER" = '"some-tool"' ]; then
  pass "pre-existing unrelated mcpServers entry survives arming"
else
  fail "pre-existing unrelated mcpServers entry must survive (got: $OTHER_BROKER)"
fi

QPIN2="$(json_get "$REPO2/.claude/settings.json" 'enabledPlugins.quetrex@quetrex')"
KANBAN2="$(json_get "$REPO2/.mcp.json" 'mcpServers.quetrex-kanban.url')"
if [ "$QPIN2" = "true" ] && [ "$KANBAN2" = '"https://kanban.example.test/api/mcp"' ]; then
  pass "arming still adds its own entries alongside the foreign ones"
else
  fail "arming should still add its own entries (qpin=$QPIN2, kanban=$KANBAN2)"
fi

# ---------------------------------------------------------------------------
# 5. Missing arguments — usage + exit 2, never a silent no-op.
# ---------------------------------------------------------------------------
USAGE_OUT="$("$ARM" 2>&1)"; RC_USAGE=$?
if [ "$RC_USAGE" -eq 2 ]; then
  pass "invoking with no arguments exits 2 (usage error)"
else
  fail "invoking with no arguments should exit 2 (got rc=$RC_USAGE)"
fi
if printf '%s' "$USAGE_OUT" | grep -qi 'usage: quetrex-arm'; then
  pass "invoking with no arguments prints usage"
else
  fail "invoking with no arguments should print a usage message (got: $USAGE_OUT)"
fi

# ---------------------------------------------------------------------------
# 6. Marketplace unreachable — fails OPEN on the factory pin, never writes a
#    bogus/floating value, still enables quetrex@quetrex, and still exits 0.
#    This is the exact branch AC5's "never true" guarantee depends on: a
#    regression here could silently degrade to writing `true` (or crashing)
#    the moment the marketplace manifest is unreachable, which is precisely
#    when a fresh /quetrex:init is most likely to hit it (offline, DNS
#    hiccup, GitHub raw outage).
# ---------------------------------------------------------------------------
REPO3="$WORK/repo3"
mkdir -p "$REPO3"

UNREACHABLE_OUT="$(QX_ARM_MARKET_URL="file://$WORK/does-not-exist.json" "$ARM" "$REPO3" "$KANBAN_URL" 2>&1)"
RC_UNREACHABLE=$?

if [ "$RC_UNREACHABLE" -eq 0 ]; then
  pass "unreachable marketplace still exits 0 (fails open on the pin, not on the run)"
else
  fail "unreachable marketplace should still exit 0 (got rc=$RC_UNREACHABLE, output: $UNREACHABLE_OUT)"
fi

QPIN3="$(json_get "$REPO3/.claude/settings.json" 'enabledPlugins.quetrex@quetrex')"
if [ "$QPIN3" = "true" ]; then
  pass "unreachable marketplace still enables quetrex@quetrex"
else
  fail "unreachable marketplace should still enable quetrex@quetrex (got: $QPIN3)"
fi

FPIN3_RAW="$(node -e '
  const fs = require("fs");
  let o = {};
  try { o = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch {}
  const has = Object.prototype.hasOwnProperty.call(o.enabledPlugins || {}, "quetrex-factory@quetrex");
  process.stdout.write(has ? JSON.stringify(o.enabledPlugins["quetrex-factory@quetrex"]) : "ABSENT");
' "$REPO3/.claude/settings.json")"
if [ "$FPIN3_RAW" = "ABSENT" ]; then
  pass "unreachable marketplace defers the factory pin entirely (no key written, never true)"
else
  fail "unreachable marketplace must not write any quetrex-factory@quetrex value (got: $FPIN3_RAW)"
fi

if printf '%s' "$UNREACHABLE_OUT" | grep -qi 'marketplace unreachable'; then
  pass "unreachable marketplace warns on stderr/stdout"
else
  fail "unreachable marketplace should warn about the deferred pin (got: $UNREACHABLE_OUT)"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "quetrex-arm.test.sh: all checks passed"
  exit 0
else
  echo "quetrex-arm.test.sh: FAILURES above"
  exit 1
fi
