#!/usr/bin/env bash
# quetrex-bound-version-guard.sh — SessionStart guard: is the plugin code this
# SESSION already bound to stale relative to what is now INSTALLED?
#
# WHY THIS EXISTS. A plugin's hooks are wired from its versioned cache dir at
# session launch; upgrading the marketplace does not re-bind a session already
# running. The 2026-08 incident that motivated this task was traced to exactly
# that: PATH carried `.../quetrex-factory/1.7.1/bin` while the marketplace had
# already moved to 1.7.2, so the running session kept enforcing the OLD, unfixed
# copy of every safety-floor hook (including the pre-quick-chain verify-gate.sh)
# with no visible sign anything was stale. quetrex-update-check.sh answers a
# DIFFERENT question (installed vs latest-in-marketplace, network/TTL-cached,
# at most once a day) and cannot see this at all. This guard is filesystem-only,
# fires every session, and never touches the network.
#
# HOW IT COVERS BOTH PLUGIN ROOTS FROM ONE SCRIPT. quetrex-factory ships a
# bin/ on PATH; every enabled plugin that ships one gets its VERSIONED cache
# dir prepended to the PATH of every hook process — that is exactly the
# evidence the incident was proven with. So candidate bound roots come from
# TWO sources: ${CLAUDE_PLUGIN_ROOT} (this plugin, always) and every PATH
# entry ending in /bin whose parent directory holds a .claude-plugin/plugin.json
# (any OTHER plugin, including quetrex-factory, discovered from inside a
# quetrex process without ever executing anything found there).
#
# SHOULD BE REGISTERED IN BOTH quetrex-setup AND quetrex-factory (HOOKFIX
# correction 1, 2026-08-21, verified against
# https://code.claude.com/docs/en/hooks.md) — BUT, AS OF SEC-GLOBAL-7
# (2026-08-26), IT IS CURRENTLY REGISTERED IN quetrex-setup ONLY. This is a
# real, open gap, not a documentation nit: under managed-settings
# `allowManagedHooksOnly: true`, ONLY plugins FORCE-ENABLED in managed
# settings' own enabledPlugins are exempt from the hook lockdown — every
# OTHER hook, including every hook a merely-enabled (not force-enabled)
# plugin registers, is silently blocked. An operator's managed settings can
# force-enable quetrex-factory@quetrex without force-enabling
# quetrex-setup@quetrex, and in that exact configuration this guard — which
# lives only in quetrex-setup — goes dark. quetrex-factory's own
# hooks.json (plugins/quetrex-factory/hooks/hooks.json, THIS repo) carries no
# reference to this script today; it is advisory-only (always exits 0,
# blocks nothing), so no enforcement floor is lost while this gap stands, but
# it should still be closed. The quetrex-factory-side registration belongs
# in a DIFFERENT repository, Glori-Holdings/quetrex-plugins, and is a
# cross-repo follow-up outside this workstream's file ownership — see the
# HOOKFIX developer report and .quetrex/security-findings.json (SEC-GLOBAL-7).
# Do NOT "clean up" the single registration below on the assumption a second
# one exists elsewhere in THIS repo — it does not, yet. (This file previously
# shipped inside `quetrex`; it moved to quetrex-setup with the setup-plugin
# split so it keeps firing in every repo, armed or not — see GLOBAL's plan
# notes.)
#
# SESSION DEDUP. Because it can now run TWICE in one session (both plugins
# enabled), it must not print twice for the same staleness. Keyed on the
# SessionStart payload's own `session_id` (present on stdin): the first
# invocation for a given session_id writes a marker and prints normally; a
# second invocation for the SAME session_id finds the marker and stays fully
# silent. Without a session_id (a payload that carries none) there is nothing
# to correlate a "second" invocation against, so this never guesses — it
# always evaluates and prints for real in that case.
#
# HARD RULES (never violated): always exit 0 — SessionStart output is
# non-blocking and this must never wedge a session or cry wolf. Silent when
# every bound version matches its installed version, when a version cannot be
# resolved, when installed_plugins.json is absent or malformed, and when a
# candidate root is not actually under a plugin cache. NEVER execute, source,
# or otherwise invoke anything discovered on PATH or under a plugin cache —
# every file this script touches is only ever PARSED. No network call. Prints
# AT MOST one stdout line total for the whole invocation (never one per stale
# plugin) and prints nothing to stderr.
#
# Register as: bash "${CLAUDE_PLUGIN_ROOT}/scripts/quetrex-bound-version-guard.sh"
# (repo rule: a plugin hook command resolves via ${CLAUDE_PLUGIN_ROOT}, never
# ~/.claude — reading the machine-global installed_plugins.json from INSIDE
# the script is a different layer, exactly like ${CLAUDE_PROJECT_DIR} inside
# other hooks targeting the user's repo).
#
# TEST SEAMS: QX_BOUND_INSTALLED_PLUGINS_FILE (the installed-plugins map),
# QX_BOUND_GUARD_STATE_DIR (where the session-dedup marker is written — a
# hygiene knob for test isolation, never a shortcut around real discovery),
# plus the real CLAUDE_PLUGIN_ROOT and PATH, which a test sets against a
# synthetic plugin-cache tree. No other override exists: discovery always
# walks the real filesystem shape.

set -uo pipefail

# --- SEC-GLOBAL-2 hardening --------------------------------------------------
# This guard now fires machine-wide (every SessionStart, armed repo or not —
# see the WHY THIS EXISTS note above), and its PATH walk discovers a
# .claude-plugin/plugin.json from ANY plugin that ships a bin/ on PATH, not
# only quetrex's own. That file's .name and .version are therefore hostile
# input from any such repo (direnv, .envrc, project settings env can all put
# a hostile ./bin on PATH), yet they were printed verbatim in the STALE BIND
# line. Both are validated to a plain, safe shape before resolve_plugin_json
# ever returns them; an unsafe shape is folded into the SAME "cannot be
# resolved -> skip this candidate, never guess harder" rule the fallback path
# already documents below (never executed, never sourced — this is purely
# about what reaches the final printf).
valid_plugin_name() {  # <string> -> true (0) if safely shaped
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]]
}
valid_plugin_version() {  # <string> -> true (0) if safely shaped
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][A-Za-z0-9.-]{1,40})?$ ]]
}

# --- read hook input (best-effort; absence is fine) -------------------------
INPUT=""
if [ ! -t 0 ]; then INPUT=$(cat); fi
jqget() {
  [ -n "$INPUT" ] || { printf ''; return; }
  command -v jq >/dev/null 2>&1 || { printf ''; return; }
  printf '%s' "$INPUT" | jq -r "$1 // empty" 2>/dev/null
}
SESSION_ID="$(jqget '.session_id')"

# No `set -e` and no ERR trap, deliberately: this script is written so every
# meaningful failure point is an explicit `|| return`/`|| continue`/`|| exit 0`
# check. A blanket ERR trap over command substitutions that legitimately
# return non-zero on "found nothing" (e.g. `grep -v` with zero matching
# lines, upstream of `set -o pipefail`) would abort the WHOLE script the
# instant the first candidate has no installed match, silently skipping every
# later candidate — a fail-open by accident rather than by the explicit exits
# below. Every exit point in this file is intentional; there is no implicit
# one.

# --- SESSION DEDUP: never print twice for the same session ------------------
MARKER=""
if [ -n "$SESSION_ID" ]; then
  STATE_DIR="${QX_BOUND_GUARD_STATE_DIR:-${TMPDIR:-/tmp}}"
  # A bare session_id is treated as an opaque token, never interpreted — a
  # sanity filter on shape (no path separators) keeps a hostile/malformed
  # payload from turning this into a path-traversal write.
  case "$SESSION_ID" in
    */*|*..*) SESSION_ID="" ;;
  esac
  if [ -n "$SESSION_ID" ]; then
    MARKER="$STATE_DIR/quetrex-bound-version-guard.$SESSION_ID.done"
    if [ -e "$MARKER" ]; then
      exit 0
    fi
  fi
fi

command -v jq >/dev/null 2>&1 || exit 0

# --- discover candidate BOUND plugin roots -----------------------------------
CAND_ROOTS=()
add_candidate() {
  local root="$1" existing
  [ -n "$root" ] && [ -d "$root" ] || return 0
  [ -f "$root/.claude-plugin/plugin.json" ] || return 0
  for existing in ${CAND_ROOTS[@]+"${CAND_ROOTS[@]}"}; do
    [ "$existing" = "$root" ] && return 0
  done
  CAND_ROOTS+=("$root")
}

if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  add_candidate "$CLAUDE_PLUGIN_ROOT"
fi
if [ -n "${PATH:-}" ]; then
  OLDIFS="$IFS"
  IFS=':'
  for p in $PATH; do
    case "$p" in
      */bin) add_candidate "${p%/bin}" ;;
    esac
  done
  IFS="$OLDIFS"
fi

[ "${#CAND_ROOTS[@]}" -gt 0 ] || exit 0

# --- installed_plugins.json --------------------------------------------------
INSTALLED_FILE="${QX_BOUND_INSTALLED_PLUGINS_FILE:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json}"
[ -f "$INSTALLED_FILE" ] || exit 0
jq -e . "$INSTALLED_FILE" >/dev/null 2>&1 || exit 0

installed_version_for() {  # <name> -> highest .version among "<name>@..." keys, or empty
  local name="$1"
  jq -r --arg name "$name" '
      (.plugins // {}) as $p
      | ($p | to_entries[]? | select(.key | startswith($name + "@")) | (.value[]?.version // empty))
    ' "$INSTALLED_FILE" 2>/dev/null | grep -v '^$' | sort -V | tail -1
}

# resolve_plugin_json <root> -> sets RP_NAME / RP_VERSION (both empty on failure)
resolve_plugin_json() {
  local root="$1" pj
  pj="$root/.claude-plugin/plugin.json"
  RP_NAME=""
  RP_VERSION=""
  if [ -f "$pj" ]; then
    RP_NAME="$(jq -r '.name // empty' "$pj" 2>/dev/null)"
    RP_VERSION="$(jq -r '.version // empty' "$pj" 2>/dev/null)"
  fi
  if [ -z "$RP_NAME" ] || [ -z "$RP_VERSION" ]; then
    # FALLBACK ONLY, when plugin.json is unreadable or incomplete: recover a
    # version from a versioned path segment (the exact shape the incident was
    # proven with — .../quetrex-factory/1.7.1/bin) and the name from the path
    # segment immediately preceding it. Silent (empty) if no such segment
    # exists — an unresolvable candidate is skipped, never guessed harder.
    local ver
    ver="$(printf '%s' "$root" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | tail -1)"
    if [ -n "$ver" ]; then
      local prefix name
      prefix="${root%%"$ver"*}"
      prefix="${prefix%/}"
      name="${prefix##*/}"
      [ -n "$name" ] && { RP_NAME="$name"; RP_VERSION="$ver"; }
    fi
  fi
  # SEC-GLOBAL-2: clamp before returning. An unsafely-shaped name or version
  # (from either the primary plugin.json read or the path-derived fallback)
  # is cleared to empty here so the caller's
  # `[ -n "$RP_NAME" ] && [ -n "$RP_VERSION" ] || continue` skips this
  # candidate entirely — it is never printed and never fed to installed_version_for.
  [ -n "$RP_NAME" ] && ! valid_plugin_name "$RP_NAME" && RP_NAME=""
  [ -n "$RP_VERSION" ] && ! valid_plugin_version "$RP_VERSION" && RP_VERSION=""
  return 0
}

version_lt() {  # version_lt <a> <b> -> 0 (true, a < b) if a sorts strictly before b
  local lowest
  lowest="$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)"
  [ "$lowest" = "$1" ] && [ "$1" != "$2" ]
}

STALE=()
for root in "${CAND_ROOTS[@]}"; do
  resolve_plugin_json "$root"
  [ -n "$RP_NAME" ] && [ -n "$RP_VERSION" ] || continue
  inst="$(installed_version_for "$RP_NAME")"
  [ -n "$inst" ] || continue
  # SEC-GLOBAL-2 (round 2, still open): `inst` is the THIRD value interpolated
  # into the STALE BIND printf below, read out of installed_plugins.json —
  # itself reachable via the real CLAUDE_CONFIG_DIR env var pointed at a
  # repo-controlled file, not only the QX_BOUND_* test seam. RP_NAME/
  # RP_VERSION are already clamped inside resolve_plugin_json; `inst` must be
  # clamped the same way before it can reach STALE/the printf, or it skips
  # every guard the other two fields got.
  valid_plugin_version "$inst" || continue
  if version_lt "$RP_VERSION" "$inst"; then
    STALE+=("${RP_NAME} ${RP_VERSION} (installed: ${inst})")
  fi
done

# Mark the session as evaluated BEFORE printing, so a crash mid-print on a
# second, concurrent invocation still cannot double-print (best effort; a
# missing marker just means the guard evaluates again, never worse than that).
if [ -n "$MARKER" ]; then
  mkdir -p "$(dirname "$MARKER")" 2>/dev/null
  ( umask 077; : > "$MARKER" ) 2>/dev/null
fi

[ "${#STALE[@]}" -gt 0 ] || exit 0

JOINED="$(printf '%s; ' "${STALE[@]}")"
JOINED="${JOINED%; }"
printf '[quetrex] STALE BIND: this session is running %s — plugin roots resolve once at session launch. Restart Claude Code to pick it up.\n' "$JOINED"
exit 0
