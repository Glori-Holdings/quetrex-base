#!/usr/bin/env bash
# test/quetrex-arm.test.sh — behavioural test for bin/quetrex-arm, the
# deterministic cloud-arming tool called by .claude/commands/init.md (steps
# 4h/4i) in place of the buried, non-executing inline node prose it replaces.
#
# Run: bash test/quetrex-arm.test.sh
#
# Proves:
#   1. Fresh repo: writes the enabledPlugins pin (concrete factory version,
#      never `true`) and extraKnownMarketplaces.quetrex in the EXACT required
#      shape — and writes NO .mcp.json at all.
#   2. Idempotent: a second run on the same repo makes NO changes (byte-
#      identical settings.json, still no .mcp.json) and exits 0.
#   3. Non-destructive: a pre-existing unrelated enabledPlugins entry and a
#      pre-existing unrelated mcpServers entry both survive arming.
#   4. REMEDIATION (the reason this behaviour changed): arming REMOVES a
#      quetrex-kanban broker registered at the never-built <kanban>/api/mcp
#      endpoint — deleting .mcp.json when that entry was all it held, and
#      preserving the file when it holds anything else. A quetrex-kanban entry
#      pointing at a DIFFERENT url is left untouched.
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

if [ -f "$SETTINGS1" ]; then
  pass "fresh run writes .claude/settings.json"
else
  fail "fresh run should write .claude/settings.json"
fi

# The retired behaviour: arming used to register an http MCP broker at
# <kanban>/api/mcp. That endpoint was never built — it answers with the dash's
# Next.js 404 page — so every armed repo opened with an MCP server that could
# never handshake. Arming must not create that file at all any more.
if [ ! -e "$MCP1" ]; then
  pass "fresh run writes NO .mcp.json (the /api/mcp broker endpoint does not exist)"
else
  fail "fresh run must not create .mcp.json — the quetrex-kanban broker endpoint was never built (got: $(cat "$MCP1"))"
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

# NOTE: the "concrete version" check above (FPIN_UNQUOTED, via String(JSON.parse(...)))
# CANNOT tell a one-element array pin apart from a bare version string — JS coerces
# String(["1.0.0"]) to the exact same "1.0.0" as String("1.0.0"). It stays as
# documentation of intent, but the shape assertion below is the one that actually
# proves the on-disk value is the array Claude Code's settings schema requires
# (enabledPlugins: record<string, string[] | boolean | undefined> — a bare string
# fails validation with "Invalid input" and the entry is silently dropped).
FPIN_IS_ARRAY="$(printf '%s' "$FPIN" | node -e '
  let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
    let v; try { v = JSON.parse(s); } catch { v = undefined; }
    const ok = Array.isArray(v) && v.length === 1 && typeof v[0] === "string" && /^[0-9]+\.[0-9]+\.[0-9]+$/.test(v[0]);
    process.stdout.write(ok ? "yes" : "no");
  });
')"
if [ "$FPIN_IS_ARRAY" = "yes" ]; then
  pass "enabledPlugins['quetrex-factory@quetrex'] is a one-element ARRAY pin, not a bare string (got: $FPIN)"
else
  fail "enabledPlugins['quetrex-factory@quetrex'] must be a one-element array like [\"1.0.0\"] — a bare string fails Claude Code's settings validation with Invalid input (got: $FPIN)"
fi

MKT="$(json_get "$SETTINGS1" 'extraKnownMarketplaces.quetrex.source')"
EXPECT_MKT='{"source":"github","repo":"Glori-Holdings/quetrex-plugins"}'
if [ "$MKT" = "$EXPECT_MKT" ]; then
  pass "extraKnownMarketplaces.quetrex.source is the exact expected shape"
else
  fail "extraKnownMarketplaces.quetrex.source mismatch (got: $MKT, want: $EXPECT_MKT)"
fi

# Third-party marketplaces default to auto-update OFF. Without this declared, the
# catalog freezes at whatever it was when the marketplace was added, the
# SessionStart update check compares against stale data, and the whole team runs
# an old engine indefinitely — which is exactly how a shipped merge-gate fix
# failed to reach anyone. Declaring it in settings syncs it to
# known_marketplaces.json for every member of the repo.
AUTOUP="$(json_get "$SETTINGS1" 'extraKnownMarketplaces.quetrex.autoUpdate')"
if [ "$AUTOUP" = "true" ]; then
  pass "extraKnownMarketplaces.quetrex.autoUpdate is true (team tracks published engine fixes)"
else
  fail "extraKnownMarketplaces.quetrex.autoUpdate must be true — third-party marketplaces default to OFF and silently strand the team on a stale engine (got: $AUTOUP)"
fi

# ---------------------------------------------------------------------------
# 2. Idempotent — second run makes no changes.
# ---------------------------------------------------------------------------
cp "$SETTINGS1" "$WORK/settings.run1.json"

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

if [ ! -e "$MCP1" ]; then
  pass "second run still creates no .mcp.json"
else
  fail "second run must not create .mcp.json (got: $(cat "$MCP1"))"
fi

if printf '%s' "$OUT2" | grep -qi 'already current' && printf '%s' "$OUT2" | grep -qi 'nothing to remediate'; then
  pass "second run reports already-current for settings.json and nothing to remediate for .mcp.json"
else
  fail "second run should report already-current + nothing-to-remediate (got: $OUT2)"
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
KANBAN2="$(json_get "$REPO2/.mcp.json" 'mcpServers.quetrex-kanban')"
if [ "$QPIN2" = "true" ]; then
  pass "arming still adds its own settings entries alongside the foreign ones"
else
  fail "arming should still add its own settings entries (qpin=$QPIN2)"
fi
if [ "$KANBAN2" = "undefined" ]; then
  pass "arming registers no quetrex-kanban broker alongside a foreign one"
else
  fail "arming must not register a quetrex-kanban broker (got: $KANBAN2)"
fi

# ---------------------------------------------------------------------------
# 4. REMEDIATION — the dead broker is REMOVED from an already-armed repo.
#
#    This is why the behaviour above changed. Repos armed by an older engine
#    carry a committed quetrex-kanban registration pointing at
#    <kanban>/api/mcp, a route the kanban never had; Claude Code fails to
#    connect it on every single session, in every clone, for every teammate.
#    Re-running /quetrex:init (hence quetrex-arm) is the remediation path, so
#    the removal is asserted four ways: the whole-file delete, the
#    preserve-other-servers case, the preserve-other-top-level-keys case, and
#    the leave-a-real-url-alone case.
# ---------------------------------------------------------------------------

# 4a. .mcp.json holding ONLY the dead broker → the file itself is deleted, because
#     an empty {"mcpServers":{}} is still a config Claude Code loads.
REPO4="$WORK/repo4"
mkdir -p "$REPO4"
cat > "$REPO4/.mcp.json" <<'JSON'
{
  "mcpServers": {
    "quetrex-kanban": { "type": "http", "url": "https://dash.quetrex.com/api/mcp" }
  }
}
JSON
OUT4="$(run_arm "$REPO4")"; RC4=$?

if [ "$RC4" -eq 0 ]; then
  pass "arming a repo carrying the dead broker exits 0"
else
  fail "arming a repo carrying the dead broker should exit 0 (got rc=$RC4, output: $OUT4)"
fi

if [ ! -e "$REPO4/.mcp.json" ]; then
  pass "dead-broker-only .mcp.json is deleted outright"
else
  fail "a .mcp.json holding only the dead broker must be deleted (still present: $(cat "$REPO4/.mcp.json"))"
fi

if printf '%s' "$OUT4" | grep -qi 'removed the dead quetrex-kanban broker'; then
  pass "removal is reported out loud, so /quetrex:init can tell the operator"
else
  fail "removal must be reported in the output (got: $OUT4)"
fi

# 4b. .mcp.json ALSO holding a foreign server → entry removed, file kept, foreign
#     server untouched.
REPO5="$WORK/repo5"
mkdir -p "$REPO5"
cat > "$REPO5/.mcp.json" <<'JSON'
{
  "mcpServers": {
    "quetrex-kanban": { "type": "http", "url": "https://dash.quetrex.com/api/mcp" },
    "other-broker": { "type": "stdio", "command": "some-tool" }
  },
  "unrelatedTopLevelKey": "keep-me"
}
JSON
run_arm "$REPO5" >/dev/null

if [ -f "$REPO5/.mcp.json" ]; then
  pass "a .mcp.json with other content survives the removal"
else
  fail "a .mcp.json with other content must NOT be deleted"
fi

DEAD5="$(json_get "$REPO5/.mcp.json" 'mcpServers.quetrex-kanban')"
OTHER5="$(json_get "$REPO5/.mcp.json" 'mcpServers.other-broker.command')"
TOP5="$(json_get "$REPO5/.mcp.json" 'unrelatedTopLevelKey')"
if [ "$DEAD5" = "undefined" ]; then
  pass "the dead quetrex-kanban entry is removed from a shared .mcp.json"
else
  fail "the dead quetrex-kanban entry must be removed (got: $DEAD5)"
fi
if [ "$OTHER5" = '"some-tool"' ]; then
  pass "a foreign mcpServers entry survives the removal"
else
  fail "a foreign mcpServers entry must survive the removal (got: $OTHER5)"
fi
if [ "$TOP5" = '"keep-me"' ]; then
  pass "an unrelated top-level .mcp.json key survives the removal"
else
  fail "an unrelated top-level .mcp.json key must survive (got: $TOP5)"
fi

# 4c. A quetrex-kanban entry pointing at a DIFFERENT url is NOT ours to delete —
#     a team that has wired this name to something real must keep it.
REPO6="$WORK/repo6"
mkdir -p "$REPO6"
cat > "$REPO6/.mcp.json" <<'JSON'
{
  "mcpServers": {
    "quetrex-kanban": { "type": "http", "url": "https://broker.example.test/mcp/v1" }
  }
}
JSON
OUT6="$(run_arm "$REPO6")"

KEPT6="$(json_get "$REPO6/.mcp.json" 'mcpServers.quetrex-kanban.url')"
if [ "$KEPT6" = '"https://broker.example.test/mcp/v1"' ]; then
  pass "a quetrex-kanban entry at a non-/api/mcp url is left untouched"
else
  fail "only the /api/mcp endpoint may be removed — a real broker url must survive (got: $KEPT6)"
fi
if printf '%s' "$OUT6" | grep -qi 'left untouched'; then
  pass "leaving a real broker alone is reported out loud"
else
  fail "leaving a foreign quetrex-kanban url alone should be reported (got: $OUT6)"
fi

# 4d. An unparseable .mcp.json is never rewritten or deleted — arming reports and
#     moves on rather than destroying hand-written config it cannot understand.
REPO7="$WORK/repo7"
mkdir -p "$REPO7"
printf '{ this is not json' > "$REPO7/.mcp.json"
OUT7="$(run_arm "$REPO7")"; RC7=$?

if [ "$RC7" -eq 0 ] && [ "$(cat "$REPO7/.mcp.json")" = '{ this is not json' ]; then
  pass "an unparseable .mcp.json is left byte-identical and does not fail the run"
else
  fail "an unparseable .mcp.json must be left alone with rc=0 (rc=$RC7, content: $(cat "$REPO7/.mcp.json"))"
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
