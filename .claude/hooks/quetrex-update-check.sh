#!/usr/bin/env bash
# quetrex-update-check.sh — SessionStart hook (sources: startup|resume|compact).
#
# WHY THIS HOOK EXISTS. A pinned plugin gets NO native update notification, and
# there is no built-in version-check API — so a team can silently drift onto a
# stale engine. This is the ONE hook the command-layer plugin (quetrex)
# legitimately owns: it fetches the marketplace manifest, compares the pinned
# quetrex / quetrex-factory versions against the latest, and prints a single
# one-line nudge to run /quetrex:update when either is behind. It NEVER blocks
# and never mutates anything the pipeline enforces.
#
# CONTRACT (why it is safe to run on every SessionStart):
#   * NON-BLOCKING. SessionStart ignores blocking entirely; this hook always
#     exits 0. It can never wedge a session.
#   * AT MOST ONCE PER DAY. The result is cached under ${CLAUDE_PLUGIN_DATA}
#     (never ~/.claude, never the repo). Within the TTL the cache is reused and
#     NO network call is made.
#   * OFFLINE-SAFE. A failed/timed-out fetch falls back to a fresh-enough cache
#     if present, else stays SILENT and exits 0. A missing network is not an
#     error the user should see.
#   * SILENT WHEN CURRENT. It prints ONLY when a newer version exists. A
#     stdout line from a SessionStart hook is added to the model's context, so
#     silence when up-to-date keeps that context clean.
#
# TESTABILITY. The pure decision — "given installed X and latest Y, print or
# stay silent" — is driven entirely by env so test/update-check.test.sh can
# exercise it offline (see the QX_UPDATE_* overrides below).

set -uo pipefail

# --- config / overrides (tests inject these; production uses the defaults) ---
MARKET_URL="${QX_UPDATE_MARKETPLACE_URL:-https://raw.githubusercontent.com/Glori-Holdings/quetrex-plugins/main/.claude-plugin/marketplace.json}"
# A local marketplace file wins over the network (used by the test; also lets a
# mirror be pointed at a checkout). When set and readable, no curl is attempted.
MARKET_FILE="${QX_UPDATE_MARKETPLACE_FILE:-}"
TTL_SECONDS="${QX_UPDATE_TTL_SECONDS:-86400}"       # once/day
OFFLINE="${QX_UPDATE_OFFLINE:-0}"                   # test hook: force the offline path

# Cache location: plugin-local state ONLY. Fall back to an XDG state dir (never
# ~/.claude, never the repo) when ${CLAUDE_PLUGIN_DATA} is not exported.
CACHE_DIR="${CLAUDE_PLUGIN_DATA:-${XDG_STATE_HOME:-$HOME/.local/state}/quetrex}"
CACHE_FILE="$CACHE_DIR/update-check.cache"

# --- installed versions ------------------------------------------------------
# quetrex's own installed version = its plugin.json (this hook ships INSIDE the
# quetrex plugin, so ${CLAUDE_PLUGIN_ROOT} is its root). factory's pinned
# version = the consumer repo's enabledPlugins pin, when readable.
read_json_field() {  # <file> <node-expression-returning-string-or-empty>
  [ -f "$1" ] || return 0
  node -e '
    const fs=require("fs");
    let o; try{o=JSON.parse(fs.readFileSync(process.argv[1],"utf8"))}catch{process.exit(0)}
    const f=new Function("o", "try{return ("+process.argv[2]+")||\"\"}catch{return \"\"}");
    process.stdout.write(String(f(o)||""));
  ' "$1" "$2" 2>/dev/null
}

INSTALLED_QUETREX="${QX_UPDATE_INSTALLED_QUETREX:-}"
if [ -z "$INSTALLED_QUETREX" ] && [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  INSTALLED_QUETREX="$(read_json_field "$CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json" 'o.version')"
fi

INSTALLED_FACTORY="${QX_UPDATE_INSTALLED_FACTORY:-}"
if [ -z "$INSTALLED_FACTORY" ] && [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  PIN="$(read_json_field "$CLAUDE_PROJECT_DIR/.claude/settings.json" 'o.enabledPlugins && o.enabledPlugins["quetrex-factory@quetrex"]')"
  # A pin of `true` (unversioned) tells us nothing to compare — leave it empty.
  [ "$PIN" != "true" ] && INSTALLED_FACTORY="$PIN"
fi

# Nothing we can compare -> nothing to say.
if [ -z "$INSTALLED_QUETREX" ] && [ -z "$INSTALLED_FACTORY" ]; then
  exit 0
fi

# --- obtain the marketplace manifest (cache-first, offline-safe) -------------
mkdir -p "$CACHE_DIR" 2>/dev/null || true

cache_fresh() {
  [ -f "$CACHE_FILE" ] || return 1
  local now mtime
  now="$(date +%s)"
  mtime="$(stat -f %m "$CACHE_FILE" 2>/dev/null || stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)"
  [ $((now - mtime)) -lt "$TTL_SECONDS" ]
}

MANIFEST=""
if cache_fresh; then
  MANIFEST="$(cat "$CACHE_FILE" 2>/dev/null)"
else
  if [ -n "$MARKET_FILE" ] && [ -f "$MARKET_FILE" ]; then
    MANIFEST="$(cat "$MARKET_FILE" 2>/dev/null)"
  elif [ "$OFFLINE" != "1" ] && command -v curl >/dev/null 2>&1; then
    MANIFEST="$(curl -fsS --max-time 4 "$MARKET_URL" 2>/dev/null)" || MANIFEST=""
  fi
  if [ -n "$MANIFEST" ] && printf '%s' "$MANIFEST" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{JSON.parse(s)}catch{process.exit(1)}})' 2>/dev/null; then
    printf '%s' "$MANIFEST" > "$CACHE_FILE" 2>/dev/null || true
  else
    # Fetch failed or returned junk — fall back to whatever cache exists (even
    # if stale). No cache => silent success (offline, first run).
    MANIFEST="$(cat "$CACHE_FILE" 2>/dev/null || true)"
  fi
fi

[ -n "$MANIFEST" ] || exit 0   # offline with no cache — say nothing

# --- latest versions from the manifest ---------------------------------------
latest_of() {  # <plugin-name>
  printf '%s' "$MANIFEST" | node -e '
    const name=process.argv[1];
    let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
      let o; try{o=JSON.parse(s)}catch{process.exit(0)}
      const p=(o.plugins||[]).find(x=>x&&x.name===name);
      process.stdout.write(p&&p.version?String(p.version):"");
    });' "$1" 2>/dev/null
}

# Semver-ish "is A strictly older than B" via version sort. Returns 0 (behind)
# only when both are non-empty, differ, and A sorts before B.
behind() {  # <installed> <latest>
  local a="$1" b="$2"
  [ -n "$a" ] && [ -n "$b" ] || return 1
  [ "$a" = "$b" ] && return 1
  local first
  first="$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n1)"
  [ "$first" = "$a" ]
}

LATEST_QUETREX="$(latest_of quetrex)"
LATEST_FACTORY="$(latest_of quetrex-factory)"

MSG=""
if behind "$INSTALLED_QUETREX" "$LATEST_QUETREX"; then
  MSG="Quetrex $LATEST_QUETREX available (you have $INSTALLED_QUETREX)"
fi
if behind "$INSTALLED_FACTORY" "$LATEST_FACTORY"; then
  if [ -n "$MSG" ]; then
    MSG="$MSG; quetrex-factory $LATEST_FACTORY available (you have $INSTALLED_FACTORY)"
  else
    MSG="quetrex-factory $LATEST_FACTORY available (you have $INSTALLED_FACTORY)"
  fi
fi

[ -n "$MSG" ] && echo "[quetrex] $MSG — run /quetrex:update"
exit 0
