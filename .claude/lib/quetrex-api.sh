# shellcheck shell=bash
#
# quetrex-api.sh — shared API foundation for Quetrex terminal skills.
#
# SOURCE, do not execute:
#     source ~/.claude/lib/quetrex-api.sh
#
# Provides three functions consumed by every Phase 2 skill:
#     resolve_auth     — load + validate machine auth, set QX_KANBAN_URL + _QX_TOKEN
#     resolve_project  — find the repo's project binding, set QX_PROJECT_CODE
#     qapi             — token-safe curl wrapper for the kanban API
#
# ---------------------------------------------------------------------------
# CONTRACTS (consumed here, never written here — owned by /quetrex-login and
# /quetrex-init). Two JSON files, two shapes:
#
#   AUTH — machine level, outside any repo:  ~/.quetrex/auth.json
#     {
#       "kanbanUrl":  "https://dash.quetrex.com",
#       "token":      "<per-user bearer token>",
#       "expiresAt":  "<iso8601>"
#     }
#   Written by /quetrex-login. `token` is the per-user api_token minted by the
#   kanban device-flow. Read here via resolve_auth.
#
#   PROJECT BINDING — committed per repo:  ./.quetrex/project.json
#     {
#       "projectCode": "SMA",
#       "kanbanUrl":   "https://dash.quetrex.com"
#     }
#   Written by /quetrex-init, committed. Read here via resolve_project, which
#   walks up the directory tree from $PWD to find it.
#
# ---------------------------------------------------------------------------
# TOKEN SAFETY — the single most important invariant of this file:
#
#   The bearer token is NEVER printed to stdout/stderr, NEVER written to a log,
#   NEVER passed on a command line (so it cannot appear in `ps aux`), and is
#   NEVER exposed by `curl -v` or a shell `set -x` trace. It lives only in
#   _QX_TOKEN (in-process) and, transiently, in a 0600 temp curl config file
#   that is removed with an explicit `rm` the instant curl returns (no trap —
#   see qapi for why; zsh has no RETURN pseudo-signal). Do not add `set -x`,
#   `-v`, or `echo "$_QX_TOKEN"` anywhere in this file or in callers, and do
#   not replace the explicit `rm` with a trap.
#
# ---------------------------------------------------------------------------
# Module-level state (set by the resolvers, read by qapi):
#     QX_KANBAN_URL    base URL (source of truth = auth.json)
#     QX_PROJECT_CODE  project code from project.json
#     _QX_TOKEN        bearer token (underscore = "private"; never echoed)
#
# Requirements: curl (present on macOS/Linux) and node (>=18, guaranteed by the
# package `engines`). No jq / python3 dependency — JSON + date math use node.
# ---------------------------------------------------------------------------

# _qx_json_get <file> <dot.path>
#   Print one field value from a JSON file. Exit 1 if the file is unreadable,
#   not valid JSON, or the path resolves to null/undefined.
_qx_json_get() {
  node -e '
    const fs = require("fs");
    const [f, p] = process.argv.slice(1);
    let o;
    try { o = JSON.parse(fs.readFileSync(f, "utf8")); } catch { process.exit(1); }
    const v = p.split(".").reduce((a, k) => (a == null ? a : a[k]), o);
    if (v == null) { process.exit(1); }
    process.stdout.write(String(v));
  ' "$1" "$2"
}

# resolve_auth
#   Read ~/.quetrex/auth.json; validate presence, fields, and non-expiry.
#   Sets QX_KANBAN_URL and _QX_TOKEN. On any failure prints "Run /quetrex-login"
#   to stderr and returns 1.
resolve_auth() {
  local f="$HOME/.quetrex/auth.json"
  if [ ! -f "$f" ]; then
    echo "Run /quetrex-login" >&2
    return 1
  fi

  QX_KANBAN_URL="$(_qx_json_get "$f" kanbanUrl)" || { echo "Run /quetrex-login" >&2; return 1; }
  _QX_TOKEN="$(_qx_json_get "$f" token)"         || { echo "Run /quetrex-login" >&2; return 1; }

  local exp
  exp="$(_qx_json_get "$f" expiresAt)" || { echo "Run /quetrex-login" >&2; return 1; }

  # Expired? node date math, no jq dependency. exit 0 = still valid.
  if ! node -e 'process.exit(new Date(process.argv[1]) > new Date() ? 0 : 1)' "$exp"; then
    echo "Run /quetrex-login" >&2
    return 1
  fi

  return 0
}

# qx_binding_path
#   Print the absolute path of the repo's .quetrex/project.json by walking up from
#   $PWD — the same walk resolve_project uses. Useful for skills that need to READ
#   or WRITE non-secret binding fields (e.g. /deploy's deploy config). Prints the
#   path on stdout and returns 0 if found; prints nothing and returns 1 on miss.
#   Never reads or emits any secret — the binding holds only projectCode/kanbanUrl
#   (and non-secret deploy config). Token-safe: touches no auth state.
qx_binding_path() {
  local dir="$PWD"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/.quetrex/project.json" ]; then
      printf '%s\n' "$dir/.quetrex/project.json"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

# resolve_project
#   Walk up from $PWD to find .quetrex/project.json. Sets QX_PROJECT_CODE.
#   Keeps auth.json's kanbanUrl as the source of truth, falling back to the
#   binding's kanbanUrl only if auth has not set one. On miss prints
#   "Run /quetrex-init" to stderr and returns 1.
resolve_project() {
  local dir="$PWD" f=""
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/.quetrex/project.json" ]; then
      f="$dir/.quetrex/project.json"
      break
    fi
    dir="$(dirname "$dir")"
  done

  if [ -z "$f" ]; then
    echo "Run /quetrex-init" >&2
    return 1
  fi

  # consumed by skill callers, not internally — hence the disable.
  # shellcheck disable=SC2034
  QX_PROJECT_CODE="$(_qx_json_get "$f" projectCode)" || { echo "Run /quetrex-init" >&2; return 1; }

  # auth's kanbanUrl wins; only fall back to the binding if auth set nothing.
  if [ -z "${QX_KANBAN_URL:-}" ]; then
    QX_KANBAN_URL="$(_qx_json_get "$f" kanbanUrl)" || { echo "Run /quetrex-init" >&2; return 1; }
  fi

  return 0
}

# qapi <METHOD> <PATH> [json_body]
#   Token-safe curl wrapper. Requires resolve_auth (and usually resolve_project)
#   to have run first.
#     - injects the bearer via a 0600 temp curl config file (-K), so the token
#       never appears in argv/stdout/logs; that config file is wiped the instant
#       curl returns (explicit rm — portable across bash and zsh; zsh's `trap`
#       has no RETURN pseudo-signal, so we never rely on a trap for the wipe).
#     - 401      -> "Run /quetrex-login" (stderr), return 1
#     - 403/404  -> "No access — contact your administrator" (stderr), return 1
#     - other non-2xx -> "Quetrex API error (HTTP <code>)" (stderr), return 1
#     - 2xx      -> prints the JSON response body to stdout, return 0
qapi() {
  # NOTE: do not name a local `path` — zsh ties lowercase `path` to $PATH and
  # would clobber command lookup inside this function. Use `endpoint`.
  local method="$1" endpoint="$2" body="${3:-}"
  local url="${QX_KANBAN_URL}${endpoint}"
  local cfg bodyf code rc=1

  cfg="$(mktemp)"   || { echo "Quetrex API error (temp file)" >&2; return 1; }
  bodyf="$(mktemp)" || { rm -f "$cfg"; echo "Quetrex API error (temp file)" >&2; return 1; }
  # Both temp files may hold sensitive bytes: cfg the bearer token, bodyf the
  # response body (which for /secrets/export is the vault map). Lock both to 0600
  # on creation and rm -f each on every return path below.
  chmod 600 "$cfg" "$bodyf"

  # The token's only on-disk home: a 0600 curl config (-K), never on argv.
  printf 'header = "Authorization: Bearer %s"\n' "$_QX_TOKEN" > "$cfg"

  if [ -n "$body" ]; then
    code="$(curl -sS -K "$cfg" \
      -H 'Content-Type: application/json' \
      -X "$method" --data "$body" \
      -o "$bodyf" -w '%{http_code}' "$url")"
  else
    code="$(curl -sS -K "$cfg" \
      -X "$method" \
      -o "$bodyf" -w '%{http_code}' "$url")"
  fi

  # Token's on-disk copy is no longer needed — wipe it before doing anything else.
  rm -f "$cfg"

  case "$code" in
    2*)
      cat "$bodyf"
      rc=0
      ;;
    401)
      echo "Run /quetrex-login" >&2
      ;;
    403 | 404)
      echo "No access — contact your administrator" >&2
      ;;
    *)
      echo "Quetrex API error (HTTP $code)" >&2
      ;;
  esac

  rm -f "$bodyf"
  return "$rc"
}
