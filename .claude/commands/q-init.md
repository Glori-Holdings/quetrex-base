---
description: Link this repo to a Quetrex project (writes ./.quetrex/project.json) or create one, then non-destructively adopt the repo (clean stale tracker refs, ensure project Verification rules, deploy the committed per-project build gates, offer to import local env creds into the vault, open a PR). Usage: /q-init [project name]
argument-hint: "[project name — only used when the repo is not yet linked]"
---

# Quetrex Init

Bind this repository to a Quetrex project. If the repo is **already linked**
(`./.quetrex/project.json` exists), re-verify access and re-run adoption — never
re-create the binding and never prompt for a name. If it is **not linked**, create
the project (or surface the admin-only guidance on 403) and write the binding.

This command is **non-destructive**: it only ever ADDs `.quetrex/project.json`,
auto-cleans stale tracker references from `CLAUDE.md`, and deploys the committed
per-project build gates (step 4d) — the `verify-gate.sh`/`merge-gate.sh`/`secret-scan.sh`
hooks, the seven fat pipeline agents, and `.quetrex/verify.json`, merged (never clobbered)
into `.claude/settings.json`. It never overwrites or silently deletes existing `.claude/`,
`CLAUDE.md` body content, commands, other settings/hooks, or any git/Claude history. The
**only** removals are stale old-Quetrex project commands/skills, and only the specific
ones the user **confirms** (step 4c) — never auto-deleted. Secrets are never prompted for
here — they live at `dash.quetrex.com/keys`.

**Token safety:** never echo or print the bearer token. The helper's `qapi` injects
it via a `0600` temp config and never exposes it. Build all JSON with
`node` / `JSON.stringify`, never with `echo`. No `set -x`, no `curl -v`.

---

## 1. Resolve auth

Run a single bash block. The helper owns all auth messaging — do not reinvent it.

```bash
source ~/.claude/lib/quetrex-api.sh
resolve_auth || exit 1   # prints "Run /q-login" on miss/expiry
```

If it fails, surface its message verbatim and stop. `QX_KANBAN_URL` is now set from
`auth.json` and is the source of truth for the binding's `kanbanUrl`.

---

## 2. Detect an existing binding

Walk up from `$PWD` for `.quetrex/project.json` (the same walk `resolve_project`
performs). Also locate the repo root (the directory containing `.git`) for later
staging.

```bash
# Find an existing binding by walking up from $PWD.
BIND=""
dir="$PWD"
while [ "$dir" != "/" ]; do
  if [ -f "$dir/.quetrex/project.json" ]; then BIND="$dir/.quetrex/project.json"; break; fi
  dir="$(dirname "$dir")"
done

# Repo root = directory containing .git (fallback to $PWD).
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
```

### 2a. IF PRESENT — already linked (idempotent path)

Do **not** re-create the binding and do **not** prompt for a name or POST
`/api/projects`. Read the code, announce it, and verify access:

```bash
CODE="$(_qx_json_get "$BIND" projectCode)" || { echo "Binding is unreadable — fix or remove $BIND and re-run." >&2; exit 1; }
echo "This repo is linked to project $CODE"
qapi GET "/api/projects/$CODE" >/dev/null || exit 1   # helper prints 401→login, 403/404→no access
```

A non-zero `qapi` exit means the helper already printed the correct message — stop.
On success, proceed to **step 4 (adoption)** so re-runs still clean stale refs and
can open a PR if anything changed.

### 2b. IF ABSENT — not linked (create path)

Proceed to step 3 to create the project and write the binding, then continue to
adoption (step 4).

---

## 3. Create the project and write the binding (only when not linked)

**a. Determine the project name.** Use trimmed `$ARGUMENTS` if non-empty; otherwise
**ask the user** interactively for a project name. Do not assume a name.

```bash
NAME="$(echo "$ARGUMENTS" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
```

If `NAME` is empty, stop the bash block and ask the user: *"What should this Quetrex
project be called?"* Capture their answer into `NAME` before continuing.

**b. Create the project via the API.** Build the payload with `node`:

```bash
PAYLOAD="$(node -e 'process.stdout.write(JSON.stringify({name:process.argv[1]}))' "$NAME")"
if ! RESP="$(qapi POST /api/projects "$PAYLOAD")"; then
  # qapi already printed a message. The most common failure here is 403 — project
  # creation currently requires admin. Give the clearer, action-specific guidance.
  echo "Creating a project requires admin — ask a super_admin to create it, or get added to an existing project, then re-run /q-init." >&2
  exit 1
fi
CODE="$(node -e '
  let o; try{o=JSON.parse(process.argv[1])}catch{process.exit(1)}
  if(!o || !o.code){process.exit(1)}
  process.stdout.write(String(o.code))
' "$RESP")" || { echo "Project created, but the response had no code — contact your administrator." >&2; exit 1; }
echo "Created project $CODE"
```

**c. Write the binding** at the repo root, building the JSON with `node` and using
`QX_KANBAN_URL` (auth's URL, the source of truth):

```bash
mkdir -p "$REPO_ROOT/.quetrex"
node -e '
  const fs=require("fs");
  const [path, projectCode, kanbanUrl] = process.argv.slice(1);
  fs.writeFileSync(path, JSON.stringify({projectCode, kanbanUrl}, null, 2) + "\n");
' "$REPO_ROOT/.quetrex/project.json" "$CODE" "$QX_KANBAN_URL"
echo "Wrote binding: $REPO_ROOT/.quetrex/project.json → $CODE"
```

---

## 4. Non-destructive adoption — auto-clean stale tracker refs

NEVER overwrite or delete existing `.claude/`, `CLAUDE.md` content, commands,
settings, or history. The only file this command CREATES is `.quetrex/project.json`.
Adoption only *edits* `CLAUDE.md` files to remove **stale old-tracker / Linear
references**, preserving everything else.

Operate **only** on files inside this repo. Resolve both targets against
`$REPO_ROOT` explicitly — never a CWD-relative or bare `.claude/CLAUDE.md`, which
could resolve to a subdirectory's file or, worse, the user's **global**
`~/.claude/CLAUDE.md`. The two and only two candidates are:

- `$REPO_ROOT/CLAUDE.md`
- `$REPO_ROOT/.claude/CLAUDE.md`

For each of those two absolute paths that exists, read it and compute a cleaned
version that removes ONLY:

- **`## Linear States` section blocks** — the heading through its table, up to (but
  not including) the next `##` heading or EOF.
- **Removed pipeline-command references** — table rows or list items that mention
  `/issue-prd`, `/issue-rework`, `/merge-issue`, `/map-states`, or `/runner`.
- **Pure old-branding lines** — standalone "Glori Builder" / old-Quetrex branding
  lines that carry no other instruction. Do not touch lines where the branding is
  embedded in content you must preserve; when in doubt, keep the line.

Preserve all other content, ordering, and formatting. Compute the edit precisely —
either with a `node` script that splits on headings / filters lines, or with
targeted `Edit` calls against the exact text you read. Track the exact file path and
each block/line you remove so you can report it.

If a file does not exist, skip it silently. After processing, build a precise list of
what changed.

> Implementation note: read each file with the Read tool using its **absolute
> `$REPO_ROOT/…` path** (never a bare or global path), decide the removals, and apply
> them with `Edit` (exact-match) calls or by writing back a `node`-computed version.
> Never blank a whole file; only excise the matched blocks/lines. Never touch any
> `CLAUDE.md` outside `$REPO_ROOT` — in particular, never the global `~/.claude/CLAUDE.md`.

---

## 4a. Ensure the Learning / LESSONS block (top of project CLAUDE.md)

Every adopted repo's **project** `.claude/CLAUDE.md` must open with the Learning
protocol so corrections are captured as durable one-line rules. This is
**non-destructive** and **prepend-only** — it never rewrites or reorders existing
content; it only inserts the block at the very top when it is absent.

**Target file (resolve strictly, never the global file):**

```bash
PROJ_RULES="$REPO_ROOT/.claude/CLAUDE.md"
```

Use this exact `$REPO_ROOT`-anchored path — never a bare/CWD-relative `.claude/CLAUDE.md`
and **never** the user's global `~/.claude/CLAUDE.md` (same hard-pin guardrail as step 4).

**1. Idempotent check.** If `$PROJ_RULES` already contains a `# Learning` heading, leave
it untouched and report *"Learning block already present."* Detect with `node` (do not
`cat`):

```bash
if [ -f "$PROJ_RULES" ] && node -e '
  const fs=require("fs");
  process.exit(/^#\s+Learning\s*$/m.test(fs.readFileSync(process.argv[1],"utf8"))?0:1);
' "$PROJ_RULES"; then
  echo "Learning block already present."
  LEARNING_CHANGED=0
else
  LEARNING_CHANGED=1   # absent — prepend below
fi
```

**2. Prepend the block** (only when `LEARNING_CHANGED=1`). Read the existing file (if any)
and write the Learning/LESSONS block followed by the original content — never truncate,
never reorder. Use a `node` writer so nothing is echoed to the shell:

```bash
node -e '
  const fs=require("fs");
  const file=process.argv[1];
  let cur="";
  try { cur=fs.readFileSync(file,"utf8"); } catch {}
  if (/^#\s+Learning\s*$/m.test(cur)) process.exit(0);   // never duplicate
  const block=[
    "# Learning","",
    "When I correct you or you catch yourself making a mistake, before continuing, add the lesson as a one-line rule under #LESSONS so it never happens again.","",
    "# LESSONS","",
    "(Place Lessons Here)","",
  ].join("\n");
  fs.mkdirSync(require("path").dirname(file),{recursive:true});
  fs.writeFileSync(file, block + (cur ? "\n" + cur : ""));
' "$PROJ_RULES"
echo "Prepended Learning/LESSONS block to $PROJ_RULES"
```

Same `$REPO_ROOT` pin and "never the global file" rule as step 4. Record whether 4a
prepended the block so step 6 stages the file and step 7 reports it.

---

## 4b. Ensure project Verification rules

The QA agent reads the **project** `.claude/CLAUDE.md` `## Verification` section to know
which commands to run. Guarantee that section exists so QA always has it. This is the
fold of the former `/create-rules` — minimal, **non-destructive**, append-only, and
strictly pinned to `$REPO_ROOT`.

**Target file (resolve strictly, never the global file):**

```bash
PROJ_RULES="$REPO_ROOT/.claude/CLAUDE.md"
```

Use this exact `$REPO_ROOT`-anchored path — never a bare/CWD-relative `.claude/CLAUDE.md`
and **never** the user's global `~/.claude/CLAUDE.md` (same hard-pin guardrail as step 4).

**1. Idempotent check.** If `$PROJ_RULES` already contains a `## Verification` heading,
leave it untouched and report *"Verification rules already present."* Detect with `node`
(do not `cat`):

```bash
if [ -f "$PROJ_RULES" ] && node -e '
  const fs=require("fs");
  process.exit(/^##\s+Verification\s*$/m.test(fs.readFileSync(process.argv[1],"utf8"))?0:1);
' "$PROJ_RULES"; then
  echo "Verification rules already present."
  VERIF_CHANGED=0
else
  VERIF_CHANGED=1   # absent — detect, confirm, append below
fi
```

**2. Auto-detect candidate commands** (only when `VERIF_CHANGED=1`). Read repo signals
with the **Read tool** or `node` (never `cat`) and map to a verification list — order is
lint → typecheck → test → build:

- **`package.json`** → inspect its `scripts`: map `lint`/`test`/`build` and
  `typecheck`|`type-check` to `npm run <script>`. If a Biome signal is present
  (`biome` in deps/devDeps or a `biome.json`/`biome.jsonc`), prefer `npx biome check .`
  for the lint step.
- else **`pyproject.toml`** / **`requirements.txt`** → `ruff check .`, `mypy .`, `pytest`.
- else **`Cargo.toml`** → `cargo fmt --check`, `cargo clippy -- -D warnings`,
  `cargo test`, `cargo build`.
- else **`go.mod`** → `golangci-lint run`, `go vet ./...`, `go test ./...`,
  `go build ./...`.
- else **`Gemfile`** (Rails) → `bundle exec rubocop`, `bundle exec rspec`.
- else → **ask the user** for the exact verification commands; do not assume.

Only include steps that actually exist (e.g. skip `build` if there is no `build` script).

**3. Confirm with the user before writing.** Present the detected list:
*"Detected these verification commands — correct? add/remove any?"* Apply their edits.
Do not write on a genuine gap without confirmation.

**4. Append-only write** (never truncate, never reorder existing content). Use a `node`
writer that reads the existing file (if any), bails if a `## Verification` heading is
already present, and otherwise appends the confirmed block. Pass the confirmed commands
as argv (one per line, in order):

```bash
# CONFIRMED_STEPS = the user-confirmed commands, one per line, in run order.
node -e '
  const fs=require("fs");
  const file=process.argv[1];
  const steps=process.argv.slice(2).filter(Boolean);
  let cur="";
  try { cur=fs.readFileSync(file,"utf8"); } catch {}
  if (/^##\s+Verification\s*$/m.test(cur)) process.exit(0);   // never duplicate
  const fresh=(cur.trim()==="");
  const lines=[];
  if (fresh) lines.push(`# Project: ${process.argv[1].split("/").slice(-3,-2)[0]||"this project"}`,"");
  lines.push("## Verification","Run in this order — all must pass before any PR:");
  steps.forEach((s,i)=>lines.push(`${i+1}. \`${s}\``));
  const sep = (cur && !cur.endsWith("\n")) ? "\n\n" : (cur ? "\n" : "");
  fs.mkdirSync(require("path").dirname(file),{recursive:true});
  fs.writeFileSync(file, cur + sep + lines.join("\n") + "\n");
' "$PROJ_RULES" "${CONFIRMED_STEPS[@]}"
echo "Wrote ## Verification to $PROJ_RULES"
```

Same `$REPO_ROOT` pin and "never the global file" rule as step 4. Record whether 4b
created or appended so step 6 stages the file and step 7 reports it.

---

## 4c. Stale project-command cleanup (with confirmation)

During adoption of an **existing** repo, scan the repo's **project-level** command/skill
directories for STALE old-Quetrex artifacts and offer to remove them — **never without
confirmation**. This excises dead pipeline commands left over from a previous Quetrex
generation so the adopted repo's `.claude/` matches the current command set.

Operate **only** on these two `$REPO_ROOT`-pinned directories (same hard-pin guardrail as
step 4):

- `$REPO_ROOT/.claude/commands/`  (one `*.md` per command; basename = command name)
- `$REPO_ROOT/.claude/skills/`    (one subdirectory per skill; dir name = skill name)

> **IMPORTANT:** this is about the *adopted repo's own* project-level `.claude/`, **NOT**
> the user's global `~/.claude` (never touch `~/.claude`) and **NOT** the new global
> Quetrex skills. Resolve everything against `$REPO_ROOT` — never a bare/CWD-relative path.
> If neither directory exists, skip this step silently.

**1. Flag likely-stale artifacts.** A file/skill is FLAGGED when ANY of these holds:

- Its basename (command file name without `.md`, or skill directory name) is in the known
  REMOVED old-Quetrex command set:
  `issue-prd`, `issue-rework`, `map-states`, `complete`, `auto-pilot`, `plan-project`,
  `runner`, `deploy-setup`, `create-prd`, `create-rules`, `update-rules`, `execute`,
  `prime`, `plan-feature`, `project-setup`, `quetrex-docs`, `quetrex-setup`, `secrets`,
  `new-video`,
  `que-task`, `new-task`, `refine-task`, `rework`, `task-merge`, `task-complete`.
- Its skill directory name is in the known REMOVED old-Quetrex skill set:
  `domain-capture`, `story-builder`, `agent-browser`, `e2e-test`, `quetrex`,
  `quetrex-create-agent`, `quetrex-create-plugin`.
- Its CONTENT references the removed tracker/pipeline — e.g. `Linear`, `api.linear.app`,
  or the removed pipeline commands (`/issue-prd`, `/issue-rework`, `/merge-issue`,
  `/map-states`, `/runner`). For a skill, check its `SKILL.md` (and any `*.md`) content.

Detect with the **Read tool** / `node` (never `cat`). Record, per flagged item, the
absolute path and a one-line reason (which rule matched).

**2. Present + confirm.** Show the flagged list — name + one-line reason each — and ASK the
user to confirm removal. Allow **per-item or batch** selection. PRESERVE anything genuinely
custom; when unsure, **KEEP it** and let the user decide. **Never auto-delete without
confirmation.** If nothing is flagged, say *"No stale project commands found."* and move on.

**3. Remove only the confirmed items** with `git rm` (so the removal is staged into the same
adoption commit/PR as steps 4/4b). Use `git -C "$REPO_ROOT"` so the enforce-branch hook sees
the branch. Files use `git rm`; skill directories use `git rm -r`:

```bash
# CONFIRMED_PATHS = the user-confirmed $REPO_ROOT-relative paths to remove (commands as
# .claude/commands/<name>.md, skills as .claude/skills/<name>). Empty => nothing to do.
for rel in "${CONFIRMED_PATHS[@]}"; do
  [ -n "$rel" ] || continue
  if [ -d "$REPO_ROOT/$rel" ]; then
    git -C "$REPO_ROOT" rm -r --quiet -- "$rel" && echo "Removed stale skill: $rel"
  elif [ -f "$REPO_ROOT/$rel" ]; then
    git -C "$REPO_ROOT" rm --quiet -- "$rel" && echo "Removed stale command: $rel"
  fi
done
```

Track exactly what was removed vs kept so step 6 includes the removals and step 7 reports
them.

---

## 4d. Deploy the committed per-project build gates

**Why:** the real gate scripts (`verify-gate.sh`, `merge-gate.sh`, `secret-scan.sh`, plus
`deny-guard.sh`/`enforce-branch.sh`) and the seven fat pipeline agents live in the
operator's **global** `~/.claude`. A local Claude Code session already sees them there —
but any **Anthropic cloud routine** only ever sees what is **committed to this repo**; it
clones the repo and never touches the operator's machine. Without this step the gates
would silently no-op in the cloud (no `.claude/hooks/verify-gate.sh` to run, no wiring in
`.claude/settings.json` to call it). Running this step makes the build gates fire
**both locally and in cloud routines**, from the same committed source.

This is the same non-destructive adoption this command already performs: it only ever
copies the specific quetrex hook/agent files and merges the specific quetrex hook entries
into `.claude/settings.json` — it never touches any other hook, permission, or setting
already in the repo.

```bash
bash ~/.claude/lib/quetrex-install-project-gates.sh "$REPO_ROOT"
```

This deploys, idempotently:

- `.claude/hooks/verify-gate.sh`, `merge-gate.sh`, `secret-scan.sh`, `deny-guard.sh`,
  `enforce-branch.sh` — copied in and made executable.
- `.claude/agents/architect.md`, `developer.md`, `qa.md`, `reviewer.md`,
  `security-reviewer.md`, `git-workflow.md`, `database-architect.md` — the seven fat
  pipeline agents, so cloud routines run the same agents as a local session.
- `.claude/settings.json` — merged (never clobbered) to wire `verify-gate.sh` on
  `Stop`/`SubagentStop` and `deny-guard.sh`/`secret-scan.sh`/`enforce-branch.sh`/
  `merge-gate.sh` on the relevant `PreToolUse` matchers, using
  `$CLAUDE_PROJECT_DIR`-relative paths so they resolve in a fresh clone.
- `.quetrex/verify.json` — seeded from the committed Next.js template on first run only
  (never overwritten once present), giving QA and `verify-gate.sh` the exact verify chain
  to run.

A non-zero exit means the helper already printed the exact cause (e.g. the global
install is missing a required hook/agent) — surface it verbatim and stop; do not
silently continue past a failed gate deployment.

Track that this step ran (and whether it changed anything) so step 6 stages the result
and step 7 reports it.

---

## 5. Point to /keys (never prompt for secrets)

Print exactly:

> Set this project's deploy secrets at https://dash.quetrex.com/keys — do not paste keys here.

Do not prompt for, read, or store any key values in this command.

---

## 5b. Import local env creds into the vault (offer, never echo a value)

Before sending the user off to paste keys by hand, see what's already on disk in this
repo's local env files and offer to import them straight into the project's vault. This
turns the bare "set them in the dashboard" pointer into a one-keystroke import.

**SECRET SAFETY (the invariant of this step):** the scan and import NEVER print a secret
value or the bearer token. The only value-derived output is a masked last-4 tail. Each
value flows **file → `node` → `qapi` → vault** and is never echoed, never on argv as a
value, never written to disk or logs. No `set -x`, no `curl -v`. `unset` after use.

Requires the project to be linked: ensure `QX_PROJECT_CODE` is resolved (it is, from this
command's flow once linked — otherwise `resolve_project`).

**1. Scan.** Use the shared `qx_env_scan` helper, which reads `$REPO_ROOT/.env`,
`.env.local`, and `.env.*` (skipping `*.example`/`*.sample`), parses them in `node`
(handles `KEY=value`, `export KEY=…`, quotes, `#` comments), filters to relevant
credential names, normalizes variants (notably `FLY_TOKEN` → `FLY_API_TOKEN`), and emits
`FILE<TAB>RAWNAME<TAB>CANON<TAB>****<last4>` — masked tail only, never the value:

```bash
source ~/.claude/lib/quetrex-api.sh   # already sourced earlier; harmless to re-source
SCAN="$(qx_env_scan "$REPO_ROOT")"
if [ -z "$SCAN" ]; then
  echo "No local env credentials found to import."
fi
```

**2. Show + ask.** If `SCAN` is non-empty, present the discovered entries by **CANON name
+ masked last-4 only** (e.g. `FLY_API_TOKEN … ****CDEF`), then ask:
*"Import these N keys into the project's vault?"* On **no**, skip the import. On **yes**,
import each one — read the value inside `node` straight from its file via the shared
`qx_secret_put_from_env` helper (PUT `/api/projects/$QX_PROJECT_CODE/secrets` with
`{name,value}`); the value is never visible to the shell:

```bash
# Iterate the scan lines; FILE/RAWNAME/CANON are non-secret, the value stays inside node.
while IFS=$'\t' read -r ENVFILE RAWNAME CANON MASK; do
  [ -n "$CANON" ] || continue
  if qx_secret_put_from_env "$ENVFILE" "$RAWNAME" "$CANON"; then
    echo "Imported $CANON ($MASK)"
  else
    echo "Failed to import $CANON — set it at $QX_KANBAN_URL/keys" >&2
  fi
done <<< "$SCAN"
```

**3. Only prompt for what's missing.** Anything not found locally stays the user's job —
direct them to `dash.quetrex.com/keys` for those specific names only. Never re-prompt for
a credential that was just imported.

---

## 6. Commit the additions — PR if possible, else local

Follow the `worktree-workflow` conventions. Stage **only** the additions/cleanups:
`.quetrex/project.json` plus any `CLAUDE.md` edits made in step 4, and the build gates
deployed in step 4d. The confirmed stale removals from step 4c are already staged (they
were `git rm`'d into the index), so they ride along in this same commit/PR. Use
`git -C "$REPO_ROOT"` so the enforce-branch hook sees the branch rather than blocking on
`main`.

```bash
BRANCH="feature/q-init-adopt"
git -C "$REPO_ROOT" checkout -b "$BRANCH" 2>/dev/null || git -C "$REPO_ROOT" checkout "$BRANCH"

# Stage only what this command added/cleaned: the binding, any CLAUDE.md cleanups
# (step 4), the project Verification rules created/appended in step 4b, and the
# committed build gates deployed in step 4d (hooks + fat agents + settings.json wiring +
# .quetrex/verify.json). Each `add` is a no-op if that path has nothing new to stage.
git -C "$REPO_ROOT" add .quetrex/project.json 2>/dev/null || true
[ -f "$REPO_ROOT/CLAUDE.md" ]        && git -C "$REPO_ROOT" add CLAUDE.md 2>/dev/null || true
[ -f "$REPO_ROOT/.claude/CLAUDE.md" ] && git -C "$REPO_ROOT" add .claude/CLAUDE.md 2>/dev/null || true
git -C "$REPO_ROOT" add .claude/hooks/verify-gate.sh .claude/hooks/merge-gate.sh \
  .claude/hooks/secret-scan.sh .claude/hooks/deny-guard.sh .claude/hooks/enforce-branch.sh \
  2>/dev/null || true
git -C "$REPO_ROOT" add .claude/agents/architect.md .claude/agents/developer.md \
  .claude/agents/qa.md .claude/agents/reviewer.md .claude/agents/security-reviewer.md \
  .claude/agents/git-workflow.md .claude/agents/database-architect.md 2>/dev/null || true
[ -f "$REPO_ROOT/.claude/settings.json" ] && git -C "$REPO_ROOT" add .claude/settings.json 2>/dev/null || true
[ -f "$REPO_ROOT/.quetrex/verify.json" ]  && git -C "$REPO_ROOT" add .quetrex/verify.json 2>/dev/null || true

if git -C "$REPO_ROOT" diff --cached --quiet; then
  echo "Nothing to commit — repo already adopted."
else
  git -C "$REPO_ROOT" commit -m "chore: adopt repo into Quetrex project $CODE

Add .quetrex/project.json binding, clean stale tracker references, ensure project
Verification rules, and deploy the committed per-project build gates (hooks + fat
agents + .quetrex/verify.json) so they fire locally and in cloud routines." >/dev/null

  # Open a PR only if there is a remote AND gh is available.
  if git -C "$REPO_ROOT" remote get-url origin >/dev/null 2>&1 && command -v gh >/dev/null 2>&1; then
    git -C "$REPO_ROOT" push -u origin "$BRANCH" >/dev/null 2>&1
    PR_URL="$(gh pr create --repo "$(git -C "$REPO_ROOT" remote get-url origin)" \
      --head "$BRANCH" \
      --title "chore: adopt repo into Quetrex project $CODE" \
      --body "Links this repo to Quetrex project \`$CODE\` (adds \`.quetrex/project.json\`), cleans stale tracker references from CLAUDE.md, and deploys the committed per-project build gates (hooks + fat agents + .quetrex/verify.json) so they fire locally and in cloud routines. Non-destructive: no existing config or history was overwritten." 2>/dev/null)"
    if [ -n "$PR_URL" ]; then
      echo "Opened PR: $PR_URL"
    else
      echo "Committed on $BRANCH, but PR creation failed — open one manually."
    fi
  else
    echo "Committed locally on $BRANCH; no remote configured (or gh unavailable), so no PR was opened."
  fi
fi
```

---

## 7. Final report

Summarize for the user:

- **Linked / created** — `.quetrex/project.json` → `<CODE>` (state whether it was
  already linked, newly created, or admin-blocked).
- **Cleaned** — each `CLAUDE.md` file and the exact blocks/lines removed; or
  *"no stale tracker references found"* if nothing matched.
- **Learning block** — *"prepended"* or *"already present"* for the project
  `.claude/CLAUDE.md` Learning/LESSONS header.
- **Verification rules** — *"added"* (with the commands written), *"already present"*, or
  the file path that now carries the `## Verification` section.
- **Stale project commands** — which flagged command/skill artifacts were removed (by path)
  vs kept, or *"no stale project commands found"* if nothing matched.
- **Build gates** — the summary printed by `quetrex-install-project-gates.sh`: which
  hooks/agents were (re)deployed, how many new hook entries were wired into
  `.claude/settings.json`, and whether `.quetrex/verify.json` was written or already
  present.
- **Secrets** — which local env creds were imported into the vault (by CANON name +
  masked last-4, never values), and the `dash.quetrex.com/keys` reminder for any missing
  ones.
- **Delivery** — the PR URL, or the local-commit note if no remote.

---

## Error-handling rules

- Reuse the helper's messaging verbatim: `401 → Run /q-login`,
  `403/404 → No access — contact your administrator`. The **only** override is the
  create-project 403, where you print the admin-specific hint instead.
- Never print the bearer token. Build all JSON with `node` / `JSON.stringify`.
- Idempotent: re-running on a linked repo never re-creates the binding and never
  prompts for a name — it re-verifies access and can re-clean / re-PR.
- Non-destructive: the files this command creates are `.quetrex/project.json` and the
  build-gate artifacts from step 4d (`.claude/hooks/{verify-gate,merge-gate,secret-scan,
  deny-guard,enforce-branch}.sh`, the seven fat `.claude/agents/*.md`, and
  `.quetrex/verify.json`); `CLAUDE.md` edits only excise stale tracker blocks, never
  wholesale rewrites; `.claude/settings.json` is merged, never clobbered. The only
  removals are user-confirmed stale old-Quetrex project commands/skills (step 4c) —
  never auto-deleted, never anything in the global `~/.claude` (step 4d only ever *reads*
  from `~/.claude`, it never writes there).
