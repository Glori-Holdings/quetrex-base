#!/usr/bin/env bash
# quetrex-update-check.sh — SessionStart hook (sources: startup|resume|compact).
#
# WHY THIS HOOK EXISTS. A pinned plugin gets NO native update notification, and
# there is no built-in version-check API — so a team can silently drift onto a
# stale engine. This is the hook quetrex-setup owns (it is enabled machine-wide,
# so it can fire in every repo, armed or not): it fetches the marketplace
# manifest, compares quetrex-setup's own installed version plus the
# `quetrex` / `quetrex-factory` versions installed on this machine against the
# latest published ones, and prints a single one-line nudge to run
# /quetrex-setup:update when any is behind. It NEVER blocks and never mutates
# anything the pipeline enforces.
#
# WHY THE RESOLUTION SOURCES CHANGED WITH THE setup-plugin SPLIT.
#   * quetrex-setup's OWN version now comes from ITS OWN manifest
#     (${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json) — this hook ships
#     inside quetrex-setup, a plugin independently versioned from `quetrex`.
#   * `quetrex` and `quetrex-factory` are no longer resolvable from a repo's
#     enabledPlugins pin at all: pins are booleans now (`true`/absent), never
#     a concrete version — a version pin is precisely what made the whole
#     command layer fail to load (see GOLDEN.md / init.md). Their installed
#     versions are instead read from the machine's own
#     installed_plugins.json, the same on-disk record
#     quetrex-bound-version-guard.sh already reads for the same reason.
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
#   * A COMPONENT THAT CANNOT BE RESOLVED IS OMITTED, never vouched for and
#     never claimed "behind" — the up-to-date line names only the components
#     it actually resolved from both an installed AND a latest version.
#   * THE MANIFEST IS HOSTILE INPUT (SEC-GLOBAL-1). This hook now fires
#     machine-wide, so every version string it might print is validated
#     against valid_version() first (an unsafe shape is folded into the same
#     "unresolved -> omitted" rule above) and the manifest body itself is
#     bounded to MAX_MANIFEST_BYTES on every read, whether fetched, cached,
#     or supplied via a local override file.
#
# TESTABILITY. The pure decision — "given installed X and latest Y, print or
# stay silent" — is driven entirely by env so a test can exercise it offline:
#   QX_UPDATE_MARKETPLACE_FILE / QX_UPDATE_MARKETPLACE_URL — the manifest.
#   QX_UPDATE_INSTALLED_PLUGINS_FILE — overrides installed_plugins.json (the
#     same seam name convention as quetrex-bound-version-guard.sh's
#     QX_BOUND_INSTALLED_PLUGINS_FILE).
#   QX_UPDATE_INSTALLED_SETUP / _QUETREX / _FACTORY — direct overrides for
#     each installed version, bypassing discovery entirely.
#   QX_UPDATE_TTL_SECONDS / QX_UPDATE_OFFLINE — cache/offline controls.

set -uo pipefail

# --- config / overrides (tests inject these; production uses the defaults) ---
MARKET_URL="${QX_UPDATE_MARKETPLACE_URL:-https://raw.githubusercontent.com/Glori-Holdings/quetrex-plugins/main/.claude-plugin/marketplace.json}"
# A local marketplace file wins over the network (used by the test; also lets a
# mirror be pointed at a checkout). When set and readable, no curl is attempted.
MARKET_FILE="${QX_UPDATE_MARKETPLACE_FILE:-}"
TTL_SECONDS="${QX_UPDATE_TTL_SECONDS:-86400}"       # once/day
OFFLINE="${QX_UPDATE_OFFLINE:-0}"                   # test hook: force the offline path
INSTALLED_PLUGINS_FILE="${QX_UPDATE_INSTALLED_PLUGINS_FILE:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json}"

# --- SEC-GLOBAL-1 hardening --------------------------------------------------
# This hook now fires machine-wide (every repo, armed or not — see the WHY
# THIS HOOK EXISTS note above), so the manifest it reads must be treated as
# hostile: a hostile repo's committed .claude/settings.json `env` block can
# repoint QX_UPDATE_MARKETPLACE_FILE/_URL at repo-controlled content, and
# Glori-Holdings/quetrex-plugins main is itself a shared write surface. A
# version string is compared and printed verbatim below, so it is the
# injection sink. Two independent bounds close it:
#   1. SIZE. The manifest body (fetched OR read from cache OR read from a
#      local file) is capped at MAX_MANIFEST_BYTES before anything parses it,
#      so an oversized payload cannot even reach node/jq.
#   2. SHAPE. Every version string this script ever prints — fetched from the
#      manifest, read back from the cache, or read from installed_plugins.json
#      — is passed through valid_version() first. Anything not shaped like a
#      plain semver-ish token is treated exactly like "cannot be resolved":
#      omitted, never vouched for, never echoed. This is the SAME contract
#      the file already documents for an unresolved component (line 38-40);
#      an unsafe-shaped version is now folded into that same "unresolved" case
#      rather than being a new exception.
MAX_MANIFEST_BYTES=65536

valid_version() {  # <string> -> prints it back if safely shaped, else empty
  local v="$1"
  # SEC-GLOBAL-9: an earlier version of this regex bounded the SHAPE but not
  # the SIZE of each numeric run — [0-9]+ matches an arbitrarily long digit
  # string, so an all-digit "version" (e.g. 60,000 nines) still passed and
  # flooded stdout, bounded only incidentally by MAX_MANIFEST_BYTES. Each
  # numeric run is now capped at 6 digits (no real semver component is
  # anywhere close to that), and the whole token is capped at 64 characters
  # as a second, independent belt.
  [ "${#v}" -le 64 ] || { printf ''; return; }
  if [[ "$v" =~ ^[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}([-+][A-Za-z0-9.-]{1,40})?$ ]]; then
    printf '%s' "$v"
  fi
}

# Reads a manifest candidate bounded to MAX_MANIFEST_BYTES and only if it
# parses as JSON; empty otherwise. Used for every manifest source (fetch
# response, on-disk cache, local override file) so a poisoned or oversized
# body is never trusted regardless of where it came from.
bounded_valid_manifest() {  # <raw-bytes-on-stdin> -> the manifest, or empty
  local body
  body="$(head -c "$MAX_MANIFEST_BYTES")"
  [ -n "$body" ] || { printf ''; return; }
  if printf '%s' "$body" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{JSON.parse(s)}catch{process.exit(1)}})' 2>/dev/null; then
    printf '%s' "$body"
  fi
}

# Cache location: plugin-local state ONLY. Fall back to an XDG state dir (never
# ~/.claude, never the repo) when ${CLAUDE_PLUGIN_DATA} is not exported.
CACHE_DIR="${CLAUDE_PLUGIN_DATA:-${XDG_STATE_HOME:-$HOME/.local/state}/quetrex}"
CACHE_FILE="$CACHE_DIR/update-check.cache"

# --- installed versions ------------------------------------------------------
read_json_field() {  # <file> <node-expression-returning-string-or-empty>
  [ -f "$1" ] || return 0
  node -e '
    const fs=require("fs");
    let o; try{o=JSON.parse(fs.readFileSync(process.argv[1],"utf8"))}catch{process.exit(0)}
    const f=new Function("o", "try{return ("+process.argv[2]+")||\"\"}catch{return \"\"}");
    process.stdout.write(String(f(o)||""));
  ' "$1" "$2" 2>/dev/null
}

# quetrex-setup's own installed version: its own manifest. This hook ships
# INSIDE quetrex-setup, so ${CLAUDE_PLUGIN_ROOT} is quetrex-setup's root.
INSTALLED_SETUP="${QX_UPDATE_INSTALLED_SETUP:-}"
if [ -z "$INSTALLED_SETUP" ] && [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  INSTALLED_SETUP="$(read_json_field "$CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json" 'o.version')"
fi
# SEC-GLOBAL-1: an unsafely-shaped version is treated as unresolved (omitted),
# never printed. plugin.json ships with the repo and is normally trusted, but
# validating it too costs nothing and keeps every printed field on one rule.
INSTALLED_SETUP="$(valid_version "$INSTALLED_SETUP")"

# `quetrex` / `quetrex-factory`: resolved from installed_plugins.json, the
# machine-global record of what is actually on disk — NOT the repo's
# enabledPlugins pin, which is a boolean now and carries no version at all.
installed_version_for() {  # <name> -> highest version among "<name>@..." keys, empty on failure
  local name="$1"
  [ -f "$INSTALLED_PLUGINS_FILE" ] || { printf ''; return; }
  command -v jq >/dev/null 2>&1 || { printf ''; return; }
  jq -r --arg name "$name" '
      (.plugins // {}) as $p
      | ($p | to_entries[]? | select(.key | startswith($name + "@")) | (.value[]?.version // empty))
    ' "$INSTALLED_PLUGINS_FILE" 2>/dev/null | grep -v '^$' | sort -V | tail -1
}

INSTALLED_QUETREX="${QX_UPDATE_INSTALLED_QUETREX:-}"
[ -z "$INSTALLED_QUETREX" ] && INSTALLED_QUETREX="$(installed_version_for quetrex)"
INSTALLED_QUETREX="$(valid_version "$INSTALLED_QUETREX")"

INSTALLED_FACTORY="${QX_UPDATE_INSTALLED_FACTORY:-}"
[ -z "$INSTALLED_FACTORY" ] && INSTALLED_FACTORY="$(installed_version_for quetrex-factory)"
INSTALLED_FACTORY="$(valid_version "$INSTALLED_FACTORY")"

# Nothing we can compare -> nothing to say.
if [ -z "$INSTALLED_SETUP" ] && [ -z "$INSTALLED_QUETREX" ] && [ -z "$INSTALLED_FACTORY" ]; then
  exit 0
fi

# --- obtain the marketplace manifest (cache-first, offline-safe) -------------
mkdir -p "$CACHE_DIR" 2>/dev/null || true

cache_fresh() {
  [ -f "$CACHE_FILE" ] || return 1
  local now mtime
  now="$(date +%s)"
  # GNU stat (-c %Y) first for Linux; BSD stat (-f %m) fallback for macOS. On the
  # wrong platform `stat` can emit non-numeric output, which under `set -u` makes
  # the arithmetic below treat it as an unbound variable and abort the hook (exit 1,
  # no output) — so sanitize mtime to a plain integer before the comparison.
  mtime="$(stat -c %Y "$CACHE_FILE" 2>/dev/null || stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0)"
  case "$mtime" in ''|*[!0-9]*) mtime=0 ;; esac
  [ $((now - mtime)) -lt "$TTL_SECONDS" ]
}

MANIFEST=""
if cache_fresh; then
  # SEC-GLOBAL-1: validate on READ, not only on write — the write-time check
  # (below) does not guarantee the file was never altered or truncated
  # in between. Bound the size first so a huge cache file is never even
  # handed to node to parse.
  MANIFEST="$(bounded_valid_manifest < "$CACHE_FILE" 2>/dev/null)"
fi
if [ -z "$MANIFEST" ]; then
  FETCHED=""
  if [ -n "$MARKET_FILE" ] && [ -f "$MARKET_FILE" ]; then
    FETCHED="$(bounded_valid_manifest < "$MARKET_FILE" 2>/dev/null)"
  elif [ "$OFFLINE" != "1" ] && command -v curl >/dev/null 2>&1; then
    # --max-filesize caps the fetch itself (belt) on top of the byte-bounded
    # read below (suspenders) — a malicious/misconfigured server cannot make
    # curl buffer more than MAX_MANIFEST_BYTES in the first place.
    FETCHED="$(curl -fsS --max-time 4 --max-filesize "$MAX_MANIFEST_BYTES" "$MARKET_URL" 2>/dev/null | bounded_valid_manifest)"
  fi
  if [ -n "$FETCHED" ]; then
    MANIFEST="$FETCHED"
    printf '%s' "$MANIFEST" > "$CACHE_FILE" 2>/dev/null || true
  else
    # Fetch failed, returned junk, or exceeded the size bound — fall back to
    # whatever validated cache exists (even if stale). No cache => silent
    # success (offline, first run).
    if [ -f "$CACHE_FILE" ]; then
      MANIFEST="$(bounded_valid_manifest < "$CACHE_FILE" 2>/dev/null)"
    fi
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

LATEST_SETUP="$(valid_version "$(latest_of quetrex-setup)")"
LATEST_QUETREX="$(valid_version "$(latest_of quetrex)")"
LATEST_FACTORY="$(valid_version "$(latest_of quetrex-factory)")"

MSG=""
append_msg() { [ -n "$MSG" ] && MSG="$MSG; $1" || MSG="$1"; }

if behind "$INSTALLED_SETUP" "$LATEST_SETUP"; then
  append_msg "quetrex-setup $LATEST_SETUP available (you have $INSTALLED_SETUP)"
fi
if behind "$INSTALLED_QUETREX" "$LATEST_QUETREX"; then
  append_msg "Quetrex $LATEST_QUETREX available (you have $INSTALLED_QUETREX)"
fi
if behind "$INSTALLED_FACTORY" "$LATEST_FACTORY"; then
  append_msg "quetrex-factory $LATEST_FACTORY available (you have $INSTALLED_FACTORY)"
fi

if [ -n "$MSG" ]; then
  echo "[quetrex] ⚠ $MSG — run /quetrex-setup:update"
  exit 0
fi

# UP TO DATE -> say so explicitly. Silence used to mean two different things —
# "you are current" and "I could not check" — which is indistinguishable at the
# moment you most need to trust it. Only claim "latest" for a component whose
# latest version was actually resolved from the manifest AND whose installed
# version was actually resolved; an unresolved component is omitted rather
# than vouched for.
CONFIRM=""
append_confirm() { [ -n "$CONFIRM" ] && CONFIRM="$CONFIRM · $1" || CONFIRM="$1"; }
[ -n "$INSTALLED_SETUP" ] && [ -n "$LATEST_SETUP" ] && append_confirm "quetrex-setup $INSTALLED_SETUP"
[ -n "$INSTALLED_QUETREX" ] && [ -n "$LATEST_QUETREX" ] && append_confirm "Quetrex $INSTALLED_QUETREX"
[ -n "$INSTALLED_FACTORY" ] && [ -n "$LATEST_FACTORY" ] && append_confirm "engine $INSTALLED_FACTORY"
[ -n "$CONFIRM" ] && echo "[quetrex] ✓ $CONFIRM — latest"
exit 0
