---
description: Diagnose this repo's Quetrex health — board reachable, engine enabled and auto-updating (never pinned), no leftover legacy artifacts, no dead MCP broker, verify chain configured, deploy target set, vault wired — in the checkmark / here's-the-fix style of the native /doctor. Usage: /quetrex:doctor
argument-hint: ""
---

# Quetrex Doctor

A focused health check for **the Quetrex layer of this repo**, in the same
checkmark-and-fix style as Claude Code's native `/doctor`.

**This command COMPLEMENTS native `/doctor`; it does not duplicate it.** Defer
to native **`/doctor`** for the platform and plugin-install layer — Claude Code
version, plugin marketplace connectivity, whether the `quetrex` / `quetrex-factory`
plugins are installed and enabled, MCP server process health, auth to the CLI
itself. If a check below reveals a platform/plugin-install problem (a plugin not
enabled, the CLI unhealthy), say so and **point the user at `/doctor`** rather
than re-implementing those checks here.

What THIS command owns are the seven Quetrex-app checks native `/doctor` knows
nothing about. Run them all, then print one line per check:

- `✓ <check> — <what's good>`
- `✗ <check> — <what's wrong>` followed by an indented **Fix:** line with the
  exact command or action.

Run the checks in a single bash block where practical; each is independent, so a
failure in one never aborts the rest. Never print the bearer token; let the
`quetrex-api` tool (on the plugin's PATH) own all auth messaging.

---

## Setup

```bash
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
SETTINGS="$REPO_ROOT/.claude/settings.json"
BIND="$REPO_ROOT/.quetrex/project.json"
MARKET_URL="https://raw.githubusercontent.com/Glori-Holdings/quetrex-plugins/main/.claude-plugin/marketplace.json"
```

---

## Check 1 — Board reachable

The kanban is the origination surface; if the CLI can't reach it, nothing else
matters. Use the `quetrex-api` tool (it injects the bearer via a `0600` temp
config and never echoes it) to confirm auth resolves AND the linked project
answers:

```bash
if ! quetrex-api kanban-url >/dev/null 2>&1; then
  echo "✗ Board reachable — not logged in on this machine."
  echo "    Fix: run /quetrex:login"
elif [ -f "$BIND" ] && CODE="$(quetrex-api json-get "$BIND" projectCode 2>/dev/null)" && [ -n "$CODE" ]; then
  if quetrex-api GET "/api/projects/$CODE" >/dev/null 2>&1; then
    echo "✓ Board reachable — authenticated, project $CODE answers."
  else
    echo "✗ Board reachable — logged in, but project $CODE did not answer (access or network)."
    echo "    Fix: confirm you're a member of $CODE, or re-run /quetrex:login if the token expired."
  fi
else
  echo "✗ Board reachable — this repo is not linked to a Quetrex project."
  echo "    Fix: run /quetrex:init"
fi
```

---

## Check 2 — Engine present, auto-updating, and NOT pinned

Quetrex pins nothing. A pinned `enabledPlugins` entry makes the plugin count as
**disabled** for dependency resolution, and the whole `/quetrex:*` command layer
then fails to load — measured across four checkouts: pin absent → enabled;
`true` → enabled; `["1.2.1"]` (the exact installed version) → **failed to load**;
`["1.1.0"]` → **failed to load**. So a pin is now a DEFECT, and the version lives
in the status bar instead of in config:

```bash
RUNNING="$(quetrex-version --plain 2>/dev/null || echo "")"
PINS="$(node -e '
  let o={}; try{o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))}catch{}
  const e=o.enabledPlugins||{};
  const bad=Object.keys(e).filter(function(k){return /^quetrex(-factory)?@quetrex$/.test(k) && e[k]!==true && e[k]!==false});
  process.stdout.write(bad.map(function(k){return k+"="+JSON.stringify(e[k])}).join(", "));
' "$SETTINGS" 2>/dev/null)"
ENABLED="$(node -e '
  let o={}; try{o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))}catch{}
  const e=o.enabledPlugins||{};
  process.stdout.write(String(e["quetrex@quetrex"]===true && e["quetrex-factory@quetrex"]===true));
' "$SETTINGS" 2>/dev/null)"
AUTOUP="$(node -e '
  let o={}; try{o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))}catch{}
  process.stdout.write(String(((o.extraKnownMarketplaces||{}).quetrex||{}).autoUpdate===true));
' "$SETTINGS" 2>/dev/null)"

if [ -n "$PINS" ]; then
  echo "✗ Engine — this repo PINS a version ($PINS). While a pin is present the quetrex command layer does not load here, so no /quetrex:* command exists."
  echo "    Fix: run /quetrex:init — arming rewrites any pin to true."
elif [ "$ENABLED" != "true" ]; then
  echo "✗ Engine — quetrex and/or quetrex-factory are not enabled in this repo's committed settings."
  echo "    Fix: run /quetrex:init"
elif [ "$AUTOUP" != "true" ]; then
  echo "✗ Engine — extraKnownMarketplaces.quetrex.autoUpdate is not true, so this repo will never see a published fix."
  echo "    Fix: run /quetrex:init"
elif [ -n "$RUNNING" ]; then
  echo "✓ Engine — enabled, unpinned, auto-updating (running Quetrex v$RUNNING)."
else
  echo "✓ Engine — enabled, unpinned, auto-updating."
fi

# The LOAD is the thing that matters, so assert it rather than infer it from config.
if command -v claude >/dev/null 2>&1; then
  if claude plugin list 2>/dev/null | grep -A3 "quetrex@quetrex" | grep -q "failed to load"; then
    echo "✗ Engine loads — claude plugin list reports quetrex@quetrex as FAILED TO LOAD in this repo, so no /quetrex:* command is available."
    echo "    Fix: clear any version pin (above), then restart Claude Code."
  fi
fi
```

Report the running version from `quetrex-version` / the status bar, never from
config — config carries no version by design.

---

## Check 3 — No leftover legacy artifacts

The npm era seeded files into the operator's global `~/.claude`; the plugin era
does not. Stray legacy artifacts (old `quetrex-*.md` commands, the retired
`quetrex-doctrine.md`, superseded hooks like `check-quetrex-update.sh` /
`enforce-merge-approval.sh` / `security-check.sh`, the `~/.quetrex-manifest.json`
record) are harmless but confusing and can double-fire guards. Detect their
PRESENCE only — never remove anything here:

```bash
LEGACY=()
for f in "$HOME/.claude/quetrex-doctrine.md" \
         "$HOME/.claude/hooks/check-quetrex-update.sh" \
         "$HOME/.claude/hooks/enforce-merge-approval.sh" \
         "$HOME/.claude/hooks/security-check.sh" \
         "$HOME/.claude/statusline-command.sh" \
         "$HOME/.claude/team-protocol.md" \
         "$HOME/.claude/.quetrex-manifest.json"; do
  [ -e "$f" ] && LEGACY+=("${f/#$HOME/~}")
done
if compgen -G "$HOME/.claude/commands/quetrex-*.md" >/dev/null 2>&1; then
  LEGACY+=("~/.claude/commands/quetrex-*.md (npm-era commands)")
fi
if [ "${#LEGACY[@]}" -eq 0 ]; then
  echo "✓ No leftover legacy artifacts — global ~/.claude is clean of npm-era Quetrex files."
else
  echo "✗ Leftover legacy artifacts — ${#LEGACY[@]} npm-era item(s) in ~/.claude: ${LEGACY[*]}"
  echo "    Fix: run /quetrex:init — it offers the guarded, reversible one-time legacy cleanup (quarantine, never hard-delete)."
fi
```

---

## Check 4 — No dead MCP broker

Earlier engines committed an `.mcp.json` registering a `quetrex-kanban` http
broker at `<kanbanUrl>/api/mcp`. **That endpoint was never built** — the kanban
has no such route and the URL answers with the dash's Next.js 404 HTML page — so
Claude Code opened the repo with an MCP server that could never handshake. The
operator sees it as *"the plugins cannot connect to the dash"*, and it is
committed, so it hits every teammate and every cloud routine. Detect the stale
registration; never remove it here (`/quetrex:init` owns the repair):

```bash
DEAD_MCP="$(node -e '
  const fs=require("fs");
  let o; try{o=JSON.parse(fs.readFileSync(process.argv[1],"utf8"))}catch{process.stdout.write("");process.exit(0)}
  const e=o && o.mcpServers && o.mcpServers["quetrex-kanban"];
  const url=e?String(e.url||""):"";
  process.stdout.write(/\/api\/mcp\/?$/.test(url)?url:"");
' "$REPO_ROOT/.mcp.json" 2>/dev/null)"
if [ -z "$DEAD_MCP" ]; then
  echo "✓ No dead MCP broker — .mcp.json registers no server at the never-built /api/mcp endpoint."
else
  echo "✗ Dead MCP broker — .mcp.json points quetrex-kanban at $DEAD_MCP, an endpoint that does not exist; MCP fails to connect on every session in this repo."
  echo "    Fix: run /quetrex:init — arming now removes that registration and commits the repair for the whole team."
fi
```

Do **not** report this as a dash outage or an auth problem. If the board check
above went green, the dash is fine; this is a config pointing at a route that was
never built.

---

## Check 5 — Verify chain configured

QA and `verify-gate.sh` run the chain from `.quetrex/verify.json` (machine-
readable, authoritative), with the project `.claude/CLAUDE.md` `## Verification`
section as the human fallback. A repo with neither has no gate to go green
against:

```bash
if [ -f "$REPO_ROOT/.quetrex/verify.json" ] && node -e '
  const fs=require("fs");
  let o; try{o=JSON.parse(fs.readFileSync(process.argv[1],"utf8"))}catch{process.exit(1)}
  const steps=o.steps||o.commands||o.chain||o.verify;
  process.exit(Array.isArray(steps)&&steps.length?0:1);
' "$REPO_ROOT/.quetrex/verify.json" 2>/dev/null; then
  echo "✓ Verify chain configured — .quetrex/verify.json has a non-empty chain."
elif [ -f "$REPO_ROOT/.claude/CLAUDE.md" ] && node -e '
  const fs=require("fs");
  process.exit(/^##\s+Verification\s*$/m.test(fs.readFileSync(process.argv[1],"utf8"))?0:1);
' "$REPO_ROOT/.claude/CLAUDE.md" 2>/dev/null; then
  echo "✓ Verify chain configured — no .quetrex/verify.json, but the project CLAUDE.md has a ## Verification section."
else
  echo "✗ Verify chain configured — no .quetrex/verify.json and no ## Verification section."
  echo "    Fix: run /quetrex:init — it detects and writes your verify chain."
fi
```

---

## Check 6 — Deploy target set

`/quetrex:deploy` needs a per-project deploy config (its Fly app, region, etc.,
recorded by the deploy command's first-run interview). Detect whether a deploy
target has been configured for this repo:

```bash
DEPLOY_CFG=""
for f in "$REPO_ROOT/.quetrex/deploy.json" "$REPO_ROOT/fly.toml" "$REPO_ROOT/.quetrex/deploy.toml"; do
  [ -f "$f" ] && DEPLOY_CFG="$f" && break
done
if [ -n "$DEPLOY_CFG" ]; then
  echo "✓ Deploy target set — ${DEPLOY_CFG#$REPO_ROOT/} present."
else
  echo "✗ Deploy target set — no deploy config found for this repo."
  echo "    Fix: run /quetrex:deploy once — its first-run interview records the target (Fly app/region)."
fi
```

---

## Check 7 — Vault wired

Secrets live in the project vault (values are never in AI context); the repo
just needs to be linked so `dash.quetrex.com/keys` and the in-memory secret
pull resolve the right project. Confirm the binding resolves a project code and
that the vault endpoint answers for it:

```bash
if [ -f "$BIND" ] && CODE="$(quetrex-api json-get "$BIND" projectCode 2>/dev/null)" && [ -n "$CODE" ]; then
  if quetrex-api GET "/api/projects/$CODE/secrets" >/dev/null 2>&1; then
    echo "✓ Vault wired — project $CODE resolves and its vault answers."
  else
    echo "✗ Vault wired — project $CODE is linked, but its vault did not answer (access or not provisioned)."
    echo "    Fix: set this project's secrets at $(quetrex-api kanban-url 2>/dev/null || echo https://dash.quetrex.com)/keys"
  fi
else
  echo "✗ Vault wired — no project binding, so no vault to resolve."
  echo "    Fix: run /quetrex:init to link this repo, then set keys at dash.quetrex.com/keys."
fi
```

---

## Final summary

After the seven checks, print a one-line roll-up: *"Quetrex health: N/7 green."*
If any check surfaced a **platform or plugin-install** symptom (a plugin not
enabled, the CLI itself unhealthy, marketplace unreachable), add one line
directing the user to native **`/doctor`** for that layer — this command
deliberately does not diagnose it.
