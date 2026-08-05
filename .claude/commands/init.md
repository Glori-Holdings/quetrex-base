---
description: Link this repo to a Quetrex project (writes ./.quetrex/project.json with its branchPrefix) or create one, then non-destructively adopt the repo (clean stale tracker refs, ensure project Verification rules, pin the quetrex-factory engine in enabledPlugins so its build gates run locally and in cloud routines, union in the permissions the pipeline needs, generate .worktreeinclude, offer /install-github-app, offer to import local env creds into the vault, open a PR). Usage: /quetrex:init [project name]
argument-hint: "[project name — only used when the repo is not yet linked]"
---

# Quetrex Init

Bind this repository to a Quetrex project. If the repo is **already linked**
(`./.quetrex/project.json` exists), re-verify access and re-run adoption — never
re-create the binding and never prompt for a name. If it is **not linked**, create
the project (or surface the admin-only guidance on 403) and write the binding.

This command is **non-destructive**: it only ever ADDs `.quetrex/project.json`,
auto-cleans stale tracker references from `CLAUDE.md`, and pins the `quetrex-factory`
plugin in `enabledPlugins` (step 4h) — the build engine that ships the
`verify-gate.sh`/`merge-gate.sh`/`secret-scan.sh` hooks and the fat pipeline agents, so
they run **both locally and in cloud routines** with no per-project copy required. It
also **unions in** the permissions the pipeline needs (4e), writes a `.worktreeinclude`
so worktrees are actually runnable (4f), and **offers** `/install-github-app` (4g). It
never overwrites or silently deletes existing `.claude/`,
`CLAUDE.md` body content, commands, other settings/hooks, or any git/Claude history, and
it never removes or narrows a permission the repo already had. The **only** removals are
stale old-Quetrex project commands/skills, and only the specific ones the user
**confirms** (step 4c) — never auto-deleted. Secrets are never prompted for here — they
live at `dash.quetrex.com/keys`.

**Token safety:** never echo or print the bearer token. The helper's `quetrex-api` injects
it via a `0600` temp config and never exposes it. Build all JSON with
`node` / `JSON.stringify`, never with `echo`. No `set -x`, no `curl -v`.

---

## 1. Resolve auth

Run a single bash block. The `quetrex-api` tool (shipped on the plugin's PATH) owns all auth
messaging — do not reinvent it.

```bash
QX_KANBAN_URL="$(quetrex-api kanban-url)" || exit 1   # prints "Run /quetrex:login" on miss/expiry
```

If it fails, surface its message verbatim and stop. `QX_KANBAN_URL` is now set from
`auth.json` and is the source of truth for the binding's `kanbanUrl`.

---

## 2. Detect an existing binding

Walk up from `$PWD` for `.quetrex/project.json` (the same walk `quetrex-api project-code`
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
CODE="$(quetrex-api json-get "$BIND" projectCode)" || { echo "Binding is unreadable — fix or remove $BIND and re-run." >&2; exit 1; }
echo "This repo is linked to project $CODE"
quetrex-api GET "/api/projects/$CODE" >/dev/null || exit 1   # helper prints 401→login, 403/404→no access
```

A non-zero `quetrex-api` exit means the helper already printed the correct message — stop.
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
if ! RESP="$(quetrex-api POST /api/projects "$PAYLOAD")"; then
  # quetrex-api already printed a message. The most common failure here is 403 — project
  # creation currently requires admin. Give the clearer, action-specific guidance.
  echo "Creating a project requires admin — ask a super_admin to create it, or get added to an existing project, then re-run /quetrex:init." >&2
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
  const [path, projectCode, kanbanUrl, branchPrefix] = process.argv.slice(1);
  fs.writeFileSync(path, JSON.stringify({projectCode, kanbanUrl, branchPrefix}, null, 2) + "\n");
' "$REPO_ROOT/.quetrex/project.json" "$CODE" "$QX_KANBAN_URL" "$BRANCH_PREFIX"
echo "Wrote binding: $REPO_ROOT/.quetrex/project.json → $CODE (branchPrefix=$BRANCH_PREFIX)"
```

See **3d** for how `$BRANCH_PREFIX` is chosen — decide it before writing the binding.

**d. Choose `branchPrefix` — do not hardcode `feature/`.**

Every branch the pipeline creates is built from this value. It exists because an
**Anthropic cloud routine starts from a fresh clone of the default branch and can only
push to `claude/`-prefixed branches** unless that restriction is loosened per repo. Nothing
else in the workflow breaks under that restriction — worktrees, local sub-branch commits,
merging sub-branches locally, basing off an integration branch and diffing `main...HEAD` all
survive. **Only the push breaks — and with no push there is no PR, so the pipeline has no
terminus.**

```bash
BRANCH_PREFIX="feature/"   # default
```

Ask the user only when it matters, and give them the real trade-off:

> This repo's branches will be named `feature/<task>`. If you plan to run Quetrex builds
> as cloud routines and you **cannot** loosen the branch restriction on this repo, choose
> `claude/` instead — routines can only push to `claude/*` by default. Loosening the repo
> is the better option where you have the access, because the restriction is a real
> guardrail against an autonomous run touching `main`.

Accept only a value ending in `/`. On an **already-linked** repo (step 2a), if
`branchPrefix` is absent from the binding, add it with the default rather than re-prompting
— every consumer already defaults to `feature/`, so this is a pure backfill:

```bash
node -e '
  const fs=require("fs"); const f=process.argv[1];
  const o=JSON.parse(fs.readFileSync(f,"utf8"));
  if(!o.branchPrefix){ o.branchPrefix="feature/"; fs.writeFileSync(f, JSON.stringify(o,null,2)+"\n"); console.log("backfilled branchPrefix=feature/"); }
' "$BIND"
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
  lines.push("## Verification","Run in this order — all must pass before any PR:","");
  // Emit a FENCED block, one bare command per line. verify-gate.sh and the
  // qa-verify skill both extract the chain from the fence under this heading;
  // a prose list of backticked items is not what they parse. Never emit a
  // comment inside the fence — the extractors read those lines verbatim.
  // (The fence marker is built from char codes so this snippet can itself live
  // inside a fenced block without closing it.)
  const FENCE = String.fromCharCode(96,96,96);
  lines.push(FENCE + "bash");
  steps.forEach(s=>lines.push(s));
  lines.push(FENCE);
  const sep = (cur && !cur.endsWith("\n")) ? "\n\n" : (cur ? "\n" : "");
  fs.mkdirSync(require("path").dirname(file),{recursive:true});
  fs.writeFileSync(file, cur + sep + lines.join("\n") + "\n");
' "$PROJ_RULES" "${CONFIRMED_STEPS[@]}"
echo "Wrote ## Verification to $PROJ_RULES"
```

The same confirmed list is also the seed for `.quetrex/verify.json` — the machine-readable
chain that takes precedence over this section. This block is the human-readable fallback.

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

## 4e. Merge the pipeline's required permissions into project settings

**Why this is the only channel that works.** A plugin can ship hooks (`hooks/hooks.json`)
and per-agent `permissionMode` in frontmatter, but **a plugin cannot ship a
`permissions.allow` block** — Claude Code honours only two keys from a plugin's
`settings.json`. The pipeline's terminal stage runs `git push` and `gh pr create`, and
neither is a "filesystem bash command" that `acceptEdits` covers. Without an allow-list,
those calls prompt — and in an unattended run there is no one to answer, so **the pipeline
hangs at the last step with the work already done.** Writing the allow-list into the
customer's own project settings is what survives plugin packaging.

Merge — never clobber — into `$REPO_ROOT/.claude/settings.json`. Union with whatever is
already there, preserve every other key, and write only if something was actually added:

```bash
node -e '
  const fs=require("fs"), path=require("path");
  const file=process.argv[1];
  const need=[
    "Bash(git push:*)","Bash(gh pr:*)","Bash(git worktree:*)","Bash(git checkout:*)",
    "Bash(git merge:*)","Bash(git diff:*)","Bash(git rev-parse:*)","Bash(git add:*)",
    "Bash(git commit:*)","Bash(jq:*)","Bash(mkdir:*)","Write","Edit"
  ];
  let o={};
  try { o=JSON.parse(fs.readFileSync(file,"utf8")); } catch {}
  o.permissions = o.permissions || {};
  const cur = Array.isArray(o.permissions.allow) ? o.permissions.allow : [];
  const added = need.filter(n => !cur.includes(n));
  if (!added.length) { console.log("permissions.allow already covers the pipeline."); process.exit(0); }
  o.permissions.allow = cur.concat(added);
  fs.mkdirSync(path.dirname(file), {recursive:true});
  fs.writeFileSync(file, JSON.stringify(o, null, 2) + "\n");
  console.log("Added " + added.length + " pipeline permission(s): " + added.join(", "));
' "$REPO_ROOT/.claude/settings.json"
```

**Never remove or narrow an entry the repo already had**, and never touch
`permissions.deny` or `permissions.ask` — those are the customer's. This step only ever
adds. Note in the report that these are *additions to the customer's own settings*, so
they are visible and revocable by them.

---

## 4f. Generate `.worktreeinclude`

**Why:** `git worktree` checks out **tracked files only**. Every developer in the pipeline
runs in a worktree, and `node_modules/` and `.env*` are git-ignored — so without this an
agent lands in a tree with no deps and no env, and must still make the build exit 0. It
burns all three bounded self-heal attempts "fixing" code that was never broken, and the
artefacts of that flailing are hardcoded credentials and weakened tests. This file is the
cheapest fix in the adoption.

The file list is already known: step 5b's `quetrex-api env-scan` enumerates this repo's env files.
If 5b has not run yet, call `quetrex-api env-scan "$REPO_ROOT"` here — it is read-only and safe to
run twice. **Take only the FILE column** (the masked-value column never leaves that step):

```bash
ENV_FILES=()
while IFS=$'\t' read -r ENVFILE _RAW _CANON _MASK; do
  [ -n "$ENVFILE" ] || continue
  ENV_FILES+=("${ENVFILE#$REPO_ROOT/}")
done <<< "$(quetrex-api env-scan "$REPO_ROOT")"
```

Write the union of those, plus any local Claude settings, **append-only and idempotent** —
never drop an entry the user added:

```bash
WTI="$REPO_ROOT/.worktreeinclude"
# ENV_FILES = the FILE column of quetrex-api env-scan output (see 5b), de-duplicated and made
# repo-relative. Add local-only config that every worktree also needs.
node -e '
  const fs=require("fs");
  const [file, ...cands] = process.argv.slice(1);
  let cur=""; try { cur=fs.readFileSync(file,"utf8"); } catch {}
  const have=new Set(cur.split("\n").map(s=>s.trim()).filter(Boolean));
  const add=cands.filter(c=>c && !have.has(c));
  if(!add.length){ console.log(".worktreeinclude already current."); process.exit(0); }
  const header = cur ? "" :
    "# Git-ignored paths every worktree needs. Listing a path here does NOT commit it.\n" +
    "# NOTE: the harness applies this to the worktrees IT creates; a manual\n" +
    "# `git worktree add` must copy these itself (see the worktree-workflow skill).\n";
  fs.writeFileSync(file, header + cur + (cur && !cur.endsWith("\n") ? "\n" : "") + add.join("\n") + "\n");
  console.log("Added to .worktreeinclude: " + add.join(", "));
' "$WTI" ".env" ".env.local" ".claude/settings.local.json" "${ENV_FILES[@]}"
```

Only list paths that actually exist in this repo — a phantom entry is noise the copy step
has to skip every time. **Never list a path that is tracked in git** (it is already in the
worktree) and never list a directory of build output.

---

## 4g. Offer `/install-github-app` (ask, never run unprompted)

The GitHub Action path (`anthropics/claude-code-action@v1`) is how a check runs in CI
rather than inside the agent that wrote the code — the only reviewer whose exit status the
pipeline cannot self-report. Setting it up starts with `/install-github-app`, which needs
**repo admin** and walks through installing the GitHub app and setting the API key secret.

Detect whether it is already in place and offer it once:

```bash
gh api "repos/$(git -C "$REPO_ROOT" remote get-url origin | sed -E 's#.*[:/]([^/]+/[^/]+?)(\.git)?$#\1#')/installation" >/dev/null 2>&1 \
  && echo "Claude GitHub app: already installed." \
  || echo "Claude GitHub app: not installed."
```

If not installed, say:

> To run Quetrex's checks in CI on every PR, install the Claude GitHub app with
> `/install-github-app` (needs repo admin). Want to do that now? It is optional — the
> local gates work without it.

**Do not run `/install-github-app` without an explicit yes**, and do not block adoption on
it. If they decline, record it and move on.

---

## 4h. Arm the repo for cloud execution — `quetrex-arm`

Cloud routines and every teammate read which engine to run, and how to reach the kanban,
from what is **committed** in this repo — `.claude/settings.json` `enabledPlugins` +
`extraKnownMarketplaces`, and `.mcp.json`'s kanban broker registration — never from any one
machine's local plugin cache or MCP config. These writes used to be inline `node` prose
right here in this command; that prose did not reliably execute (a run could finish with
empty `enabledPlugins`, no `.mcp.json`, and no `extraKnownMarketplaces`), so arming is now a
**deterministic executable**, `quetrex-arm`, shipped on the plugin's `bin/` (which IS on
PATH in slash-command bash, unlike the plugin-root path variable, which is unset in this
context — call it by name, never source it):

```bash
QUETREX_ARM_OUTPUT="$(quetrex-arm "$REPO_ROOT" "$QX_KANBAN_URL")"; QUETREX_ARM_RC=$?
printf '%s\n' "$QUETREX_ARM_OUTPUT"
if [ "$QUETREX_ARM_RC" -ne 0 ]; then
  echo "quetrex-arm failed — .claude/settings.json / .mcp.json may be only partially armed. Re-run /quetrex:init once resolved." >&2
fi
```

`quetrex-arm` idempotently and non-destructively writes, into `$REPO_ROOT`:

- `.claude/settings.json` `enabledPlugins`: `"quetrex@quetrex": true` (the command layer,
  not version-gated per repo) and `"quetrex-factory@quetrex": ["<concrete version>"]` — a
  **concrete version pin**, never a floating `true`, resolved from the public marketplace
  manifest on GitHub raw. The value is a one-element **array**: Claude Code's
  `enabledPlugins` schema accepts a boolean or an array of semver ranges, and a bare version
  *string* fails settings validation with `Invalid input`, silently dropping the pin. If the
  marketplace is unreachable it still enables `quetrex@quetrex` and reports that the factory
  pin is deferred until `/quetrex:update` is run online.
- `.claude/settings.json` `extraKnownMarketplaces.quetrex.source`:
  `{"source":"github","repo":"Glori-Holdings/quetrex-plugins"}` — without this the
  `quetrex-factory` pin above cannot resolve.
- `.mcp.json` `mcpServers.quetrex-kanban`: `{"type":"http","url":"<kanbanUrl>/api/mcp"}` —
  **endpoint only, no secret value**. The broker authenticates cloud sessions and
  auto-rotates their credentials.
>>>>>>> origin/main

Every write merges — it never clobbers any other `enabledPlugins` entry, any other
`extraKnownMarketplaces` entry, any other `mcpServers` entry, or any other settings key.
Record whatever `quetrex-arm` printed (each concern reports "wrote ..." or "already
current"/"already registers ...") so step 6 stages `.claude/settings.json` + `.mcp.json`
and step 7 reports it verbatim.

---

## 4j. One-time legacy cleanup (guarded, reversible, per-machine)

The npm era seeded Quetrex files into the operator's **global** `~/.claude`; the plugin era
does not. Offer to clean those leftovers **once per machine** — idempotent, allowlist-scoped,
pristine-only, reversible (quarantine, never hard-delete), and gated by two agreeing agents
plus a per-item human decision. The deterministic engine ships as the `quetrex-cleanup` tool
on the plugin's PATH (it keeps its once-per-machine marker under `${CLAUDE_PLUGIN_DATA}`,
never `~/.claude`, never the repo).

**1. Skip if already offered on this machine:**

```bash
if quetrex-cleanup already-ran; then
  echo "Legacy cleanup already offered on this machine — skipping."
else
  quetrex-cleanup scan   # read-only TSV: STATUS<TAB>REL<TAB>REASON (empty => nothing to clean)
fi
```

If `scan` prints nothing, say *"No npm-era Quetrex artifacts found in ~/.claude."*, run
`quetrex-cleanup mark-done`, and move on.

**2. Two-agent gate.** When `scan` returns candidates, launch **both** cleanup agents (via
the Task tool) on the scan output:

- `quetrex-cleanup-proposer` — proposes a per-item KEEP/REMOVE/STRIP plan (conservative,
  default KEEP).
- `quetrex-cleanup-auditor` — independently re-inspects each proposed REMOVE/STRIP and
  **vetoes** anything user-owned or modified.

Only items **both** agents agree are removable proceed. Any disagreement is **escalated to
the human** as an open question — never auto-resolved.

**3. Per-item human gate.** For each agreed item, ask the user in plain English — *what* the
item is and *why* it is proposed for removal — and take a **per-item KEEP/REMOVE** decision.
The default is **KEEP**; the user may decline any single item. Never batch-remove without
per-item consent.

**4. Apply — reversibly.** For the items the user approved:

```bash
# APPROVED = the ~/.claude-relative paths the user confirmed for removal.
quetrex-cleanup quarantine "${APPROVED[@]}"   # MOVES each into ~/.claude/.quetrex-backup-<ts>/
# For an approved SURGICAL item, strip ONLY Quetrex's own entries (never user content):
#   quetrex-cleanup strip-settings     # drops Quetrex hook entries + the npm-era statusLine
#   quetrex-cleanup strip-claudemd     # drops only the @quetrex-doctrine.md import line
quetrex-cleanup mark-done                     # never offer again on this machine
```

`secrets.env` is **never removed** — it is only ever flagged so the user knows it is there.
Everything quarantined stays restorable from the timestamped backup dir the engine prints.

Record what was quarantined / stripped / kept / flagged so step 7 reports it.

---

## 4k. Note the Quetrex workflow in the project `CLAUDE.md`

So anyone (and any agent) opening this repo knows work flows through the board, append a
one-line note to the project `.claude/CLAUDE.md` — **append-only and idempotent**, never
rewriting or reordering existing content. Use the same `$REPO_ROOT`-pinned path and
"never the global file" rule as step 4:

```bash
PROJ_RULES="$REPO_ROOT/.claude/CLAUDE.md"
node -e '
  const fs=require("fs"), path=require("path");
  const file=process.argv[1];
  let cur=""; try{cur=fs.readFileSync(file,"utf8")}catch{}
  if (/This is a Quetrex project/.test(cur)) { console.log("Quetrex note already present."); process.exit(0); }
  const note = "\n## Quetrex\n\nThis is a Quetrex project — features go through `/quetrex:task-build`, and the guarded pipeline (architect → developers → QA → reviewer → git-workflow) carries each task to a reviewed, merged PR.\n";
  fs.mkdirSync(path.dirname(file),{recursive:true});
  fs.writeFileSync(file, cur + (cur && !cur.endsWith("\n") ? "\n" : "") + note);
  console.log("Appended the Quetrex workflow note to " + file);
' "$PROJ_RULES"
```

Record whether the note was appended so step 6 stages `.claude/CLAUDE.md` (already staged)
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
value flows **file → `node` → `quetrex-api` → vault** and is never echoed, never on argv as a
value, never written to disk or logs. No `set -x`, no `curl -v`. `unset` after use.

Requires the project to be linked: `quetrex-api secret-put` resolves the project code itself
(it walks up for `.quetrex/project.json`), so the repo just needs to be linked first.

**1. Scan.** Use the shared `quetrex-api env-scan` helper, which reads `$REPO_ROOT/.env`,
`.env.local`, and `.env.*` (skipping `*.example`/`*.sample`), parses them in `node`
(handles `KEY=value`, `export KEY=…`, quotes, `#` comments), filters to relevant
credential names, normalizes variants (notably `FLY_TOKEN` → `FLY_API_TOKEN`), and emits
`FILE<TAB>RAWNAME<TAB>CANON<TAB>****<last4>` — masked tail only, never the value:

```bash
SCAN="$(quetrex-api env-scan "$REPO_ROOT")"
if [ -z "$SCAN" ]; then
  echo "No local env credentials found to import."
fi
```

**2. Show + ask.** If `SCAN` is non-empty, present the discovered entries by **CANON name
+ masked last-4 only** (e.g. `FLY_API_TOKEN … ****CDEF`), then ask:
*"Import these N keys into the project's vault?"* On **no**, skip the import. On **yes**,
import each one — read the value inside `node` straight from its file via the shared
`quetrex-api secret-put` helper (PUT `/api/projects/$QX_PROJECT_CODE/secrets` with
`{name,value}`); the value is never visible to the shell:

```bash
# Iterate the scan lines; FILE/RAWNAME/CANON are non-secret, the value stays inside node.
while IFS=$'\t' read -r ENVFILE RAWNAME CANON MASK; do
  [ -n "$CANON" ] || continue
  if quetrex-api secret-put "$ENVFILE" "$RAWNAME" "$CANON"; then
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
`.quetrex/project.json` plus any `CLAUDE.md` edits made in step 4. The build gates
(`verify-gate.sh`/`merge-gate.sh`/`secret-scan.sh` and the fat pipeline agents) are
delivered by the `quetrex-factory` plugin pin (4h) — this command never copies hook or
agent files into the repo. The confirmed stale removals from step 4c are already staged
(they were `git rm`'d into the index), so they ride along in this same commit/PR. Use
`git -C "$REPO_ROOT"` so the enforce-branch hook sees the branch rather than blocking on
`main`.

```bash
# Use the project's own prefix — a repo pinned to "claude/" cannot push a feature/ branch.
BRANCH="${BRANCH_PREFIX}quetrex-init-adopt"
git -C "$REPO_ROOT" checkout -b "$BRANCH" 2>/dev/null || git -C "$REPO_ROOT" checkout "$BRANCH"

# Stage only what this command added/cleaned: the binding, any CLAUDE.md cleanups
# (step 4), and the project Verification rules created/appended in step 4b. Each
# `add` is a no-op if that path has nothing new to stage.
git -C "$REPO_ROOT" add .quetrex/project.json 2>/dev/null || true
[ -f "$REPO_ROOT/CLAUDE.md" ]        && git -C "$REPO_ROOT" add CLAUDE.md 2>/dev/null || true
[ -f "$REPO_ROOT/.claude/CLAUDE.md" ] && git -C "$REPO_ROOT" add .claude/CLAUDE.md 2>/dev/null || true
[ -f "$REPO_ROOT/.claude/settings.json" ] && git -C "$REPO_ROOT" add .claude/settings.json 2>/dev/null || true
[ -f "$REPO_ROOT/.quetrex/verify.json" ]  && git -C "$REPO_ROOT" add .quetrex/verify.json 2>/dev/null || true
[ -f "$REPO_ROOT/.worktreeinclude" ]      && git -C "$REPO_ROOT" add .worktreeinclude 2>/dev/null || true
# The committed engine pin and the kanban MCP broker — both written by
# quetrex-arm in step 4h — are read by cloud routines from the repo, so both
# must be committed.
[ -f "$REPO_ROOT/.mcp.json" ]             && git -C "$REPO_ROOT" add .mcp.json 2>/dev/null || true

if git -C "$REPO_ROOT" diff --cached --quiet; then
  echo "Nothing to commit — repo already adopted."
else
  git -C "$REPO_ROOT" commit -m "chore: adopt repo into Quetrex project $CODE

Add .quetrex/project.json binding, clean stale tracker references, ensure project
Verification rules, and pin the quetrex-factory engine in enabledPlugins so its
build gates run locally and in cloud routines." >/dev/null

  # Open a PR only if there is a remote AND gh is available.
  if git -C "$REPO_ROOT" remote get-url origin >/dev/null 2>&1 && command -v gh >/dev/null 2>&1; then
    git -C "$REPO_ROOT" push -u origin "$BRANCH" >/dev/null 2>&1
    PR_URL="$(gh pr create --repo "$(git -C "$REPO_ROOT" remote get-url origin)" \
      --head "$BRANCH" \
      --title "chore: adopt repo into Quetrex project $CODE" \
      --body "Links this repo to Quetrex project \`$CODE\` (adds \`.quetrex/project.json\`), cleans stale tracker references from CLAUDE.md, and pins the quetrex-factory engine in enabledPlugins so its build gates run locally and in cloud routines. Non-destructive: no existing config or history was overwritten." 2>/dev/null)"
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
- **Branch prefix** — the value recorded in the binding (`feature/` by default), and, if it
  is not `claude/`, the one-line note that cloud routines need the repo's branch restriction
  loosened to push it.
- **Permissions** — which pipeline entries were added to the customer's own
  `.claude/settings.json` `permissions.allow` (or *"already covered"*), stated as additions
  they can see and revoke. Nothing was removed or narrowed.
- **Worktree environment** — the `.worktreeinclude` entries written (or *"already
  current"*), and the note that they are git-ignored paths copied into worktrees, never
  committed.
- **GitHub app** — installed already / offered and accepted / offered and declined.
- **Engine pin** — the `enabledPlugins` written (`quetrex@quetrex: true` and the concrete
  `quetrex-factory@quetrex: <version>` pin), or *"already current"*; if the marketplace was
  unreachable, the note to run `/quetrex:update` once online to write the concrete factory pin.
- **MCP broker** — whether the `quetrex-kanban` server was registered in `.mcp.json` or was
  already present (endpoint only — no secret written).
- **Legacy cleanup** — *"already offered on this machine"*, *"nothing to clean"*, or the
  per-item outcome (quarantined / stripped / kept / flagged), noting that everything is
  reversible from the timestamped backup dir and that `secrets.env` was only flagged.
- **Secrets** — which local env creds were imported into the vault (by CANON name +
  masked last-4, never values), and the `dash.quetrex.com/keys` reminder for any missing
  ones.
- **Delivery** — the PR URL, or the local-commit note if no remote.

---

## Error-handling rules

- Reuse the helper's messaging verbatim: `401 → Run /quetrex:login`,
  `403/404 → No access — contact your administrator`. The **only** override is the
  create-project 403, where you print the admin-specific hint instead.
- Never print the bearer token. Build all JSON with `node` / `JSON.stringify`.
- Idempotent: re-running on a linked repo never re-creates the binding and never
  prompts for a name — it re-verifies access and can re-clean / re-PR.
- Non-destructive: the only files this command creates are `.quetrex/project.json`,
  `.worktreeinclude` (step 4f), and `.mcp.json` (step 4h, via `quetrex-arm`, merged — never
  clobbering an existing MCP server entry); `CLAUDE.md` edits only excise stale tracker
  blocks, never wholesale rewrites; `.claude/settings.json` is merged, never clobbered —
  step 4e only ever **adds** to `permissions.allow` and step 4h (`quetrex-arm`) only ever
  adds/updates the `enabledPlugins` pin and `extraKnownMarketplaces.quetrex`, never removing
  or narrowing an entry, and never touching `permissions.deny`/`ask`. The only removals are
  user-confirmed stale old-Quetrex
  project commands/skills (step 4c) — never auto-deleted, never anything in the global
  `~/.claude`. The build gates (`verify-gate.sh`/`merge-gate.sh`/`secret-scan.sh` and the
  fat pipeline agents) are delivered by the `quetrex-factory` plugin pin (4h), never
  copied into the repo — this command never writes a hook or agent file.
- Never hardcode `feature/`: `branchPrefix` is chosen in step 3d, recorded in the binding,
  and used for this command's own adoption branch and by every downstream command.
- `/install-github-app` is **offered**, never run unprompted, and adoption never blocks on
  it.
