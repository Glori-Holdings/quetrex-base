---
description: Diagnose this repo's Quetrex health — board reachable, engine enabled and auto-updating (never pinned), no leftover legacy artifacts, no dead MCP broker, verify chain configured and in sync with CLAUDE.md, requiredEnv outstanding, deploy target set, vault wired and covering .env.local, pipeline permissions granted, arming committed, cloud environment recorded — in the checkmark / here's-the-fix style of the native /doctor, and it never asks a question. Usage: /quetrex-setup:doctor
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

What THIS command owns are the fourteen Quetrex-app checks native `/doctor` knows
nothing about. Run them all, then print one line per check:

- `✓ <check> — <what's good>`
- `✗ <check> — <what's wrong>` followed by an indented **Fix:** line with the
  exact command or action.

**Doctor never asks a question.** Every check ends in a verdict and, on ✗, the exact
command to run — a check that would need an operator decision (which cloud
environment, which chain command a variable gates) prints the candidates with one
Fix line each and stops. It lives in `quetrex-setup` (user scope) precisely so it
exists on an unarmed repo, before the project plugins are enabled. Doctor is
report-only: it never writes `.quetrex/project.json`, `.quetrex/verify.json`,
`.claude/CLAUDE.md` or the vault — the Fix lines name the writers.

Run the checks in a single bash block where practical; each is independent, so a
failure in one never aborts the rest. Never print the bearer token; let the
`quetrex-api` tool (on the plugin's PATH) own all auth messaging. The helpers
(`quetrex-api`, `quetrex-env-derive`, `quetrex-cloud-env`) ship on this plugin's
`bin/`, which IS on PATH in slash-command bash — call each by name, never source
it, never path it (exactly as `/quetrex-setup:init` does).

---

## Setup

```bash
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
SETTINGS="$REPO_ROOT/.claude/settings.json"
HOME_SETTINGS="$HOME/.claude/settings.json"
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
  echo "    Fix: run /quetrex-setup:login"
elif [ -f "$BIND" ] && CODE="$(quetrex-api json-get "$BIND" projectCode 2>/dev/null)" && [ -n "$CODE" ]; then
  if quetrex-api GET "/api/projects/$CODE" >/dev/null 2>&1; then
    echo "✓ Board reachable — authenticated, project $CODE answers."
  else
    echo "✗ Board reachable — logged in, but project $CODE did not answer (access or network)."
    echo "    Fix: confirm you're a member of $CODE, or re-run /quetrex-setup:login if the token expired."
  fi
else
  echo "✗ Board reachable — this repo is not linked to a Quetrex project."
  echo "    Fix: run /quetrex-setup:init"
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
  const fs=require("fs");
  function load(p){ try{return JSON.parse(fs.readFileSync(p,"utf8"))}catch{return null} }
  const repo=load(process.argv[1]);
  const home=load(process.argv[2]);
  // Claude Code settings precedence: repo settings.json overrides the global
  // ~/.claude/settings.json at the top-level key. quetrex-base itself has NO
  // extraKnownMarketplaces key at all (a valid, common setup — the operator
  // set autoUpdate globally), so ABSENCE of the key at the repo level must
  // fall back to global, never be read as a failure.
  let level;
  if (repo && Object.prototype.hasOwnProperty.call(repo, "extraKnownMarketplaces")) {
    level = repo.extraKnownMarketplaces;
  } else if (home && Object.prototype.hasOwnProperty.call(home, "extraKnownMarketplaces")) {
    level = home.extraKnownMarketplaces;
  } else {
    level = {};
  }
  process.stdout.write(String(((level||{}).quetrex||{}).autoUpdate===true));
' "$SETTINGS" "$HOME_SETTINGS" 2>/dev/null)"

if [ -n "$PINS" ]; then
  echo "✗ Engine — this repo PINS a version ($PINS). While a pin is present the quetrex command layer does not load here, so no /quetrex:* command exists."
  echo "    Fix: run /quetrex-setup:init — arming rewrites any pin to true."
elif [ "$ENABLED" != "true" ]; then
  echo "✗ Engine — quetrex and/or quetrex-factory are not enabled in this repo's committed settings."
  echo "    Fix: run /quetrex-setup:init"
elif [ "$AUTOUP" != "true" ]; then
  echo "✗ Engine — extraKnownMarketplaces.quetrex.autoUpdate is not true at the repo level ($SETTINGS) or the global level ($HOME_SETTINGS), so this repo will never see a published fix."
  echo "    Fix: run /quetrex-setup:init"
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
PRESENCE only — never remove anything here. A file is NEVER flagged if it is
the target of a LIVE `statusLine.command` in either the repo's or the global
`settings.json` — a diagnostic must never recommend deleting working
configuration, and the status bar is where the running Quetrex version is
shown by design (config carries no version):

```bash
STATUSLINE_CMDS=""
for sf in "$SETTINGS" "$HOME_SETTINGS"; do
  [ -f "$sf" ] || continue
  cmd="$(node -e '
    let o={}; try{o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))}catch{}
    process.stdout.write(String((o.statusLine&&o.statusLine.command)||""));
  ' "$sf" 2>/dev/null)"
  [ -n "$cmd" ] && STATUSLINE_CMDS="$STATUSLINE_CMDS
$cmd"
done

is_live_statusline() {  # is_live_statusline <abs-path> -> 0 if EXACTLY targeted by
  # a live statusLine.command (never a substring match — a command that
  # merely CONTAINS a candidate's path, e.g. a `.bak` superstring, must not
  # suppress the candidate).
  local target="$1" cmd tok resolved
  [ -z "$STATUSLINE_CMDS" ] && return 1
  while IFS= read -r cmd; do
    [ -z "$cmd" ] && continue
    for tok in $cmd; do
      case "$tok" in
        "~") resolved="$HOME" ;;
        "~/"*) resolved="$HOME/${tok#\~/}" ;;
        *) resolved="$tok" ;;
      esac
      [ "$resolved" = "$target" ] && return 0
    done
  done <<STATUSLINE_EOF
$STATUSLINE_CMDS
STATUSLINE_EOF
  return 1
}

LEGACY=()
for f in "$HOME/.claude/statusline-command.sh" \
         "$HOME/.claude/quetrex-doctrine.md" \
         "$HOME/.claude/hooks/check-quetrex-update.sh" \
         "$HOME/.claude/hooks/enforce-merge-approval.sh" \
         "$HOME/.claude/hooks/security-check.sh" \
         "$HOME/.claude/team-protocol.md" \
         "$HOME/.claude/.quetrex-manifest.json"; do
  if [ -e "$f" ] && ! is_live_statusline "$f"; then
    LEGACY+=("${f/#$HOME/~}")
  fi
done
# Portable existence test — `compgen` is a bash-only builtin (command not
# found under zsh, which silently swallows the check) and a bare glob would
# abort the script under zsh's default NOMATCH option when nothing matches.
# `find` takes the pattern as a literal argument in both shells, so this is
# the one test that behaves identically under bash and zsh.
if find "$HOME/.claude/commands" -maxdepth 1 -name 'quetrex-*.md' 2>/dev/null | grep -q .; then
  LEGACY+=("~/.claude/commands/quetrex-*.md (npm-era commands)")
fi
if [ "${#LEGACY[@]}" -eq 0 ]; then
  echo "✓ No leftover legacy artifacts — global ~/.claude is clean of npm-era Quetrex files."
else
  echo "✗ Leftover legacy artifacts — ${#LEGACY[@]} npm-era item(s) in ~/.claude: ${LEGACY[*]}"
  echo "    Fix: run /quetrex-setup:init — it offers the guarded, reversible one-time legacy cleanup (quarantine, never hard-delete)."
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
registration; never remove it here (`/quetrex-setup:init` owns the repair):

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
  echo "    Fix: run /quetrex-setup:init — arming now removes that registration and commits the repair for the whole team."
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
  echo "    Fix: run /quetrex-setup:init — it detects and writes your verify chain."
fi

# requiredEnv coverage — report-only, NEVER blocks (doctor's exit code stays
# 0 for this check regardless). verify-gate.sh's declarative env skip
# (should_skip_for_env) only fires for a command that has a COMMITTED
# requiredEnv entry; a repo whose .quetrex/verify.json predates that field
# has none, so a genuinely-absent variable its own .env.example declares
# blocks the agent instead of skipping — the exact defect this feature
# closes. Only meaningful when the repo actually declares required config: a
# repo with no committed .env.example/.env.sample has nothing to derive, so
# it is never nagged. `quetrex-env-derive missing` is read-only — it never
# writes anything, it only reports what `verify-json` WOULD add.
if { [ -f "$REPO_ROOT/.env.example" ] || [ -f "$REPO_ROOT/.env.sample" ]; } \
   && command -v quetrex-env-derive >/dev/null 2>&1; then
  MISSING_REQUIRED_ENV="$(quetrex-env-derive missing "$REPO_ROOT" 2>/dev/null)"
  if [ -n "$MISSING_REQUIRED_ENV" ]; then
    # `scan` carries the read site per name (NAME<TAB>file:line — SOURCE files
    # only, prose is excluded); join it in so the operator sees exactly where
    # each outstanding name is read without a fallback.
    SCAN_REQUIRED_ENV="$(quetrex-env-derive scan "$REPO_ROOT" 2>/dev/null)"
    echo "✗ requiredEnv outstanding — committed candidates (declared in .env.example, read with no fallback in source) covered by neither requiredEnv nor requiredEnvDeclined in .quetrex/verify.json, so verify-gate.sh's declarative env skip cannot fire for them:"
    while IFS= read -r qx_name; do
      [ -n "$qx_name" ] || continue
      qx_at="$(printf '%s\n' "$SCAN_REQUIRED_ENV" | awk -F'\t' -v n="$qx_name" '$1==n{print $2; exit}')"
      echo "      $qx_name (read at ${qx_at:-unknown})"
    done <<QX_MISSING_EOF
$MISSING_REQUIRED_ENV
QX_MISSING_EOF
    echo "    Fix: re-run /quetrex-setup:init — its step 5c asks you, per name, which chain command (if any) may skip when that name is unset, and writes only what you confirm. Doctor never writes .quetrex/verify.json."
  else
    echo "✓ requiredEnv outstanding — none; every committed candidate is declared or declined in .quetrex/verify.json."
  fi
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
  echo "    Fix: run /quetrex-setup:init to link this repo, then set keys at dash.quetrex.com/keys."
fi
```

---

## Check 8 — Pipeline permissions granted

A plugin **cannot** ship a `permissions.allow` block — Claude Code honours only
two keys from a plugin's `settings.json` — so the pipeline's terminal grants
have to live in the customer's own committed `.claude/settings.json`, written
there by `/quetrex-setup:init` step 4e. When they are missing, nothing fails early:
the architect plans, the developers build, QA and the reviewer pass, and then
the very last step tries to `git push` / `gh pr create`, hits a permission
prompt, and **hangs with the work already done**. In an unattended cloud build
there is nobody at the keyboard — measured on QDM-4, where the operator was
paged on his phone to approve a `gh pr create` that is supposed to be automatic,
because `quetrex-demo`'s `.claude/settings.json` had no `permissions` key at all.

Check the two grants that actually strand the terminal stage, by name.
`Bash(git push:*)` and `Bash(gh pr:*)` are the pair; a repo missing either one
hangs in exactly the same place, so report which are absent rather than whether
the `permissions` key merely exists:

```bash
MISSING_PERMS="$(node -e '
  const fs=require("fs");
  const need=["Bash(git push:*)","Bash(gh pr:*)"];
  let o={}; try{o=JSON.parse(fs.readFileSync(process.argv[1],"utf8"))}catch{}
  const allow=(o.permissions&&Array.isArray(o.permissions.allow))?o.permissions.allow:[];
  process.stdout.write(need.filter(function(n){return allow.indexOf(n)===-1}).join(", "));
' "$SETTINGS" 2>/dev/null)"
if [ -z "$MISSING_PERMS" ]; then
  echo "✓ Pipeline permissions granted — this repo's .claude/settings.json allows the terminal git push and gh pr calls."
else
  echo "✗ Pipeline permissions granted — .claude/settings.json is missing $MISSING_PERMS, so the pipeline runs the whole build and then HANGS at the final push/PR step waiting for a human to approve it."
  echo "    Fix: run /quetrex-setup:init — its step 4e unions the FULL pipeline grant set (12 entries) into your own committed .claude/settings.json, not only the ones named above: the git worktree/checkout/merge/diff/rev-parse/add/commit calls, Bash(jq:*), Bash(mkdir:*), and Edit(/**) — the file-write grant, anchored at your project root. It only ever adds, never removes or narrows an existing entry, and never touches permissions.deny/ask. See init.md step 4e for the exact list; every entry lands in your own settings, so it is visible and revocable by you."
fi
```

This is a **repo** check, not a machine one: the grants must be committed, or
they reach neither a teammate's checkout nor a cloud routine's fresh clone.

---

## Check 9 — Arming is COMMITTED, not just present on disk

Checks 1–7 all read the **working tree**. A teammate's clone — and every cloud
routine, which starts from a *fresh clone* and can only ever see committed
files — sees just what git **tracks**. So a repo whose arming artifacts exist
on disk but were never `git add`ed (or sit under a `.gitignore` rule such as
`.quetrex/` or `.claude/`) is armed for **you** and unarmed for **everyone and
everything else**, while every check above still prints ✓. That is the most
consequential half-armed state there is: doctor says green, the operator
dispatches a build, and the routine clones a repo with no project binding, no
engine enablement and no verify chain.

So ask the same questions again — of `HEAD` instead of of the working tree.
Never infer this from `[ -f ... ]`; use `git ls-files` / `git cat-file -e
HEAD:<path>`, which is the only thing a clone reproduces.

```bash
GONE=""
note_gone() {  # note_gone <text> — append to the "a fresh clone would not see" list
  if [ -n "$GONE" ]; then GONE="$GONE; "; fi
  GONE="$GONE$1"
}
tracked_state() {  # tracked_state <repo-relative-path> -> absent|ignored|untracked|staged|committed
  if ! git -C "$REPO_ROOT" ls-files --error-unmatch -- "$1" >/dev/null 2>&1; then
    if [ ! -e "$REPO_ROOT/$1" ]; then echo absent; return; fi
    if git -C "$REPO_ROOT" check-ignore -q -- "$1" 2>/dev/null; then echo ignored; return; fi
    echo untracked; return
  fi
  # Tracked is not enough: a clone materialises HEAD, so a file that is only
  # in the index (git add, never committed) is still absent from every clone.
  if git -C "$REPO_ROOT" cat-file -e "HEAD:$1" 2>/dev/null; then echo committed; else echo staged; fi
}
say_state() {  # say_state <repo-relative-path> <state>
  case "$2" in
    absent)    note_gone "$1 (missing here too)" ;;
    ignored)   note_gone "$1 (on disk but UNTRACKED — a .gitignore rule excludes it)" ;;
    untracked) note_gone "$1 (on disk but UNTRACKED — never git add'ed)" ;;
    staged)    note_gone "$1 (staged in the index but never committed)" ;;
  esac
}

if ! git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "✗ Arming committed — $REPO_ROOT is not a git repository, so there is nothing for a teammate or a cloud routine to clone."
  echo "    Fix: git init and commit this repo, then run /quetrex-setup:init."
else
  say_state ".quetrex/project.json" "$(tracked_state .quetrex/project.json)"

  SET_STATE="$(tracked_state .claude/settings.json)"
  say_state ".claude/settings.json" "$SET_STATE"
  # Tracked AND committed is still not enough for settings.json: the arming
  # edit itself (enabledPlugins) can sit uncommitted in a long-tracked file,
  # so read the COMMITTED blob, never the one on disk.
  if [ "$SET_STATE" = "committed" ]; then
    HEAD_ENABLED="$(git -C "$REPO_ROOT" show HEAD:.claude/settings.json 2>/dev/null | node -e '
      let s=""; process.stdin.on("data",function(d){s+=d}).on("end",function(){
        let o={}; try{o=JSON.parse(s)}catch{}
        const e=o.enabledPlugins||{};
        process.stdout.write(String(e["quetrex@quetrex"]===true && e["quetrex-factory@quetrex"]===true));
      });' 2>/dev/null)"
    if [ "$HEAD_ENABLED" != "true" ]; then
      note_gone ".claude/settings.json (committed, but the COMMITTED copy does not enable quetrex + quetrex-factory)"
    fi
  fi

  # Verify chain — mirror Check 5's either/or against HEAD. Only asked when
  # the working tree actually has one of the two; if it has neither, Check 5
  # already owns that failure and this must not double-report it.
  if [ -f "$REPO_ROOT/.quetrex/verify.json" ] || [ -f "$REPO_ROOT/.claude/CLAUDE.md" ]; then
    CHAIN_AT_HEAD=false
    if git -C "$REPO_ROOT" show HEAD:.quetrex/verify.json 2>/dev/null | node -e '
      let s=""; process.stdin.on("data",function(d){s+=d}).on("end",function(){
        let o; try{o=JSON.parse(s)}catch{process.exit(1)}
        const steps=o.steps||o.commands||o.chain||o.verify;
        process.exit(Array.isArray(steps)&&steps.length?0:1);
      });' 2>/dev/null; then
      CHAIN_AT_HEAD=true
    elif git -C "$REPO_ROOT" show HEAD:.claude/CLAUDE.md 2>/dev/null | node -e '
      let s=""; process.stdin.on("data",function(d){s+=d}).on("end",function(){
        process.exit(/^##\s+Verification\s*$/m.test(s)?0:1);
      });' 2>/dev/null; then
      CHAIN_AT_HEAD=true
    fi
    if [ "$CHAIN_AT_HEAD" != "true" ]; then
      note_gone "the verify chain (neither a committed .quetrex/verify.json with a non-empty chain nor a committed .claude/CLAUDE.md with a ## Verification section)"
    fi
  fi

  if [ -z "$GONE" ]; then
    echo "✓ Arming committed — every arming artifact this repo has is committed, so a fresh clone (a teammate's, or a cloud routine's) is armed exactly like this checkout."
  else
    echo "✗ Arming committed — a fresh clone would NOT be armed: $GONE. This repo is armed for you alone; every teammate and every cloud routine (which starts from a fresh clone and sees only committed files) gets an UNARMED repo with no gates at all."
    echo "    Fix: commit the arming artifacts — git add -f .quetrex/project.json .claude/settings.json (plus your verify chain) and commit them. If .gitignore excludes .claude/ or .quetrex/, add negations (e.g. '!.quetrex/project.json') so they stay tracked for the whole team."
  fi
fi
```

Never "fix" this by loosening the check to the working tree, and never report
it as a board/auth problem — the repo is fine locally *by construction*; the
whole point is that locally-fine and clone-armed are different questions.

---

## Check 10 — user-scope plugin hygiene

`quetrex-setup` (login/init/update/doctor, four commands + a one-line unarmed
offer) is meant to be enabled ONCE, at **user** scope, machine-wide — it is
what lets an unarmed repo be armed at all, and what lets this very command
run on a repo before its project plugins exist. `quetrex` and `quetrex-factory`
(the pipeline itself) are meant to be enabled per repo, at **project** scope,
by `/quetrex-setup:init` — never at user scope, where they would leak the
full 11-command pipeline and its gate hooks into every repo on the machine,
armed or not, which is exactly the surface this split exists to shrink.

```bash
HYGIENE="$(node -e '
  const fs = require("fs");
  let o = {};
  try { o = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch {}
  const e = o.enabledPlugins || {};
  const truthy = (v) => v === true || Array.isArray(v) || typeof v === "string";
  const OTHER_RE = /^quetrex(-[a-z0-9]+)?@quetrex$/;
  const others = Object.keys(e).filter((k) => OTHER_RE.test(k) && k !== "quetrex-setup@quetrex" && truthy(e[k]));
  const setupOn = e["quetrex-setup@quetrex"] === true;
  if (others.length) console.log("BAD_OTHER:" + others.join(","));
  if (!setupOn) console.log("BAD_SETUP");
' "$HOME_SETTINGS")"

if [ -n "$HYGIENE" ]; then
  if printf '%s' "$HYGIENE" | grep -q '^BAD_OTHER:'; then
    NAMES="$(printf '%s' "$HYGIENE" | sed -n 's/^BAD_OTHER://p')"
    echo "✗ User-scope plugin hygiene — $NAMES enabled at USER scope (~/.claude/settings.json). This leaks the full pipeline command layer and its gate hooks into every repo on the machine, armed or not."
    echo "    Fix: remove $NAMES from ~/.claude/settings.json's enabledPlugins; let /quetrex-setup:init enable it per repo, at project scope."
  fi
  if printf '%s' "$HYGIENE" | grep -q '^BAD_SETUP$'; then
    echo "✗ User-scope plugin hygiene — quetrex-setup is not enabled at USER scope, so an unarmed repo has no path to /quetrex-setup:login, :init or :update."
    echo "    Fix: enable quetrex-setup@quetrex: true in ~/.claude/settings.json's enabledPlugins (once per machine)."
  fi
else
  echo "✓ User-scope plugin hygiene — quetrex-setup is enabled at user scope; no pipeline plugin leaks in at user scope."
fi
```

---

## Check 11 — Cloud environment

`/quetrex:task-build` fires the build as a cloud routine, and a routine needs the
`cloudEnvironmentId` recorded in `.quetrex/project.json`. When it is missing the
first build stalls. `/quetrex-setup:init` step 3e derives it from the operator's own
routines; doctor runs the SAME derivation (`quetrex-cloud-env`, the one copy) and
prints the writer command instead of asking.

**Before this block, when the binding has no `cloudEnvironmentId`, call `RemoteTrigger`
with `action: "list"`** — a tool call, not a shell command (the OAuth token is added
in-process) — and write the raw JSON to a temp file whose path you export as
`TRIGGERS_JSON`. If that call fails or the id is already set, leave `TRIGGERS_JSON`
unset; the block never blocks on it.

```bash
CLOUD_ENV_ID=""
if [ -f "$BIND" ]; then
  CLOUD_ENV_ID="$(quetrex-api json-get "$BIND" cloudEnvironmentId 2>/dev/null || true)"
fi
if [ ! -f "$BIND" ]; then
  echo "✗ Cloud environment — no project binding, so nothing records which environment this repo's builds run in."
  echo "    Fix: run /quetrex-setup:init"
elif [ -n "$CLOUD_ENV_ID" ]; then
  echo "✓ Cloud environment — builds run in $CLOUD_ENV_ID (.quetrex/project.json cloudEnvironmentId)."
else
  # TSV from quetrex-cloud-env: <env_id>\t<repo|other>\t<last-used>\t<name>,
  # repo-first. Only the `repo` rows — environments that have actually run
  # against THIS repo — are candidates; an `other` environment may lack this
  # repo's toolchain and is only ever mentioned, never prescribed.
  CLOUD_CANDIDATES=""
  if [ -n "${TRIGGERS_JSON:-}" ] && [ -f "${TRIGGERS_JSON:-}" ]; then
    CLOUD_CANDIDATES="$(quetrex-cloud-env candidates "$REPO_ROOT" < "$TRIGGERS_JSON" 2>/dev/null || true)"
  fi
  REPO_ENVS="$(printf '%s\n' "$CLOUD_CANDIDATES" | awk -F'\t' '$2=="repo"{print $1}')"
  OTHER_ENVS="$(printf '%s\n' "$CLOUD_CANDIDATES" | awk -F'\t' '$2=="other"{print $1}' | tr '\n' ' ')"
  REPO_N="$(printf '%s\n' "$REPO_ENVS" | grep -c . || true)"
  if [ "$REPO_N" -eq 1 ]; then
    echo "✗ Cloud environment — not recorded, but exactly one environment has run against this repo: $REPO_ENVS"
    echo "    Fix: quetrex-cloud-env set . $REPO_ENVS"
  elif [ "$REPO_N" -gt 1 ]; then
    echo "✗ Cloud environment — not recorded, and $REPO_N environments have run against this repo (they may carry different toolchains) — pick one:"
    while IFS= read -r qx_env; do
      [ -n "$qx_env" ] || continue
      echo "    Fix: quetrex-cloud-env set . $qx_env"
    done <<QX_ENVS_EOF
$REPO_ENVS
QX_ENVS_EOF
  else
    echo "✗ Cloud environment — not recorded, and no environment on this account has run against this repo${OTHER_ENVS:+ (environments seen on other repos: $OTHER_ENVS)}."
    echo "    Fix: open https://claude.ai/code, create the environment this repo should build in, then run: quetrex-cloud-env set . <env_…>  (re-running /quetrex-setup:init derives it once a routine has used it)"
  fi
fi
```

---

## Check 12 — Verification block matches verify.json

`.quetrex/verify.json` `.verify[]` is what `verify-gate.sh` and QA run; the fenced
block under `## Verification` in `.claude/CLAUDE.md` is the human-readable copy and
the fallback. When the two drift, a human reads one chain and the gate runs another.
Compare them line-for-line in `node` (never shell word-splitting), trimmed, blank
lines dropped; on drift print the exact block to paste:

```bash
VERIF_DRIFT="$(node -e '
  const fs=require("fs");
  const [vfile, rules]=process.argv.slice(1);
  const FENCE=String.fromCharCode(96,96,96);
  let chain=null;
  try { const o=JSON.parse(fs.readFileSync(vfile,"utf8")); if (o && Array.isArray(o.verify) && o.verify.length) chain=o.verify.map(String); } catch {}
  if (!chain) { process.stdout.write("NOCHAIN"); process.exit(0); }
  const want=chain.map(s=>s.trim()).filter(Boolean);
  let md=null; try { md=fs.readFileSync(rules,"utf8"); } catch {}
  let block=null;
  if (md!==null) {
    const lines=md.split(/\r?\n/);
    const i=lines.findIndex(l=>/^##\s+Verification\s*$/.test(l));
    if (i>=0) for (let j=i+1;j<lines.length;j++){
      if (/^##\s/.test(lines[j])) break;
      if (lines[j].trim().startsWith(FENCE)) {
        block=[];
        for (let k=j+1;k<lines.length;k++){ if (lines[k].trim().startsWith(FENCE)) break; block.push(lines[k]); }
        break;
      }
    }
  }
  const got=block ? block.map(s=>s.trim()).filter(Boolean) : null;
  const same = got!==null && got.length===want.length && got.every((s,n)=>s===want[n]);
  if (same) { process.stdout.write("MATCH " + want.length); process.exit(0); }
  const why = md===null ? "no .claude/CLAUDE.md" : (block===null ? "no fenced block under ## Verification" : "the block differs from .verify[]");
  process.stdout.write("DRIFT " + why + "\n" + FENCE + "bash\n" + want.join("\n") + "\n" + FENCE);
' "$REPO_ROOT/.quetrex/verify.json" "$REPO_ROOT/.claude/CLAUDE.md" 2>/dev/null || echo "ERROR")"
case "$VERIF_DRIFT" in
  NOCHAIN)
    echo "✓ Verification block — no .quetrex/verify.json chain to compare against (Check 5 owns that)." ;;
  "MATCH "*)
    echo "✓ Verification block — .claude/CLAUDE.md ## Verification matches .quetrex/verify.json (${VERIF_DRIFT#MATCH } command(s))." ;;
  "DRIFT "*)
    echo "✗ Verification block — .claude/CLAUDE.md ## Verification does not match .quetrex/verify.json ($(printf '%s\n' "$VERIF_DRIFT" | head -1 | sed 's/^DRIFT //'))."
    echo "    Fix: make the fenced block under ## Verification in .claude/CLAUDE.md exactly this (verify.json is authoritative):"
    printf '%s\n' "$VERIF_DRIFT" | tail -n +2 | sed 's/^/    /' ;;
  *)
    echo "✗ Verification block — could not compare (node unavailable or unreadable files)."
    echo "    Fix: run /quetrex-setup:init" ;;
esac
```

---

## Check 13 — Vault coverage

Secrets live in the project vault; a name that exists only in a developer's
`.env.local` is a credential every cloud build and every teammate lacks. Compare the
NAMES in `.env.local` against the names the vault reports — never a value. `.env.local`
is parsed with `grep`/`sed` only (never sourced — sourcing executes it) and no value
is ever printed. A placeholder value (empty, or an obvious template such as
`your-secret-here` / `<paste>` / `changeme`) is nothing to import, exactly as
`/quetrex-setup:init`'s env-scan skips an empty value; those are listed separately:

```bash
ENV_LOCAL="$REPO_ROOT/.env.local"
if [ ! -f "$ENV_LOCAL" ]; then
  echo "✓ Vault coverage — no .env.local in this repo, nothing to compare."
elif ! { [ -f "$BIND" ] && CODE="$(quetrex-api json-get "$BIND" projectCode 2>/dev/null)" && [ -n "$CODE" ]; }; then
  echo "✗ Vault coverage — .env.local is present but this repo has no project binding, so there is no vault to compare against."
  echo "    Fix: run /quetrex-setup:init"
elif ! VAULT_RAW="$(quetrex-api GET "/api/projects/$CODE/secrets" 2>/dev/null)"; then
  echo "✗ Vault coverage — project $CODE's vault did not answer, so .env.local could not be compared."
  echo "    Fix: re-run /quetrex-setup:login if the token expired; otherwise confirm you are a member of $CODE."
else
  # NAMES ONLY from the masked endpoint (it returns name + last4, never a value).
  VAULT_NAMES="$(printf '%s' "$VAULT_RAW" | node -e '
    let d=""; process.stdin.on("data",c=>{d+=c;}).on("end",()=>{
      let a; try { a=JSON.parse(d); } catch { process.exit(1); }
      const list = Array.isArray(a) ? a : (Array.isArray(a.secrets) ? a.secrets : Object.keys(a).map(k=>({name:k})));
      const names=[...new Set(list.map(x=>typeof x==="string"?x:(x&&(x.name||x.key||x.id))).filter(Boolean))];
      names.forEach(n=>console.log(n));
    });' 2>/dev/null)"
  unset VAULT_RAW
  # NAMES ONLY from .env.local — grep/sed, never sourced, never a value printed.
  ENV_NAMES="$(grep -E '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=' "$ENV_LOCAL" 2>/dev/null | sed -E 's/^[[:space:]]*(export[[:space:]]+)?//; s/=.*$//' | awk '!seen[$0]++')"
  MISSING_IN_VAULT=""; PLACEHOLDER_NAMES=""; N_ENV=0
  while IFS= read -r qx_name; do
    [ -n "$qx_name" ] || continue
    # Placeholder = empty value or an obvious template string. Classified in a
    # pipeline so the value never lands in a variable, let alone on stdout.
    if grep -E "^[[:space:]]*(export[[:space:]]+)?$qx_name=" "$ENV_LOCAL" | tail -1 \
         | sed -E 's/^[^=]*=//; s/^[[:space:]]*//; s/[[:space:]]*$//; s/^"(.*)"$/\1/' | sed -E "s/^'(.*)'\$/\1/" \
         | grep -Eiq '^$|^(your[-_].*|<.*>|changeme|change[-_]me|x{3,}|todo|replace[-_]me|\.\.\.|\*{3,})$'; then
      PLACEHOLDER_NAMES="$PLACEHOLDER_NAMES $qx_name"
      continue
    fi
    N_ENV=$((N_ENV + 1))
    if ! printf '%s\n' "$VAULT_NAMES" | grep -qx -- "$qx_name"; then
      MISSING_IN_VAULT="$MISSING_IN_VAULT $qx_name"
    fi
  done <<QX_ENV_NAMES_EOF
$ENV_NAMES
QX_ENV_NAMES_EOF
  if [ -z "$MISSING_IN_VAULT" ]; then
    echo "✓ Vault coverage — $N_ENV name(s) in .env.local, all in project $CODE's vault.${PLACEHOLDER_NAMES:+ Skipped (placeholder):$PLACEHOLDER_NAMES}"
  else
    echo "✗ Vault coverage — name(s) in .env.local missing from project $CODE's vault:$MISSING_IN_VAULT"
    # One Fix line per name, read line by line — never `for x in $VAR`, which
    # word-splits under bash and NOT under zsh (the operator's shell).
    while IFS= read -r qx_name; do
      [ -n "$qx_name" ] || continue
      echo "    Fix: quetrex-api secret-put .env.local $qx_name $qx_name"
    done <<QX_MISSING_VAULT_EOF
$(printf '%s\n' "$MISSING_IN_VAULT" | tr ' ' '\n')
QX_MISSING_VAULT_EOF
    if [ -n "$PLACEHOLDER_NAMES" ]; then
      echo "      skipped (placeholder):$PLACEHOLDER_NAMES"
    fi
  fi
fi
```

---

## Check 14 — Webhook registered

A cloud build has no board credential, so the card's move to `pr_ready` rides on a
GitHub webhook the board verifies against THIS project's vault entry
`GITHUB_WEBHOOK_SECRET` (generated and stored by `/quetrex-setup:init` 4i — never typed
by the operator, never needed by an agent). Four things must all hold: the origin is a
GitHub repo; that repo carries a hook pointed at the board; the vault lists the name
(names-only collection GET — never the export endpoint); and the project records BOTH
halves of the origin slug — `githubOwner` and `githubRepo` — equal to it. The board
shows the repository as linked only when both are set (`RepoLink` checks the pair), and
the webhook drops a delivery from any other repo. Report which is missing or mismatched;
the one writer for all four is init:

```bash
QX_ORIGIN="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null)"
QX_SLUG="$(printf '%s' "$QX_ORIGIN" | sed -E 's#^(git@github\.com:|(https?|ssh|git)://(git@)?github\.com/)##; s#/+$##; s#\.git$##; s#/+$##')"
if ! printf '%s' "$QX_SLUG" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
  echo "✗ Webhook registered — origin is not a GitHub repo, so no hook can move cards to pr_ready."
  echo "    Fix: add a GitHub origin remote, then re-run /quetrex-setup:init"
elif ! command -v gh >/dev/null 2>&1; then
  echo "✗ Webhook registered — gh CLI not installed, so the hook on $QX_SLUG could not be checked."
  echo "    Fix: install gh (brew install gh && gh auth login), then re-run /quetrex-setup:init"
elif ! { [ -f "$BIND" ] && CODE="$(quetrex-api json-get "$BIND" projectCode 2>/dev/null)" && [ -n "$CODE" ]; }; then
  echo "✗ Webhook registered — this repo has no project binding, so there is no vault or project to check."
  echo "    Fix: run /quetrex-setup:init"
elif ! KANBAN="$(quetrex-api kanban-url 2>/dev/null)" || [ -z "$KANBAN" ]; then
  echo "✗ Webhook registered — not logged in, so the board's hook URL is unknown."
  echo "    Fix: run /quetrex-setup:login, then re-run /quetrex-setup:init"
else
  HOOK_URL="${KANBAN%/}/api/webhooks/github"
  WH_MISSING=""
  # (b) a hook on the repo whose config.url is the board's endpoint
  HOOK_ID="$(gh api "repos/$QX_SLUG/hooks" --jq '.[] | select(.config.url=="'"$HOOK_URL"'") | .id' 2>/dev/null | head -1)"
  [ -n "$HOOK_ID" ] || WH_MISSING="$WH_MISSING GitHub hook on $QX_SLUG -> $HOOK_URL;"
  # (c) the vault lists the NAME — masked collection GET, never a value
  if ! quetrex-api GET "/api/projects/$CODE/secrets" 2>/dev/null | node -e '
    let d=""; process.stdin.on("data",c=>{d+=c;}).on("end",()=>{
      let a; try { a=JSON.parse(d); } catch { process.exit(1); }
      const list = Array.isArray(a) ? a : (Array.isArray(a.secrets) ? a.secrets : Object.keys(a).map(k=>({name:k})));
      process.exit(list.some(x=>(typeof x==="string"?x:(x&&(x.name||x.key||x.id)))==="GITHUB_WEBHOOK_SECRET") ? 0 : 1);
    });' 2>/dev/null; then
    WH_MISSING="$WH_MISSING GITHUB_WEBHOOK_SECRET in project $CODE's vault;"
  fi
  # (d) the project records BOTH halves of the origin slug — the board shows the
  # repository as linked only when githubOwner AND githubRepo are set, and the
  # webhook refuses a delivery from any other repo. Each half is named on its own.
  LINKED_JSON="$(quetrex-api GET "/api/projects/$CODE" 2>/dev/null)"
  linked_field() { printf '%s' "$LINKED_JSON" | node -e '
    let d=""; process.stdin.on("data",c=>{d+=c;}).on("end",()=>{
      let p; try { p=JSON.parse(d); } catch { process.exit(0); }
      process.stdout.write(String((p && p[process.argv[1]]) || ""));
    });' "$1" 2>/dev/null; }
  LINKED_OWNER="$(linked_field githubOwner)"; LINKED_REPO="$(linked_field githubRepo)"
  SLUG_OWNER="${QX_SLUG%%/*}"; SLUG_REPO="${QX_SLUG##*/}"
  if [ -z "$LINKED_OWNER" ]; then
    WH_MISSING="$WH_MISSING project $CODE githubOwner (unset; origin is $SLUG_OWNER);"
  elif [ "$LINKED_OWNER" != "$SLUG_OWNER" ]; then
    WH_MISSING="$WH_MISSING project $CODE githubOwner (is $LINKED_OWNER, origin is $SLUG_OWNER);"
  fi
  if [ -z "$LINKED_REPO" ]; then
    WH_MISSING="$WH_MISSING project $CODE githubRepo (unset; origin is $SLUG_REPO);"
  elif [ "$LINKED_REPO" != "$SLUG_REPO" ]; then
    WH_MISSING="$WH_MISSING project $CODE githubRepo (is $LINKED_REPO, origin is $SLUG_REPO);"
  fi
  if [ -z "$WH_MISSING" ]; then
    echo "✓ Webhook registered — $QX_SLUG hook $HOOK_ID -> $HOOK_URL, GITHUB_WEBHOOK_SECRET in project $CODE's vault, project linked to $LINKED_OWNER/$LINKED_REPO — board shows the repository as linked."
  else
    echo "✗ Webhook registered — missing:$WH_MISSING cards will not auto-move to pr_ready."
    echo "    Fix: re-run /quetrex-setup:init"
  fi
fi
```

---

## Final summary

After the fourteen checks, print a one-line roll-up: *"Quetrex health: N/14 green."*
If any check surfaced a **platform or plugin-install** symptom (a plugin not
enabled, the CLI itself unhealthy, marketplace unreachable), add one line
directing the user to native **`/doctor`** for that layer — this command
deliberately does not diagnose it.
