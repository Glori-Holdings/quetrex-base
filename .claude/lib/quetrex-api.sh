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
# CONTRACTS (consumed here, never written here — owned by /quetrex:login and
# /quetrex:init). Two JSON files, two shapes:
#
#   AUTH — machine level, outside any repo:  ~/.quetrex/auth.json
#     {
#       "kanbanUrl":  "https://dash.quetrex.com",
#       "token":      "<per-user bearer token>",
#       "expiresAt":  "<iso8601>"
#     }
#   Written by /quetrex:login. `token` is the per-user api_token minted by the
#   kanban device-flow. Read here via resolve_auth.
#
#   PROJECT BINDING — committed per repo:  ./.quetrex/project.json
#     {
#       "projectCode": "SMA",
#       "kanbanUrl":   "https://dash.quetrex.com"
#     }
#   Written by /quetrex:init, committed. Read here via resolve_project, which
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
#   Sets QX_KANBAN_URL and _QX_TOKEN. On any failure prints "Run /quetrex:login"
#   to stderr and returns 1.
resolve_auth() {
  local f="$HOME/.quetrex/auth.json"
  if [ ! -f "$f" ]; then
    echo "Run /quetrex:login" >&2
    return 1
  fi

  QX_KANBAN_URL="$(_qx_json_get "$f" kanbanUrl)" || { echo "Run /quetrex:login" >&2; return 1; }
  _QX_TOKEN="$(_qx_json_get "$f" token)"         || { echo "Run /quetrex:login" >&2; return 1; }

  local exp
  exp="$(_qx_json_get "$f" expiresAt)" || { echo "Run /quetrex:login" >&2; return 1; }

  # Expired? node date math, no jq dependency. exit 0 = still valid.
  if ! node -e 'process.exit(new Date(process.argv[1]) > new Date() ? 0 : 1)' "$exp"; then
    echo "Run /quetrex:login" >&2
    return 1
  fi

  return 0
}

# qx_binding_path
#   Print the absolute path of the repo's .quetrex/project.json by walking up from
#   $PWD — the same walk resolve_project uses. Useful for skills that need to READ
#   or WRITE non-secret binding fields (e.g. /quetrex:deploy's deploy config). Prints the
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
#   "Run /quetrex:init" to stderr and returns 1.
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
    echo "Run /quetrex:init" >&2
    return 1
  fi

  # consumed by skill callers, not internally — hence the disable.
  # shellcheck disable=SC2034
  QX_PROJECT_CODE="$(_qx_json_get "$f" projectCode)" || { echo "Run /quetrex:init" >&2; return 1; }

  # auth's kanbanUrl wins; only fall back to the binding if auth set nothing.
  if [ -z "${QX_KANBAN_URL:-}" ]; then
    QX_KANBAN_URL="$(_qx_json_get "$f" kanbanUrl)" || { echo "Run /quetrex:init" >&2; return 1; }
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
#     - 401      -> "Run /quetrex:login" (stderr), return 1
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
      echo "Run /quetrex:login" >&2
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

# ---------------------------------------------------------------------------
# CONVENIENCE WRAPPERS over qapi (added for /quetrex:task-build + /quetrex:task-rework).
#
# Each helper builds its JSON body with node/JSON.stringify (never echo, never
# hand-built strings) and routes through qapi, so every one INHERITS qapi's
# token safety: the bearer is never echoed, logged, or placed on argv. Call
# resolve_auth (and, where a helper uses QX_PROJECT_CODE, resolve_project)
# first. These are consumed by command callers, not within this file — hence the
# per-function SC2329 disables marking them as "never invoked here".
# ---------------------------------------------------------------------------

# qx_task_status TASK_ID STATUS  -> PATCH /api/tasks/$ID {status}
# shellcheck disable=SC2329
qx_task_status() {
  local body
  body="$(node -e 'process.stdout.write(JSON.stringify({status:process.argv[1]}))' "$2")" || return 1
  qapi PATCH "/api/tasks/$1" "$body" >/dev/null
}

# qx_task_ainote TASK_ID NOTE  -> PATCH /api/tasks/$ID {aiNotes}  (AI-notes are PATCH)
# shellcheck disable=SC2329
qx_task_ainote() {
  local body
  body="$(node -e 'process.stdout.write(JSON.stringify({aiNotes:process.argv[1]}))' "$2")" || return 1
  qapi PATCH "/api/tasks/$1" "$body" >/dev/null
}

# qx_task_comment TASK_ID BODY  -> POST /api/tasks/$ID/comments {body}
# shellcheck disable=SC2329
qx_task_comment() {
  local body
  body="$(node -e 'process.stdout.write(JSON.stringify({body:process.argv[1]}))' "$2")" || return 1
  qapi POST "/api/tasks/$1/comments" "$body" >/dev/null
}

# qx_task_type TASK_ID TYPE  -> PATCH /api/tasks/$ID {type}  (classification label)
# shellcheck disable=SC2329
qx_task_type() {
  local body
  body="$(node -e 'process.stdout.write(JSON.stringify({type:process.argv[1]}))' "$2")" || return 1
  qapi PATCH "/api/tasks/$1" "$body" >/dev/null
}

# qx_create_child EPIC_ID TITLE DESC
#   POST /api/tasks {parentTaskId, projectCode, title, description}. Prints the
#   new child's human identifier (CODE-N.C) on stdout; returns 1 on failure.
#   Requires QX_PROJECT_CODE (resolve_project). EPIC_ID is the parent's human id.
# shellcheck disable=SC2329,SC2016
qx_create_child() {
  local parent_ref title desc parent_json parent_meta parent_uuid parent_code parent_child body resp ident

  parent_ref="$(_qx_trim "${1-}")"
  title="$(_qx_trim "${2-}")"
  desc="${3-}"

  if [ -z "$parent_ref" ]; then
    echo "quetrex-api create-child: missing epic id (argument 1). Refusing to create anything — an empty parent makes the server create a TOP-LEVEL task, and a task cannot be deleted." >&2
    return 1
  fi
  if [ -z "$title" ]; then
    echo "quetrex-api create-child: missing child title (argument 2). Refusing to create anything." >&2
    return 1
  fi
  if [ -z "${QX_PROJECT_CODE:-}" ]; then
    echo "Run /quetrex:init" >&2
    return 1
  fi

  # Prove the parent exists and get the id the API actually links by.
  parent_json="$(_qx_task_json "$parent_ref")" || {
    echo "quetrex-api create-child: parent task '$parent_ref' could not be read. Refusing to create a child that would land as a top-level task." >&2
    return 1
  }

  # uuid US projectCode US childNumber ("" when top-level) US identifier, where
  # US is \037. NOT tab: tab is IFS *whitespace*, so bash collapses a run of
  # them into one delimiter and drops empty fields — a top-level parent (empty
  # childNumber) would shift `identifier` into `parent_child` and trip the
  # grandchild guard on every single valid parent. \037 is non-whitespace, so
  # every field position is preserved exactly, empty or not.
  parent_meta="$(node -e '
    let o; try { o = JSON.parse(process.argv[1]); } catch { process.exit(1); }
    const id = typeof o.id === "string" ? o.id : "";
    if (!/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(id)) {
      process.exit(2);
    }
    process.stdout.write([
      id,
      o.projectCode == null ? "" : String(o.projectCode),
      o.childNumber == null ? "" : String(o.childNumber),
      o.identifier == null ? "" : String(o.identifier),
    ].join("\u001f"));
  ' "$parent_json")" || {
    echo "quetrex-api create-child: parent task '$parent_ref' came back without a usable UUID id. Refusing to create a child." >&2
    return 1
  }

  IFS=$'\037' read -r parent_uuid parent_code parent_child ident <<<"$parent_meta"

  # One level only — an epic decomposes once; children have no children.
  if [ -n "$parent_child" ]; then
    echo "quetrex-api create-child: '${ident:-$parent_ref}' is itself a child (childNumber=$parent_child). Epics decompose ONE level — no grandchildren. Refusing to create anything." >&2
    return 1
  fi

  # A cross-project parent is a 404 at the server; say what actually happened.
  if [ -n "$parent_code" ] && [ "$parent_code" != "$QX_PROJECT_CODE" ]; then
    echo "quetrex-api create-child: parent '${ident:-$parent_ref}' belongs to project $parent_code, but this repo is bound to $QX_PROJECT_CODE. Refusing to create anything." >&2
    return 1
  fi

  # parentTaskId is the parent's UUID — never its human identifier.
  body="$(node -e '
    const [parentTaskId, projectCode, title, description] = process.argv.slice(1);
    const b = { parentTaskId, projectCode, title };
    if (description) { b.description = description; }
    process.stdout.write(JSON.stringify(b));
  ' "$parent_uuid" "$QX_PROJECT_CODE" "$title" "$desc")" || return 1

  resp="$(qapi POST /api/tasks "$body")" || return 1

  # Trust nothing: a 201 proves a task was created, not that it was created as
  # a CHILD. Print the identifier only if the link is really there.
  node -e '
    let o; try { o = JSON.parse(process.argv[1]); } catch { process.exit(1); }
    const parentUuid = process.argv[2];
    const parentRef = process.argv[3];
    const code = o.projectCode || o.code || "";
    const ident = o.identifier
      || (code && o.number != null
        ? `${code}-${o.number}${o.childNumber != null ? "." + o.childNumber : ""}`
        : "");
    const linked = typeof o.parentTaskId === "string"
      && o.parentTaskId.toLowerCase() === parentUuid.toLowerCase();
    if (!linked || o.childNumber == null) {
      process.stderr.write(
        `quetrex-api create-child: the server created ${ident || "a task"} as a TOP-LEVEL task ` +
        `(parentTaskId=${JSON.stringify(o.parentTaskId ?? null)}, childNumber=${JSON.stringify(o.childNumber ?? null)}) ` +
        `instead of a child of ${parentRef}. A task cannot be deleted — reconcile the board before retrying.\n`);
      process.exit(3);
    }
    if (!/^[A-Za-z][A-Za-z0-9]*-\d+\.\d+$/.test(ident)) {
      process.stderr.write(
        `quetrex-api create-child: the created child has no CODE-N.C identifier (got ${JSON.stringify(ident)}). ` +
        `The dispatcher and /quetrex:merge key off that shape.\n`);
      process.exit(4);
    }
    process.stdout.write(ident + "\n");
  ' "$resp" "$parent_uuid" "${ident:-$parent_ref}"
}

# qx_add_dep TASK_ID DEPENDS_ON_ID  -> POST /api/tasks/$ID/dependencies {dependsOnTaskId}
#   The server is cycle-safe, but the caller still DAG-validates the proposed
#   graph before any write (see /quetrex:task-build).
# shellcheck disable=SC2329
qx_add_dep() {
  local task_ref dep_ref task_uuid dep_uuid body

  task_ref="$(_qx_trim "${1-}")"
  dep_ref="$(_qx_trim "${2-}")"

  if [ -z "$task_ref" ]; then
    echo "quetrex-api add-dep: missing task id (argument 1). Refusing to call the API." >&2
    return 1
  fi
  if [ -z "$dep_ref" ]; then
    echo "quetrex-api add-dep: missing dependency id (argument 2). Refusing to call the API." >&2
    return 1
  fi

  task_uuid="$(_qx_task_uuid "$task_ref")" || return 1
  dep_uuid="$(_qx_task_uuid "$dep_ref")" || return 1

  if [ "$task_uuid" = "$dep_uuid" ]; then
    echo "quetrex-api add-dep: '$task_ref' cannot depend on itself." >&2
    return 1
  fi

  # shellcheck disable=SC2016
  body="$(node -e 'process.stdout.write(JSON.stringify({dependsOnTaskId:process.argv[1]}))' "$dep_uuid")" || return 1
  qapi POST "/api/tasks/$task_uuid/dependencies" "$body" >/dev/null
}

# qx_is_unblocked TASK_ID  -> exit 0 if ready to start, 1 if still blocked.
#   Readiness predicate for the DAG dispatch. Prefers the server's isBlocked
#   flag on the task record; falls back to checking that every dependency's
#   status is in DONE_FOR_UNBLOCKING = {merged, deployed, complete}. Re-poll
#   after each child auto-merge to refill the ready set.
# shellcheck disable=SC2329
qx_is_unblocked() {
  local ref task rc
  ref="$(_qx_trim "${1-}")"
  if [ -z "$ref" ]; then
    echo "quetrex-api is-unblocked: missing task id — readiness UNDETERMINED." >&2
    return 2
  fi
  task="$(qapi GET "/api/tasks/$ref")" || {
    echo "quetrex-api is-unblocked: could not read '$ref' — readiness UNDETERMINED (do not dispatch)." >&2
    return 2
  }
  node -e '
    let o; try { o = JSON.parse(process.argv[1]); } catch { process.exit(2); }
    if (o == null || typeof o !== "object") { process.exit(2); }
    const DONE = new Set(["merged", "deployed", "complete"]);
    if (typeof o.isBlocked === "boolean") { process.exit(o.isBlocked ? 1 : 0); }
    const deps = Array.isArray(o.dependencies) ? o.dependencies : [];
    for (const d of deps) {
      const st = (d && (d.status || (d.task && d.task.status))) || "";
      if (!DONE.has(st)) { process.exit(1); }
    }
    process.exit(0);
  ' "$task"
  rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "quetrex-api is-unblocked: '$ref' came back in an unreadable shape — readiness UNDETERMINED (do not dispatch)." >&2
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# ENV-CRED AUTO-DETECT helpers (used by /quetrex:init and /quetrex:deploy).
#
# These let a command discover credentials already on disk in the repo's local
# env files and import them straight into the project vault WITHOUT ever echoing
# a secret value. The single security invariant: a secret VALUE is only ever
# read inside node, straight from the file, and handed to qapi as a JSON body —
# it never appears on this file's argv (as a value), on stdout, or in any log.
# The only value-derived output is a masked last-4 tail. Token-safe: inherits
# qapi's bearer protection. Consumed by command callers, not here — SC2329.
# ---------------------------------------------------------------------------

# qx_env_scan DIR
#   Scan DIR for .env, .env.local and .env.* (skipping *.example / *.sample) and
#   print one tab-separated line per relevant credential discovered:
#       <FILE>\t<RAWNAME>\t<CANON>\t****<last4>
#   FILE = absolute env-file path, RAWNAME = the key as written in the file,
#   CANON = the vault's canonical name (e.g. FLY_TOKEN -> FLY_API_TOKEN), and a
#   MASKED tail (last 4 chars) only. The full secret VALUE is NEVER printed. All
#   parsing happens in node; the file is never cat/echo'd. On a variant/canonical
#   collision (e.g. both FLY_TOKEN and FLY_API_TOKEN present) the canonical wins
#   and the variant is skipped. Later definitions win (mirrors dotenv).
# shellcheck disable=SC2329,SC2016
qx_env_scan() {
  node -e '
    const fs=require("fs"), path=require("path");
    const dir=process.argv[1];
    const NORM={FLY_TOKEN:"FLY_API_TOKEN"};
    const isRelevant=(k)=>
      /(_API_KEY|_SECRET|_TOKEN|_KEY|_PASSWORD|_DSN)$/.test(k)
      || /^(DATABASE_URL|FLY_API_TOKEN|FLY_TOKEN|OPENAI_API_KEY|ANTHROPIC_API_KEY)$/.test(k)
      || /^(STRIPE_|NEON_)/.test(k);
    let files=[];
    try {
      for (const f of fs.readdirSync(dir)) {
        if (f!==".env" && !f.startsWith(".env.")) continue;
        if (/\.(example|sample)$/i.test(f)) continue;
        files.push(path.join(dir,f));
      }
    } catch { process.exit(0); }
    files.sort();
    const found=new Map();   // CANON -> {file, raw, value}
    for (const file of files) {
      let txt; try { txt=fs.readFileSync(file,"utf8"); } catch { continue; }
      for (let line of txt.split(/\r?\n/)) {
        line=line.replace(/^\s*export\s+/,"").trim();
        if (!line || line.startsWith("#")) continue;
        const eq=line.indexOf("="); if (eq<0) continue;
        const k=line.slice(0,eq).trim();
        let v=line.slice(eq+1).trim();
        if ((v.startsWith("\"")&&v.endsWith("\"")) || (v.startsWith("'\''")&&v.endsWith("'\''"))) v=v.slice(1,-1);
        if (!k || !v || !isRelevant(k)) continue;
        const canon=NORM[k]||k;
        const newIsVariant=(NORM[k]!==undefined);
        const existing=found.get(canon);
        if (existing) {
          const existingIsVariant=(existing.raw!==canon);
          if (newIsVariant && !existingIsVariant) continue;   // canonical beats variant
        }
        found.set(canon,{file,raw:k,value:v});
      }
    }
    for (const [canon,info] of found) {
      const v=info.value;
      const last4=v.length>=4 ? v.slice(-4) : v;
      process.stdout.write(`${info.file}\t${info.raw}\t${canon}\t****${last4}\n`);
    }
  ' "$1"
}

# qx_secret_put_from_env ENVFILE RAWNAME CANON
#   Read RAWNAME's value straight from ENVFILE inside node, build the JSON body
#   {name:CANON, value:<value>} with JSON.stringify, and PUT it to the project
#   vault via qapi. The secret VALUE is sourced inside node from the file and is
#   never passed as a shell-visible argv value, never echoed, never logged — only
#   the non-secret ENVFILE / RAWNAME / CANON are passed in. Requires
#   QX_PROJECT_CODE (resolve_project). Returns non-zero on failure.
# shellcheck disable=SC2329
qx_secret_put_from_env() {
  local body rc
  body="$(node -e '
    const fs=require("fs");
    const [file,raw,canon]=process.argv.slice(1);
    let txt; try { txt=fs.readFileSync(file,"utf8"); } catch { process.exit(1); }
    let val=null;
    for (let line of txt.split(/\r?\n/)) {
      line=line.replace(/^\s*export\s+/,"").trim();
      if (!line || line.startsWith("#")) continue;
      const eq=line.indexOf("="); if (eq<0) continue;
      const k=line.slice(0,eq).trim();
      if (k!==raw) continue;
      let v=line.slice(eq+1).trim();
      if ((v.startsWith("\"")&&v.endsWith("\"")) || (v.startsWith("'\''")&&v.endsWith("'\''"))) v=v.slice(1,-1);
      val=v;   // keep scanning so the LAST definition wins
    }
    if (val==null) { process.exit(1); }
    process.stdout.write(JSON.stringify({name:canon,value:val}));
  ' "$1" "$2" "$3")" || return 1
  qapi PUT "/api/projects/$QX_PROJECT_CODE/secrets" "$body" >/dev/null
  rc=$?
  unset body
  return "$rc"
}
