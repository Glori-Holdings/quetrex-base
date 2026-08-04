---
description: Diagnose this repo's Quetrex health — board reachable, engine pinned to the latest, no leftover legacy artifacts, verify chain configured, deploy target set, vault wired — in the checkmark / here's-the-fix style of the native /doctor. Usage: /quetrex:doctor
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

What THIS command owns are the six Quetrex-app checks native `/doctor` knows
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

## Check 2 — Engine pinned to the latest

The version that teammates and cloud routines actually run is the committed
`enabledPlugins` pin in `.claude/settings.json`. Compare it to the marketplace
latest (there is no version-check API — fetch the manifest from GitHub raw).
Flag a floating (`true`) factory pin as a problem in its own right — routines
must resolve one exact engine:

```bash
PIN="$(node -e '
  const fs=require("fs");
  let o; try{o=JSON.parse(fs.readFileSync(process.argv[1],"utf8"))}catch{process.exit(0)}
  const p=o.enabledPlugins && o.enabledPlugins["quetrex-factory@quetrex"];
  process.stdout.write(p===undefined?"":String(p));
' "$SETTINGS")"

LATEST_FACTORY="$(curl -fsS --max-time 6 "$MARKET_URL" 2>/dev/null | node -e '
  let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    let o; try{o=JSON.parse(s)}catch{process.exit(0)}
    const p=(o.plugins||[]).find(x=>x&&x.name==="quetrex-factory");
    process.stdout.write(p&&p.version?String(p.version):"");
  })' 2>/dev/null)"

if [ -z "$PIN" ]; then
  echo "✗ Engine pinned — no quetrex-factory pin in enabledPlugins."
  echo "    Fix: run /quetrex:init (writes the pin) or /quetrex:update (bumps it)."
elif [ "$PIN" = "true" ]; then
  echo "✗ Engine pinned — quetrex-factory is enabled but not pinned to a concrete version (cloud routines need an exact engine)."
  echo "    Fix: run /quetrex:update to write a concrete version pin."
elif [ -z "$LATEST_FACTORY" ]; then
  echo "✓ Engine pinned — quetrex-factory $PIN (could not reach the marketplace to check for a newer one; see native /doctor for connectivity)."
elif [ "$PIN" = "$LATEST_FACTORY" ]; then
  echo "✓ Engine pinned — quetrex-factory $PIN (latest)."
else
  echo "✗ Engine pinned — quetrex-factory $PIN, but $LATEST_FACTORY is published."
  echo "    Fix: run /quetrex:update"
fi
```

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

## Check 4 — Verify chain configured

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

## Check 5 — Deploy target set

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

## Check 6 — Vault wired

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

After the six checks, print a one-line roll-up: *"Quetrex health: N/6 green."*
If any check surfaced a **platform or plugin-install** symptom (a plugin not
enabled, the CLI itself unhealthy, marketplace unreachable), add one line
directing the user to native **`/doctor`** for that layer — this command
deliberately does not diagnose it.
