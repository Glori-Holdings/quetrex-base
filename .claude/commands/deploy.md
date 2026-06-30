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
  (provider, app name, environments, needsDb) — never any key or token.
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

**If `DEPLOY_CFG` is present**, parse `provider`, `appName`, `environments` (array), and
`needsDb` from it with node.

**If it is ABSENT (node exited non-zero) → INTERVIEW** the user, one question at a time
(like `/deploy-setup`), capturing **non-secret fields only**:

- **provider** — v1 is Fly-only; default/only value `fly`. Capture into `PROVIDER`.
- **app name** — the base Fly app name. Capture into `APPNAME`.
- **environments** — which exist: `staging`, `production`, or both? Capture as a
  comma-separated string into `ENVS` (e.g. `staging,production`).
- **needsDb** — does it need a DB migration step before deploy? `true`/`false` into `NEEDSDB`.

Then MERGE the block into the existing binding **without clobbering** `projectCode` /
`kanbanUrl` and **without writing any secret**:

```bash
node -e '
  const fs=require("fs");
  const [f,provider,appName,envs,needsDb]=process.argv.slice(1);
  const o=JSON.parse(fs.readFileSync(f,"utf8"));
  o.deploy={provider,appName,environments:envs.split(",").map(s=>s.trim()).filter(Boolean),needsDb:needsDb==="true"};
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
  echo "No FLY_API_TOKEN in the project vault. Set FLY_API_TOKEN at $QX_KANBAN_URL/keys, then re-run /deploy." >&2
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

**Push runtime app secrets** into the Fly app via STDIN so values never hit argv or logs. The
in-memory map is fed to node over STDIN (not the environment); node emits `NAME=value` lines
straight into the `fly` pipe:

```bash
printf '%s' "$SECRETS_JSON" | node -e '
  let d="";
  process.stdin.on("data", c => { d += c; });
  process.stdin.on("end", () => {
    let s; try { s = JSON.parse(d); } catch { process.exit(1); }
    for (const [k, v] of Object.entries(s)) {
      if (k === "FLY_API_TOKEN") continue;
      process.stdout.write(`${k}=${v}\n`);
    }
  });
' | FLY_API_TOKEN="$_FLY_TOK" fly secrets import --app "$APP" --stage
```

(`--stage` so they apply on the next deploy; values are never printed.)

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
- that runtime secrets were staged from the vault (count only — never names/values),
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

- The vault map lives only in `$SECRETS_JSON` (process memory); never to disk/logs/context.
- `FLY_API_TOKEN` is passed inline per-command, never echoed, never on a logged line.
- Runtime secrets are piped to `fly secrets import` via STDIN, never on argv.
- `unset SECRETS_JSON _FLY_TOK` at the end (and on every early-exit after they are set).
- No `set -x`, no `curl -v`, no `fly` verbose flags that echo secrets.
- The only thing written to disk is the **non-secret** `deploy` config in
  `.quetrex/project.json`.

---

## Error-handling rules

- Absent deploy config → interview + write non-secret config, then continue.
- Unsupported provider → stop (v1 is Fly-only).
- Missing `FLY_API_TOKEN` in vault → clear "set FLY_API_TOKEN at <kanban>/keys" message; stop.
- `fly status` unreachable → stop before deploy; scrub vars.
- Env arg not in config → ask the user to pick a valid environment.
- Any `qapi` or resolver non-zero exit → the helper already printed the correct message.
- Never print or echo the bearer token or any vault secret. Never run `set -x` around `qapi`
  or `fly`.
