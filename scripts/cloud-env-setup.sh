#!/usr/bin/env bash
# scripts/cloud-env-setup.sh — the ONE cloud-environment setup script.
#
# WHY THIS FILE EXISTS. What a cloud environment does at boot used to live only
# in a web textarea (claude.ai/code -> environment -> Setup script): untracked,
# unreviewable, invisible to this repo's tests, and changed by hand. A stale
# snapshot of that textarea is what pinned a cloud run to an old engine and made
# a build refuse as a suspected gate bypass. So the environment's Setup script
# field must now contain exactly ONE line:
#
#     bash scripts/cloud-env-setup.sh
#
# and every change to cloud boot behaviour ships as a reviewed commit here.
#
# WHAT IT DOES, and just as importantly what it does NOT do:
#   1. Marks the cloned workspace TRUSTED. A cloud session has no trust dialog
#      and nobody to accept it, so an untrusted workspace makes Claude Code
#      DISCARD the repo's .claude/settings.json wholesale -- extraKnownMarketplaces
#      is never applied, enabledPlugins entries are silently skipped as orphaned,
#      and permissions.allow is dropped. One cause, three defects. (Measured
#      2026-08-24; the error text names this remedy itself.)
#   2. Writes the long Bash tool timeouts into ~/.claude/settings.json (USER
#      scope). A cloud container ships with no user settings file at all, and the
#      project one is what gets discarded, so user scope is the only place these
#      survive. Without them a >2-minute verify command (a real app's suite,
#      build, or E2E) is killed at the 2-minute default and re-launched, running
#      the same suite two or three times per stage.
#   3. It does NOT install plugins. Once the workspace is trusted the repo's own
#      settings.json installs the current engine at session start, which is the
#      whole point: pinning an install here is what went stale before.
#
# Idempotent, safe to re-run, and LOUD on failure -- an environment that boots
# half-configured must fail visibly, never silently produce an unarmed session.
set -uo pipefail

log() { printf 'cloud-env-setup: %s\n' "$1"; }
die() { printf 'cloud-env-setup: FAILED: %s\n' "$1" >&2; exit 1; }

# The workspace can be reachable under more than one path -- a symlinked mount
# (/var -> /private/var is the everyday example) makes `git rev-parse
# --show-toplevel` hand back the PHYSICAL path while the launcher may key trust
# on the LOGICAL one it cd'd into. Trust recorded under the other spelling is
# trust that silently does not apply, and an untrusted workspace is exactly the
# failure this script exists to prevent -- so record every distinct spelling.
WORKSPACE="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "$PWD")"
[ -n "$WORKSPACE" ] && [ -d "$WORKSPACE" ] || die "cannot resolve the workspace directory (PWD=$PWD)"
WORKSPACE_PATHS="$WORKSPACE"
for cand in "$PWD" "$(cd "$WORKSPACE" 2>/dev/null && pwd -P)" "$(cd "$PWD" 2>/dev/null && pwd -P)"; do
  [ -n "$cand" ] || continue
  case ":$WORKSPACE_PATHS:" in *":$cand:"*) ;; *) WORKSPACE_PATHS="$WORKSPACE_PATHS:$cand" ;; esac
done
HOME_DIR="${HOME:?HOME is unset}"
CLAUDE_JSON="$HOME_DIR/.claude.json"
SETTINGS="$HOME_DIR/.claude/settings.json"

# One JSON editor, chosen once. jq first (present in most images); python3 as the
# fallback. Neither present is a hard failure -- editing JSON with sed is how a
# config file gets silently corrupted.
if command -v jq >/dev/null 2>&1; then JSON_TOOL=jq
elif command -v python3 >/dev/null 2>&1; then JSON_TOOL=python3
else die "neither jq nor python3 is available; cannot edit JSON safely"
fi
log "using $JSON_TOOL"

json_merge() {  # json_merge <file> <jq-filter> <python-expr-on-'d'>
  local file="$1" filter="$2" pyexpr="$3" tmp
  mkdir -p "$(dirname "$file")" || die "cannot create $(dirname "$file")"
  # A NEW file here may hold credentials (~/.claude.json carries oauthAccount),
  # so create it private rather than at whatever the ambient umask allows.
  [ -f "$file" ] || ( umask 077; printf '{}\n' > "$file" )
  tmp="$file.cloud-env-setup.$$"
  # PRESERVE THE ORIGINAL MODE. Writing jq output to a fresh temp and mv-ing it
  # over the target replaces the file with one created at the ambient umask --
  # measured downgrading ~/.claude.json from 0600 to 0644, world-readable, with
  # the operator's oauthAccount inside. Seeding the temp with `cp -p` gives it
  # the original's mode; the redirect truncates its CONTENT but leaves that mode
  # intact, and mv carries it back. Found by security review.
  # `cp -p` is the clean way to inherit the mode; if cp is unavailable, fall
  # back to a PRIVATE temp (0600) rather than the ambient umask -- erring
  # tighter than the original is safe, erring looser is the bug being fixed.
  cp -p "$file" "$tmp" 2>/dev/null || ( umask 077; : > "$tmp" ) || { rm -f "$tmp"; die "cannot stage a replacement for $file"; }
  # Belt and braces: a cp that fails PART WAY can leave a temp it already
  # created at the ambient umask, and the `||` fallback cannot tighten a file
  # that now exists. These are per-user config files (one holds oauthAccount),
  # so owner-only is always correct -- never let group/other survive here.
  chmod go-rwx "$tmp" 2>/dev/null || true
  if [ "$JSON_TOOL" = jq ]; then
    jq --arg ws "$WORKSPACE" "$filter" "$file" > "$tmp" || { rm -f "$tmp"; die "jq failed on $file"; }
  else
    WS="$WORKSPACE" python3 -c '
import json, os, sys
path, expr = sys.argv[1], sys.argv[2]
with open(path) as fh:
    try: d = json.load(fh)
    except Exception: d = {}
if not isinstance(d, dict): d = {}
ws = os.environ["WS"]
exec(expr)
with open(sys.argv[3], "w") as fh:
    json.dump(d, fh, indent=2)
    fh.write("\n")
' "$file" "$pyexpr" "$tmp" || { rm -f "$tmp"; die "python3 failed on $file"; }
  fi
  mv "$tmp" "$file" || { rm -f "$tmp"; die "cannot replace $file"; }
}

# 1. Trust the workspace, under every spelling it is reachable by.
_saved_ws="$WORKSPACE"
IFS=: read -r -a _ws_list <<< "$WORKSPACE_PATHS"
for WORKSPACE in "${_ws_list[@]}"; do
  [ -n "$WORKSPACE" ] || continue
  json_merge "$CLAUDE_JSON" \
    '.projects = ((.projects // {}) | .[$ws] = ((.[$ws] // {}) | .hasTrustDialogAccepted = true))' \
    'd.setdefault("projects", {}).setdefault(ws, {})["hasTrustDialogAccepted"] = True'
  log "trusted workspace $WORKSPACE"
done
WORKSPACE="$_saved_ws"

# 2. Long Bash tool timeouts at user scope (see the header for why user scope).
json_merge "$SETTINGS" \
  '.env = ((.env // {}) | .BASH_DEFAULT_TIMEOUT_MS = "900000" | .BASH_MAX_TIMEOUT_MS = "1800000")' \
  'd.setdefault("env", {}).update({"BASH_DEFAULT_TIMEOUT_MS": "900000", "BASH_MAX_TIMEOUT_MS": "1800000"})'
log "set BASH_DEFAULT_TIMEOUT_MS=900000 BASH_MAX_TIMEOUT_MS=1800000 in $SETTINGS"

# 3. Prove both landed. A setup script that "ran" but configured nothing is the
#    failure mode this whole file exists to end, so read the files back.
verify() {  # verify <file> <jq-test> <python-test>
  if [ "$JSON_TOOL" = jq ]; then jq -e --arg ws "$WORKSPACE" "$2" "$1" >/dev/null 2>&1
  else WS="$WORKSPACE" python3 -c '
import json, os, sys
d = json.load(open(sys.argv[1])); ws = os.environ["WS"]
sys.exit(0 if eval(sys.argv[2]) else 1)
' "$1" "$3"; fi
}
_saved_ws="$WORKSPACE"
for WORKSPACE in "${_ws_list[@]}"; do
  [ -n "$WORKSPACE" ] || continue
  verify "$CLAUDE_JSON" '.projects[$ws].hasTrustDialogAccepted == true' \
    'd.get("projects", {}).get(ws, {}).get("hasTrustDialogAccepted") is True' \
    || die "workspace trust did not persist for $WORKSPACE in $CLAUDE_JSON"
done
WORKSPACE="$_saved_ws"
verify "$SETTINGS" '.env.BASH_DEFAULT_TIMEOUT_MS == "900000"' \
  'd.get("env", {}).get("BASH_DEFAULT_TIMEOUT_MS") == "900000"' \
  || die "timeouts did not persist in $SETTINGS"

log "OK - workspace trusted, timeouts set, no plugins installed (the repo's settings.json installs the current engine at session start)"
