---
description: Deploy this project's app using its vault secrets (Fly.io for v1). Interviews for deploy config on first run, fetches secrets in-memory, runs the deploy token-safely (rolling). Also supports rollback to the previous release. Usage: /quetrex:deploy [staging|production|rollback]
argument-hint: "[staging | production | rollback]"
---

# Deploy

Deploy this project's app using its **vault secrets** from the Quetrex kanban. v1 supports
**Fly.io** only, but the flow branches on `provider` so other platforms can be added later.

Forward deploys use a **rolling** strategy — Fly replaces machines one at a time, gated on
health checks, so a bad release never takes the whole app down at once.

**Rollback:** `/quetrex:deploy rollback [staging|production]` re-deploys the **previous** successful
release's image instead of building a new one. It lists recent releases, shows which prior
image it will roll back to, and **confirms with you before acting**. See
[§8b. Rollback](#8b-rollback--redeploy-the-previous-image-token-safely).

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

Argument: `$ARGUMENTS` is optional. The first token is either an environment (`staging` /
`production`) for a normal forward deploy, or the literal `rollback` to roll back to the
previous release. When the first token is `rollback`, an optional **second** token is the
environment (`/quetrex:deploy rollback production`).

---

## 1. Parse the arguments (mode + environment)

```bash
# First token = mode-or-env; optional second token = env when rolling back.
ARG1="$(printf '%s' "$ARGUMENTS" | awk '{print $1}' | tr -d '[:space:]')"
ARG2="$(printf '%s' "$ARGUMENTS" | awk '{print $2}' | tr -d '[:space:]')"

if [ "$ARG1" = "rollback" ]; then
  MODE="rollback"
  ENV_ARG="$ARG2"          # optional; may be empty → ask in step 5
else
  MODE="deploy"
  ENV_ARG="$ARG1"          # optional; may be empty → ask in step 5
fi
```

`ENV_ARG` is validated later against the project's configured environments and may be empty.
`MODE` is `deploy` (forward, build-and-ship) or `rollback` (re-deploy the previous image).

---

## 2. Resolve context via the `quetrex-api` tool

```bash
QX_KANBAN_URL="$(quetrex-api kanban-url)"     || exit 1
QX_PROJECT_CODE="$(quetrex-api project-code)" || exit 1
BIND="$(quetrex-api binding-path)" || { echo "Run /quetrex-setup:init" >&2; exit 1; }
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || dirname "$(dirname "$BIND")")"
echo "Project: $QX_PROJECT_CODE @ $QX_KANBAN_URL"
```

---

## 3. Validate project access

```bash
quetrex-api GET "/api/projects/$QX_PROJECT_CODE" >/dev/null || exit 1
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
Each value flows **file → `node` → `quetrex-api` → vault** — never echoed, never on argv as a
value, never to disk/logs. No `set -x`, no `curl -v`. `unset` after use.

Use the shared helpers (identical pattern to `/quetrex-setup:init` step 5b). `quetrex-api env-scan`
parses `$REPO_ROOT/.env`, `.env.local`, `.env.*` (skipping `*.example`/`*.sample`) in
`node`, filters to relevant credential names, **normalizes `FLY_TOKEN` → `FLY_API_TOKEN`**
(the exact name step 8 looks up), and emits `FILE<TAB>RAWNAME<TAB>CANON<TAB>****<last4>`:

```bash
SCAN="$(quetrex-api env-scan "$REPO_ROOT")"
```

If `SCAN` is non-empty, show the discovered entries by **CANON name + masked last-4 only**
and ask: *"Import these N keys into the project's vault before deploying?"* On **yes**,
import each with `quetrex-api secret-put` (value read inside `node`, PUT to
`/api/projects/$QX_PROJECT_CODE/secrets`); on **no**, skip:

```bash
if [ -n "$SCAN" ]; then
  while IFS=$'\t' read -r ENVFILE RAWNAME CANON MASK; do
    [ -n "$CANON" ] || continue
    # (Ask once up front; only loop here if the user said yes.)
    if quetrex-api secret-put "$ENVFILE" "$RAWNAME" "$CANON"; then
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
SECRETS_JSON="$(quetrex-api POST "/api/projects/$QX_PROJECT_CODE/secrets/export")" || exit 1
```

`SECRETS_JSON` is a `{NAME:value}` map held only in this process as a **plain, NON-exported**
shell variable. Do **NOT** `export` it — an exported var is visible to every child process via
`ps e` / `/proc/<pid>/environ`. It is fed to `node` only over STDIN (never argv, never the
environment). **NEVER** `echo`/`cat`/redirect it, never write it to disk, never print any key
or value, never pass it through a command that would log it.

---

## 6b. Resolve the runtime-secret allowlist

**Skip this entire step when `MODE=rollback`** — a rollback re-deploys an existing image and
does not push secrets, so no allowlist is needed. Set `RUNTIME_NAMES=()` (empty) and jump
straight to step 7. The rest of 6b runs only for a forward deploy (`MODE=deploy`).

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
MASKED="$(quetrex-api GET "/api/projects/$QX_PROJECT_CODE/secrets")" || exit 1
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
  echo "No FLY_API_TOKEN in the project vault or this repo's local env files (step 5b checked .env*). Set FLY_API_TOKEN at $QX_KANBAN_URL/keys, then re-run /quetrex:deploy." >&2
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

**If `MODE=rollback`, skip the rest of this step and jump to [§8b. Rollback](#8b-rollback--redeploy-the-previous-image-token-safely)**
— a rollback re-deploys an existing image, so there is no secret push and no forward `fly
deploy`. (The token extraction and `fly status` reachability check above still apply.) The
secret-push and forward-deploy blocks below run only for a forward deploy (`MODE=deploy`).

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

**Deploy (rolling):** deploy with an explicit **rolling** strategy so Fly replaces machines
one at a time, each gated on health checks, regardless of machine count — a bad release can
never take the whole app down at once. This is the forward-deploy path (`MODE=deploy`):

```bash
FLY_API_TOKEN="$_FLY_TOK" fly deploy --app "$APP" --strategy rolling
```

**Scrub the sensitive vars** as soon as the deploy returns (success or failure):

```bash
unset SECRETS_JSON _FLY_TOK
```

---

## 8b. Rollback — redeploy the previous image (token-safely)

**Runs only when `MODE=rollback`.** A rollback re-deploys the previous successful release's
image instead of building a new one — no build, no secret push. It reuses the same token-safe
`_FLY_TOK` extracted in step 8 (never echoed) and the same `fly status` reachability check.

**1. List recent releases (token-safe).** Show the user the last few releases so they can see
what they're rolling back from and to. `--json` gives a stable shape to parse the prior image:

```bash
RELEASES_JSON="$(FLY_API_TOKEN="$_FLY_TOK" fly releases --app "$APP" --json 2>/dev/null)"
```

Also show a human-readable table (version + date + status) — this prints release metadata
only, never a secret:

```bash
FLY_API_TOKEN="$_FLY_TOK" fly releases --app "$APP" | head -n 12
```

**2. Determine the previous image.** The current (live) release is the newest successful one;
the rollback target is the **next** successful release below it. Parse the image ref from the
releases JSON with node over STDIN (metadata only — no secret is involved):

```bash
PREV_IMAGE="$(printf '%s' "$RELEASES_JSON" | node -e '
  let d="";
  process.stdin.on("data", c => { d += c; });
  process.stdin.on("end", () => {
    let a; try { a = JSON.parse(d); } catch { process.exit(1); }
    const list = Array.isArray(a) ? a : (Array.isArray(a.releases) ? a.releases : []);
    // Newest first. Keep only successful/complete releases that carry a deployment image.
    const ok = list.filter(r => {
      const st = String(r.status || r.Status || "").toLowerCase();
      return (st === "" || st === "succeeded" || st === "complete" || st === "running");
    });
    const img = r => r.imageRef || r.ImageRef || r.image || r.Image || "";
    // The live release is ok[0]; the rollback target is the next one with a *different* image.
    const cur = ok.length ? img(ok[0]) : "";
    const prev = ok.slice(1).map(img).find(x => x && x !== cur) || "";
    process.stdout.write(String(prev));
  });
')"
```

**3. Confirm before acting.** Tell the user the current image (from `ok[0]`) and the resolved
`PREV_IMAGE` it will roll back **to**, and **wait for explicit confirmation**. This is a
mutating action gated on a yes/no — never roll back without it.

**If `PREV_IMAGE` is empty** (couldn't determine a prior image), do **not** guess. Explain that
the previous image couldn't be resolved automatically, re-show `fly releases --app "$APP"`, and
ask the user to paste the exact image ref (e.g. `registry.fly.io/<app>:deployment-<id>`) to
roll back to. Capture their answer into `PREV_IMAGE`.

**4. Roll back (rolling).** Re-deploy the prior image with the same health-check-gated rolling
strategy. `--image` re-deploys an existing image without a rebuild:

```bash
FLY_API_TOKEN="$_FLY_TOK" fly deploy --app "$APP" --image "$PREV_IMAGE" --strategy rolling
```

Report the result: the environment, resolved app name, and the image rolled back to. Then scrub
the sensitive vars (same as the forward path — success or failure):

```bash
unset SECRETS_JSON _FLY_TOK RELEASES_JSON
```

---

## 9. Report success

*(Forward deploy only — the rollback path already reported in §8b. For a rollback, skip to the
end; do **not** advance task status in step 10.)*

On a successful deploy, capture the URL (`fly status --app "$APP"` or the known
`https://$APP.fly.dev`) and report:
- the environment, resolved app name, and deployed URL,
- that the allowlisted runtime secrets were staged from the vault (count only — never
  names/values), and that non-allowlisted vault entries were NOT pushed to the app runtime,
- that the in-memory secret map was scrubbed (`unset`) and nothing was written to disk.

---

## 10. Optionally advance merged → deployed

*(Forward deploy only — a rollback does not advance task status.)*

**Ask the user first** whether to advance this project's `merged` tasks to `deployed`. Only if
they say yes:

```bash
TASKS="$(quetrex-api GET "/api/tasks?project=$QX_PROJECT_CODE")" || exit 1
node -e '
  let a; try{a=JSON.parse(process.argv[1])}catch{process.exit(1)}
  const list=Array.isArray(a)?a:(a.tasks||[]);
  list.filter(t=>(t.status||t.state)==="merged").forEach(t=>console.log(t.identifier||t.id));
' "$TASKS"
```

For each merged task, PATCH it to deployed:

```bash
PAYLOAD="$(node -e 'process.stdout.write(JSON.stringify({status:"deployed"}))')"
quetrex-api PATCH "/api/tasks/$ID" "$PAYLOAD" >/dev/null || true
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
  the only value-derived output; values flow file→`node`→`quetrex-api`→vault and are never on
  argv as a value, never to disk/logs; the body var is `unset` after each import.
- **Rollback** uses the same `_FLY_TOK` (inline per-command, never echoed); `fly releases`
  prints release metadata only (never a secret); the prior image ref is non-secret and parsed
  from `--json` via STDIN-fed node; `RELEASES_JSON` is `unset` with the rest at the end.
- Both forward deploy and rollback use `--strategy rolling` (health-check-gated, one machine
  at a time). Rollback pushes **no** secrets and skips the runtime-secret allowlist (step 6b).

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
- **Rollback** (`/quetrex:deploy rollback [env]`) → skip the runtime-secret allowlist and secret push;
  list releases, resolve the previous image, **confirm with the user before acting**, then
  `fly deploy --image <prev> --strategy rolling`. If the previous image can't be resolved,
  show `fly releases` and ask the user to paste the image ref — never guess. Do not advance
  task status on a rollback.
- Any `quetrex-api` or resolver non-zero exit → the helper already printed the correct message.
- Never print or echo the bearer token or any vault secret. Never run `set -x` around `quetrex-api`
  or `fly`.
