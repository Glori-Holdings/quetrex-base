---
description: Deploy this project's app using its vault secrets (Fly.io for v1). Interviews for deploy config on first run, fetches secrets in-memory, runs the deploy token-safely. Usage: /deploy [staging|production]
argument-hint: "[environment: staging | production]"
---

# Deploy

Deploy this project's app using its **vault secrets** from the Quetrex kanban. v1 supports
**Fly.io** only, but the flow branches on `provider` so other platforms can be added later.

**SECRET SAFETY — the core invariant of this command:**
- Vault secret VALUES live ONLY in process memory (one shell variable). They are NEVER
  written to disk, NEVER echoed/`cat`/redirected, NEVER printed (keys or values).
- The Fly API token and runtime secrets are passed to `fly` inline per-command or via STDIN,
  never on a logged line and never on argv where `ps` could see them.
- The deploy config written to `.quetrex/project.json` contains **non-secret fields only**
  (provider, app name, environments, needsDb, and `runtimeSecrets` — an allowlist of secret
  NAMES, never values) — never any key or token.
- Only the **allowlisted** runtime secrets are ever pushed to the deployed app. Pipeline-only
  creds (the Fly token, GitHub/CI tokens, the Quetrex bearer, etc.) are used by the deploy
  process and are NEVER exposed in the app's runtime environment.
- No `set -x`, no `curl -v`, no `fly` verbose flags. The sensitive vars are `unset` at the end.

Argument: `$ARGUMENTS` is an optional environment, `staging` or `production`.

---

## 1. Parse the optional environment argument

```bash
ENV_ARG="$(echo "$ARGUMENTS" | tr -d '[:space:]')"
```

Validated later against the project's configured environments. May be empty.

---

## 2. Source the helper and resolve context

```bash
source ~/.claude/lib/quetrex-api.sh
resolve_auth    || exit 1
resolve_project || exit 1
BIND="$(qx_binding_path)" || { echo "Run /quetrex-init" >&2; exit 1; }
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || dirname "$(dirname "$BIND")")"
echo "Project: $QX_PROJECT_CODE @ $QX_KANBAN_URL"
```

---

## 3. Validate project access

```bash
qapi GET "/api/projects/$QX_PROJECT_CODE" >/dev/null || exit 1
```

---

## 4. Read the non-secret deploy config (or interview + write it)

Read the `deploy` block from the binding:

```bash
DEPLOY_CFG="$(node -e '
  try{
    const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    if(o.deploy) process.stdout.write(JSON.stringify(o.deploy)); else process.exit(1);
  }catch{process.exit(1)}
' "$BIND")"
```

**If `DEPLOY_CFG` is present**, parse `provider`, `appName`, `environments` (array), `needsDb`,
and `runtimeSecrets` (array of secret NAMES — the runtime allowlist; may be absent on configs
written before this field existed) from it with node.

**If it is ABSENT (node exited non-zero) → INTERVIEW** the user, one question at a time,
capturing **non-secret fields only**:

- **provider** — v1 is Fly-only; default/only value `fly`. Capture into `PROVIDER`.
- **app name** — the base Fly app name. Capture into `APPNAME`.
- **environments** — which exist: `staging`, `production`, or both? Capture as a
  comma-separated string into `ENVS` (e.g. `staging,production`).
- **needsDb** — does it need a DB migration step before deploy? `true`/`false` into `NEEDSDB`.

The runtime-secret allowlist (`runtimeSecrets`) is **not** asked here — it is gathered in
step 6b, which needs the live list of vault secret names. Leave it out of this write; step 6b
fills it in.

Then MERGE the block into the existing binding **without clobbering** `projectCode` /
`kanbanUrl` (and preserving any existing `runtimeSecrets`) and **without writing any secret**:

```bash
node -e '
  const fs=require("fs");
  const [f,provider,appName,envs,needsDb]=process.argv.slice(1);
  const o=JSON.parse(fs.readFileSync(f,"utf8"));
  const prev=o.deploy||{};
  o.deploy={
    provider,appName,
    environments:envs.split(",").map(s=>s.trim()).filter(Boolean),
    needsDb:needsDb==="true",
    // preserve a previously-saved allowlist; step 6b sets it if absent
    runtimeSecrets:Array.isArray(prev.runtimeSecrets)?prev.runtimeSecrets:[]
  };
  fs.writeFileSync(f,JSON.stringify(o,null,2)+"\n");
' "$BIND" "$PROVIDER" "$APPNAME" "$ENVS" "$NEEDSDB"
echo "Wrote non-secret deploy config to $BIND"
```

Continue with the freshly written config (re-read `DEPLOY_CFG` as above so the rest of the
flow has `PROVIDER`/`APPNAME`/`environments`/`needsDb`).

---

## 5. Choose the environment

If `ENV_ARG` was given and is one of the configured `environments`, use it. Otherwise ask the
user to pick from the configured environments. Capture into `ENV`. If `ENV_ARG` was given but
is **not** in the configured list, say so and ask the user to pick a valid one.

Derive the concrete Fly app name. v1 convention: base `appName`, suffixed per non-default
environment (e.g. `${APPNAME}-staging`); `production` uses the bare `appName`. Confirm the
resolved name with the user if unsure. Capture into `APP`.

---

## 5b. Offer to import local env creds into the vault (before fetching it)

Before the vault is fetched, scan this repo's local env files and offer to import any
credentials found into the project vault — so a `FLY_API_TOKEN` (or other deploy/runtime
secret) that exists only in `.env.local` can be put into the vault and picked up by the
fetch in step 6, instead of failing later with "set it at /keys". Running this **before**
step 6 means freshly imported keys appear in the in-memory map.

**SECRET SAFETY (same invariant as the rest of this command):** the scan and import NEVER
print a secret value or the bearer; the only value-derived output is a masked last-4 tail.
Each value flows **file → `node` → `qapi` → vault** — never echoed, never on argv as a
value, never to disk/logs. No `set -x`, no `curl -v`. `unset` after use.

Use the shared helpers (identical pattern to `/quetrex-init` step 5b). `qx_env_scan`
parses `$REPO_ROOT/.env`, `.env.local`, `.env.*` (skipping `*.example`/`*.sample`) in
`node`, filters to relevant credential names, **normalizes `FLY_TOKEN` → `FLY_API_TOKEN`**
(the exact name step 8 looks up), and emits `FILE<TAB>RAWNAME<TAB>CANON<TAB>****<last4>`:

```bash
SCAN="$(qx_env_scan "$REPO_ROOT")"
```

If `SCAN` is non-empty, show the discovered entries by **CANON name + masked last-4 only**
and ask: *"Import these N keys into the project's vault before deploying?"* On **yes**,
import each with `qx_secret_put_from_env` (value read inside `node`, PUT to
`/api/projects/$QX_PROJECT_CODE/secrets`); on **no**, skip:

```bash
if [ -n "$SCAN" ]; then
  while IFS=$'\t' read -r ENVFILE RAWNAME CANON MASK; do
    [ -n "$CANON" ] || continue
    # (Ask once up front; only loop here if the user said yes.)
    if qx_secret_put_from_env "$ENVFILE" "$RAWNAME" "$CANON"; then
      echo "Imported $CANON ($MASK)"
    else
      echo "Failed to import $CANON — set it at $QX_KANBAN_URL/keys" >&2
    fi
  done <<< "$SCAN"
fi
```

Only fall back to the "set it at /keys" error (step 8) if a needed key is in **neither**
the vault nor local env. Never re-prompt for a credential just imported.

---

## 6. Fetch vault secrets IN-MEMORY

```bash
SECRETS_JSON="$(qapi POST "/api/projects/$QX_PROJECT_CODE/secrets/export")" || exit 1
```

`SECRETS_JSON` is a `{NAME:value}` map held only in this process as a **plain, NON-exported**
shell variable. Do **NOT** `export` it — an exported var is visible to every child process via
`ps e` / `/proc/<pid>/environ`. It is fed to `node` only over STDIN (never argv, never the
environment). **NEVER** `echo`/`cat`/redirect it, never write it to disk, never print any key
or value, never pass it through a command that would log it.

---

## 6b. Resolve the runtime-secret allowlist

Only secrets the user explicitly marks as **runtime app secrets** are ever pushed to the
deployed app. Everything else in the vault (the Fly token, GitHub/CI tokens, the Quetrex
bearer, build-only keys) is used by the deploy process and must NEVER reach the app's runtime
environment.

**If `runtimeSecrets` is present and non-empty in the deploy config**, use it as-is — skip the
interview.

**If `runtimeSecrets` is absent or empty**, build it now. List the vault's secret **NAMES**
from the **masked** endpoint (names only — values are masked server-side and we never print
them anyway):

```bash
MASKED="$(qapi GET "/api/projects/$QX_PROJECT_CODE/secrets")" || exit 1
printf '%s' "$MASKED" | node -e '
  let d="";
  process.stdin.on("data", c => { d += c; });
  process.stdin.on("end", () => {
    let a; try { a = JSON.parse(d); } catch { process.exit(1); }
    const list = Array.isArray(a) ? a
      : (Array.isArray(a.secrets) ? a.secrets
      : Object.keys(a).map(k => ({ name: k })));   // map shape -> names only
    const names = [...new Set(
      list.map(x => typeof x === "string" ? x : (x && (x.name || x.key || x.id)))
          .filter(Boolean)
    )];
    names.forEach(n => console.log(n));            // NAMES ONLY, never masked values
  });
'
unset MASKED
```

Show that name list to the user and ask **which names are RUNTIME app secrets** (the ones the
running app needs in its environment). Make clear everything they leave out stays deploy-only
and is never pushed to the app. Collect the chosen names into a `CHOSEN` bash array.

Persist just the chosen **names** (non-secret) to the binding, preserving the rest of the
deploy block:

```bash
node -e '
  const fs=require("fs");
  const [f,...names]=process.argv.slice(1);
  const o=JSON.parse(fs.readFileSync(f,"utf8"));
  o.deploy=o.deploy||{};
  o.deploy.runtimeSecrets=names;
  fs.writeFileSync(f,JSON.stringify(o,null,2)+"\n");
' "$BIND" "${CHOSEN[@]}"
echo "Saved runtime-secret allowlist (names only) to $BIND"
```

Now load the allowlist into the `RUNTIME_NAMES` bash array (names only — passed as argv to the
push step in step 8; never any value):

```bash
RUNTIME_NAMES=()
while IFS= read -r n; do
  [ -n "$n" ] && RUNTIME_NAMES+=("$n")
done < <(node -e '
  const fs=require("fs");
  const o=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
  ((o.deploy && Array.isArray(o.deploy.runtimeSecrets)) ? o.deploy.runtimeSecrets : [])
    .forEach(n => console.log(n));
' "$BIND")

if [ "${#RUNTIME_NAMES[@]}" -eq 0 ]; then
  echo "Note: no runtime secrets are allowlisted — nothing will be pushed to the app runtime." >&2
fi
```

---

## 7. Branch on provider

```bash
case "$PROVIDER" in
  fly) : ;;  # handled in step 8
  *) echo "Provider '$PROVIDER' not supported yet (v1 is Fly-only)." >&2; exit 1 ;;
esac
```

---

## 8. Fly deploy — token-safely

Per project rules, Fly access uses an explicit per-app `FLY_API_TOKEN` passed inline, never
the ambient `fly auth` login. Pull the token from the in-memory map into a plain (non-exported)
shell variable **without `eval` and without printing it**. Feed the map to node over STDIN
(`printf` is a shell builtin, so the map never appears as a separate process in `ps`); node
parses it and writes the *raw* token to stdout, which command substitution captures. Because
the value is never re-interpreted by the shell, a token containing shell metacharacters can
never be executed:

```bash
_FLY_TOK="$(printf '%s' "$SECRETS_JSON" | node -e '
  let d="";
  process.stdin.on("data", c => { d += c; });
  process.stdin.on("end", () => {
    let s; try { s = JSON.parse(d); } catch { process.exit(1); }
    process.stdout.write(String(s.FLY_API_TOKEN || ""));
  });
')"

if [ -z "$_FLY_TOK" ]; then
  echo "No FLY_API_TOKEN in the project vault or this repo's local env files (step 5b checked .env*). Set FLY_API_TOKEN at $QX_KANBAN_URL/keys, then re-run /deploy." >&2
  unset SECRETS_JSON _FLY_TOK
  exit 1
fi
```

**Confirm reachability before deploying** (stop here if the token/app is wrong, before any
mutation):

```bash
FLY_API_TOKEN="$_FLY_TOK" fly status --app "$APP" >/dev/null 2>&1 || {
  echo "Cannot reach Fly app '$APP' — check the FLY_API_TOKEN and app name." >&2
  unset SECRETS_JSON _FLY_TOK
  exit 1
}
```

**Push runtime app secrets** into the Fly app via STDIN so values never hit argv or logs. Only
the **allowlisted** names (`RUNTIME_NAMES`, from step 6b) are pushed — pipeline-only creds
(`FLY_API_TOKEN`, CI/GitHub tokens, the Quetrex bearer, build-only keys) are never exposed in
the app runtime. The in-memory map is fed to node over STDIN (not the environment); the
allowlist NAMES are passed as argv (names are non-secret); node emits only the allowlisted
`NAME=value` lines straight into the `fly` pipe:

```bash
if [ "${#RUNTIME_NAMES[@]}" -gt 0 ]; then
  printf '%s' "$SECRETS_JSON" | node -e '
    let d="";
    process.stdin.on("data", c => { d += c; });
    process.stdin.on("end", () => {
      let s; try { s = JSON.parse(d); } catch { process.exit(1); }
      const allow = new Set(process.argv.slice(1));   // allowlisted NAMES (non-secret)
      for (const [k, v] of Object.entries(s)) {
        if (!allow.has(k)) continue;                  // allowlist only — never the whole map
        if (k === "FLY_API_TOKEN") continue;          // belt-and-suspenders: never the deploy token
        process.stdout.write(`${k}=${v}\n`);
      }
    });
  ' "${RUNTIME_NAMES[@]}" | FLY_API_TOKEN="$_FLY_TOK" fly secrets import --app "$APP" --stage
else
  echo "No runtime secrets allowlisted; skipping 'fly secrets import'." >&2
fi
```

(`--stage` so they apply on the next deploy; values are never printed. Only the allowlisted
names reach the app — the rest of the vault never leaves the deploy process.)

**If `needsDb` is true**, note the pre-deploy migration step. v1 leaves the actual migration
command as a TODO hook — mention in the report that a DB migration may be required and was not
run automatically.

**Deploy:**

```bash
FLY_API_TOKEN="$_FLY_TOK" fly deploy --app "$APP"
```

**Scrub the sensitive vars** as soon as the deploy returns (success or failure):

```bash
unset SECRETS_JSON _FLY_TOK
```

---

## 9. Report success

On a successful deploy, capture the URL (`fly status --app "$APP"` or the known
`https://$APP.fly.dev`) and report:
- the environment, resolved app name, and deployed URL,
- that the allowlisted runtime secrets were staged from the vault (count only — never
  names/values), and that non-allowlisted vault entries were NOT pushed to the app runtime,
- that the in-memory secret map was scrubbed (`unset`) and nothing was written to disk.

---

## 10. Optionally advance merged → deployed

**Ask the user first** whether to advance this project's `merged` tasks to `deployed`. Only if
they say yes:

```bash
TASKS="$(qapi GET "/api/tasks?project=$QX_PROJECT_CODE")" || exit 1
node -e '
  let a; try{a=JSON.parse(process.argv[1])}catch{process.exit(1)}
  const list=Array.isArray(a)?a:(a.tasks||[]);
  list.filter(t=>(t.status||t.state)==="merged").forEach(t=>console.log(t.identifier||t.id));
' "$TASKS"
```

For each merged task, PATCH it to deployed:

```bash
PAYLOAD="$(node -e 'process.stdout.write(JSON.stringify({status:"deployed"}))')"
qapi PATCH "/api/tasks/$ID" "$PAYLOAD" >/dev/null || true
```

Report which tasks advanced.

---

## Secret/token safety invariants (restated)

- The vault map lives only in `$SECRETS_JSON`, a **plain, NON-exported** shell variable
  (process memory); never `export`ed, never to disk/logs/context. It is fed to `node` only over
  STDIN — never via the environment (`ps e` / `/proc/<pid>/environ`) and never via argv.
- `FLY_API_TOKEN` is extracted **without `eval`** (raw value captured from a STDIN-fed node via
  command substitution) and passed inline per-command, never echoed, never on a logged line.
- Only the **allowlisted** `runtimeSecrets` names reach the app runtime; values are piped to
  `fly secrets import` via STDIN, with the allowlist NAMES (non-secret) passed as argv. The
  rest of the vault never leaves the deploy process.
- `unset SECRETS_JSON _FLY_TOK` at the end (and on every early-exit after they are set);
  `MASKED` is unset right after the name list is built.
- No `set -x`, no `curl -v`, no `fly` verbose flags that echo secrets.
- The only thing written to disk is the **non-secret** `deploy` config (including the
  `runtimeSecrets` allowlist — names only) in `.quetrex/project.json`.
- The step 5b env-cred import never prints a secret value or the bearer; masked last-4 is
  the only value-derived output; values flow file→`node`→`qapi`→vault and are never on
  argv as a value, never to disk/logs; the body var is `unset` after each import.

---

## Error-handling rules

- Absent deploy config → interview + write non-secret config, then continue.
- Absent/empty `runtimeSecrets` → list masked vault NAMES, ask which are runtime, save the
  chosen names; if the user picks none, push nothing to the app runtime (warn, don't fail).
- Unsupported provider → stop (v1 is Fly-only).
- Missing `FLY_API_TOKEN` → step 5b first offers to import it from a local `.env*`
  (normalizing `FLY_TOKEN` → `FLY_API_TOKEN`); only if it's in neither the vault nor local
  env do you stop with the "set FLY_API_TOKEN at <kanban>/keys" message.
- `fly status` unreachable → stop before deploy; scrub vars.
- Env arg not in config → ask the user to pick a valid environment.
- Any `qapi` or resolver non-zero exit → the helper already printed the correct message.
- Never print or echo the bearer token or any vault secret. Never run `set -x` around `qapi`
  or `fly`.
