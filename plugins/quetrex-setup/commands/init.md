---
description: Link this repo to a Quetrex project (writes ./.quetrex/project.json with its branchPrefix) or create one, then non-destructively adopt the repo (clean stale tracker refs, ensure project Verification rules, enable the quetrex-factory engine in enabledPlugins (never version-pinned) so its build gates run locally and in cloud routines, union in the permissions the pipeline needs, generate .worktreeinclude, offer to import local env creds into the vault, open a PR). Usage: /quetrex-setup:init [project name]
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
so worktrees are actually runnable (4f). It
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
QX_KANBAN_URL="$(quetrex-api kanban-url)" || exit 1   # prints "Run /quetrex-setup:login" on miss/expiry
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

**Then decide, before adoption, whether the verify chain is already in place — and if it
is, do NOT ask the "Confirm the verification chain" question again.** An already-linked
repo commonly carries a committed `.quetrex/verify.json` AND a `## Verification` block in
`.claude/CLAUDE.md` that already says exactly the same thing; measured on a re-run of init
over such a repo, the operator was still asked to confirm a chain he had already confirmed
and committed. Compare the two line-for-line in `node` (never by shell word-splitting —
this block runs in the operator's zsh as well as bash):

```bash
# ── quetrex:exec-block qx_verify_block_in_place ────────────────────────────────
# VERIF_CHAIN_IN_PLACE=1 ⇔ .quetrex/verify.json exists with a non-empty .verify[]
# AND the fenced block under `## Verification` in .claude/CLAUDE.md equals it,
# line for line (trimmed, blank lines dropped). Anything else — no verify.json,
# no block, a drifted block — leaves it 0 and step 4b runs exactly as before.
VERIF_CHAIN_IN_PLACE="$(node -e '
  const fs=require("fs");
  const [vfile, rules]=process.argv.slice(1);
  let chain=null;
  try { const o=JSON.parse(fs.readFileSync(vfile,"utf8")); if (o && Array.isArray(o.verify) && o.verify.length) chain=o.verify.map(String); } catch {}
  if (!chain) { process.stdout.write("0"); process.exit(0); }
  let md=""; try { md=fs.readFileSync(rules,"utf8"); } catch { process.stdout.write("0"); process.exit(0); }
  const lines=md.split(/\r?\n/);
  const FENCE=String.fromCharCode(96,96,96);
  let i=lines.findIndex(l=>/^##\s+Verification\s*$/.test(l));
  if (i<0) { process.stdout.write("0"); process.exit(0); }
  let block=null;
  for (let j=i+1;j<lines.length;j++){
    if (/^##\s/.test(lines[j])) break;
    if (lines[j].trim().startsWith(FENCE)) {
      block=[];
      for (let k=j+1;k<lines.length;k++){ if (lines[k].trim().startsWith(FENCE)) break; block.push(lines[k]); }
      break;
    }
  }
  if (!block) { process.stdout.write("0"); process.exit(0); }
  const got=block.map(s=>s.trim()).filter(Boolean);
  const want=chain.map(s=>s.trim()).filter(Boolean);
  const same = got.length===want.length && got.every((s,n)=>s===want[n]);
  process.stdout.write(same ? "1" : "0");
' "$REPO_ROOT/.quetrex/verify.json" "$REPO_ROOT/.claude/CLAUDE.md" 2>/dev/null || echo 0)"
if [ "$VERIF_CHAIN_IN_PLACE" = "1" ]; then
  echo "verify chain already in place — .claude/CLAUDE.md ## Verification matches .quetrex/verify.json; not asking to confirm it again."
fi
# ── end quetrex:exec-block qx_verify_block_in_place ───────────────────────────
```

When `VERIF_CHAIN_IN_PLACE=1`, step 4b is already satisfied: print that one line and never
present the *"Detected these verification commands — correct?"* question. Every other
question in this command is unchanged — in particular the requiredEnv pairing question in
step 5c is doctrine (F2) and is never skipped on this basis.

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
  echo "Creating a project requires admin — ask a super_admin to create it, or get added to an existing project, then re-run /quetrex-setup:init." >&2
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

**d. Set `branchPrefix` — `claude/`, and do NOT ask the user.**

Every branch the pipeline creates is built from this value.

```bash
BRANCH_PREFIX="claude/"   # the only prefix that works everywhere; not a question
```

**Do not prompt for this.** It was a question once, and it was the wrong one: choosing
correctly required knowing whether you personally could loosen a branch-push restriction on
this GitHub repo, which is a repo-admin detail a new team member has no way to evaluate. The
two options were never symmetric anyway:

| Prefix | Local builds | Anthropic cloud routines |
| --- | --- | --- |
| `claude/` | works | **always accepted** |
| anything else | works | accepted only if it passes three checks (below) |

This is quoted from the routines documentation, not inferred:

> "Claude pushes its work to branches prefixed with `claude/`, which are always accepted.
> When your prompt directs Claude to push to another branch, Claude Code checks the push
> first and rejects it if any of the following is true: the branch is protected on GitHub;
> someone else has an open pull request from that branch; the branch carries commits
> authored by someone other than you."

So another prefix is not forbidden outright — but the third condition alone rules out any
**shared** branch, which is exactly what a team's `feature/*` branches are. A cloud build
that cannot push has nowhere to deliver its work: no push, no PR, no result. `claude/`
costs nothing and removes that whole class of silent failure, so it is the default rather
than a question.

Report it as a statement, not a decision — one line, phrased for someone who has never seen
this before:

> Branches: `claude/<task>` — works for local and cloud builds. Change `branchPrefix` in
> `.quetrex/project.json` if your team prefers another convention.

Only honour a different prefix if the user explicitly asks for one, and accept it only if it
ends in `/`. On an **already-linked** repo (step 2a), if `branchPrefix` is absent from the
binding, backfill the same default and say so:

```bash
node -e '
  const fs=require("fs"); const f=process.argv[1];
  const o=JSON.parse(fs.readFileSync(f,"utf8"));
  if(!o.branchPrefix){ o.branchPrefix="claude/"; fs.writeFileSync(f, JSON.stringify(o,null,2)+"\n"); console.log("backfilled branchPrefix=claude/ (existing branches are unaffected)"); }
' "$BIND"
```

**e. Set `cloudEnvironmentId` — derive it, do not make the user paste it.**

`/quetrex:task-build` fires the build as a cloud routine, and a routine needs an
`environment_id`. Until now nothing set it: the first build stopped and printed a `node -e`
one-liner asking the operator to open claude.ai, find an `env_…` id in a URL, and paste it
back. **Every new partner stalled there, on their first build, having done nothing wrong.**
Arming a feature belongs in `init`, not in a failure message from the command that needed it.

It does not have to be a question. Every routine the user already has carries the environment
it runs in *and* the repositories it runs against:

```
job_config.ccr.environment_id
job_config.ccr.session_context.sources[].git_repository.url
```

So list the routines and read the answer off them.

**Call `RemoteTrigger` with `action: "list"`** — the OAuth token is added in-process, so this
is not something a shell script can do with `curl`; it is a tool call you make. Write the raw
JSON to a temp file, then hand it to `quetrex-cloud-env` — shipped on the plugin's `bin/`
(on PATH here, exactly like `quetrex-arm`; call it by name), the ONE copy of the ranking
logic, shared with `/quetrex-setup:doctor` Check 11 and executed by
`test/init-cloud-env.test.sh` against a fixture captured from a REAL `GET /v1/code/triggers`
response. If the call fails, skip to the fallback at the end of this step — never block
`init` on it.

```bash
# TRIGGERS_JSON = the temp file holding the raw RemoteTrigger list response.
# Emits one TSV row per DISTINCT environment, best candidate first:
#     <env_id>\t<repo|other>\t<last-used ISO8601>\t<example routine name>
# "repo" = that environment has actually run against THIS repository (matched
# on the origin remote). Empty output = no routine anywhere names an
# environment, the genuinely-new-user case. See bin/quetrex-cloud-env for why
# it RANKS rather than matches (an environment is not one-per-repo).
CANDIDATES="$(quetrex-cloud-env candidates "$REPO_ROOT" < "$TRIGGERS_JSON" 2>/dev/null || true)"
```

Then decide, in this order:

- **Exactly one candidate, or exactly one marked `repo`** — write it and say so in one line.
  Do not ask.
- **More than one** — ask with `AskUserQuestion`. Label each option with the environment id
  and whether it has run against this repo; put the `repo` ones first. This is a real fork:
  the two environments may have different toolchains installed.
- **None, or the `RemoteTrigger` call failed** — this user has never created a cloud
  environment, so there is nothing to derive. Fall back to the existing instruction, and say
  plainly why you are asking:

  > No cloud environment found on your account. Open <https://claude.ai/code>, create the
  > environment this repo should build in, then re-run `/quetrex-setup:init` — or paste its
  > `env_…` id here and I will record it.

Write the chosen value into the binding, next to `branchPrefix` — the same writer
`/quetrex-setup:doctor` names in its Fix line, so an operator can run it by hand:

```bash
quetrex-cloud-env set "$REPO_ROOT" "$CHOSEN_ENV_ID"
```

On an **already-linked** repo (step 2a) with no `cloudEnvironmentId`, run this same step and
backfill — that is what repairs every repo bound before this existed. Never overwrite a value
the binding already has; if one is present, report it and move on.

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

**1. Idempotent check.** If step 2a set `VERIF_CHAIN_IN_PLACE=1`, this step is already
satisfied — it printed its one line there; do not ask anything here. Otherwise, if
`$PROJ_RULES` already contains a `## Verification` heading, leave it untouched and report
*"Verification rules already present."* Detect with `node` (do not `cat`):

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

**5. Seed and merge `.quetrex/verify.json`.** The confirmed list is also the seed for
`.quetrex/verify.json` — the machine-readable chain `verify-gate.sh` reads (it takes
precedence over the `## Verification` fence above, which stays the human-readable
fallback). This step also DECLARES `requiredEnv`: the per-command declaration that lets
`verify-gate.sh` skip a command pre-flight when a genuinely-required variable cannot
exist in this checkout (see `plugins/quetrex-factory/scripts/verify-gate.sh` — "DECLARATIVE ENV SKIP"),
instead of letting the chain go red on a variable no checkout could ever have. That
mechanism has always been fully implemented in the hook; nothing writes the declaration
it reads except an explicit human confirmation, right here.

**STOP INFERRING.** A prior version of this step ran an unattended tool that guessed
which command needed which variable from the command string itself — that guess was
provably wrong in both directions (see `.quetrex/plan/VERIFY-GATE-QUIET.json`). There is
no code path left, anywhere, that can write a `requiredEnv` key except
`quetrex-env-derive declare`, called only with the exact `--cmd`/`--env` pairs a human
confirms below. No name is ever written from a guess.

### 5a. Seed `.verify[]`

Only when `.quetrex/verify.json` does not exist yet — an already-existing chain is
authoritative and is never touched here. Guard against BOTH an unset and an empty
`CONFIRMED_STEPS` explicitly: a bare `"${CONFIRMED_STEPS[@]:-}"` expansion yields ONE
EMPTY-STRING argument, not zero words, and seeding `.verify` with `[""]` permanently
deadlocks GATE 3 of `merge-gate.sh` — no checkout can ever produce a green ledger line
for an empty command. Never pass an unguarded `"${CONFIRMED_STEPS[@]:-}"` to the seeder;
`quetrex-env-derive seed-chain` independently refuses an empty or all-blank command list
too, as a second, structural backstop:

```bash
# CONFIRMED_STEPS = the user-confirmed commands from step 4b.4, one per line, in order.
if [ -f "$REPO_ROOT/.quetrex/verify.json" ]; then
  : # an existing chain is authoritative — never touched here
elif [ "${CONFIRMED_STEPS+set}" = "set" ] && [ "${#CONFIRMED_STEPS[@]}" -gt 0 ]; then
  quetrex-env-derive seed-chain "$REPO_ROOT" "${CONFIRMED_STEPS[@]}"
fi
```

### 5b. Propose candidates from this repo's own committed evidence

Run the shared derivation tool — `quetrex-env-derive`, shipped on the plugin's `bin/`
(on PATH here, exactly like `quetrex-arm` above; call it by name, never source it) —
**every time this step runs**, not only when a fresh `## Verification` block was just
written:

```bash
QUETREX_ENV_DERIVE_PROPOSAL="$(quetrex-env-derive propose "$REPO_ROOT" 2>/dev/null)"; QUETREX_ENV_DERIVE_PROPOSE_RC=$?
```

`propose` is READ-ONLY — it never writes `.quetrex/verify.json`, ever, under any
condition. Its `.candidates[]` are names this repo's own COMMITTED `.env.example` (or
`.env.sample`) declares AND a tracked source file reads with no fallback — the exact same
evidence `verify-gate.sh` itself re-checks on read (SEC-4), so nothing shown to the human
below can ever be a pairing the gate would then silently refuse to honor.

**A candidate is never paired to a `.verify[]` command.** `propose`'s own `.note` field
says this in the JSON itself — there is no code path anywhere that determines which chain
command actually reaches a given candidate's read site, and a prior version of this step
asked the MODEL to invent that pairing and present it as derived. That is exactly the F2
defect the human-confirmation design exists to prevent, not a shortcut it can afford:
`declare`'s only defense is that `--cmd` names a byte-for-byte member of `.verify[]`, and
every real command trivially satisfies that — so a fabricated pairing a human rubber-stamps
is just as capable of silently un-gating a genuinely-red command as the deleted inference
engine ever was. The fix is not a better guess; it is never guessing.

### 5c. Confirm with the human, then write only the confirmed pairs

Ask ONLY about `.outstanding[]` — the candidates covered by neither a committed
`requiredEnv` entry nor `requiredEnvDeclined`. `propose` computes that list itself from the
committed `.quetrex/verify.json`, so a name the human already paired, or already answered
*"No — leave undeclared"* to, is never asked about again: on a re-run over an already-adopted
repo whose whole candidate set was answered last time, `.outstanding` is empty and the
question is not asked at all. (`.candidates[]` stays the full committed evidence set —
`declare` validates against it — but it is not the question list.)

When `${QUETREX_ENV_DERIVE_PROPOSAL}` has zero `.outstanding`, there is nothing to
confirm — skip straight to step 6. Otherwise, render two things BEFORE asking — never ask
cold, and never render a column with no data behind it:

**1. The outstanding candidates**, name and read_at only — both are real, from
`.outstanding[]`:

| name | read_at |
|------|---------|
| `.outstanding[].name` | `.outstanding[].read_at` |

**2. The real verify chain**, verbatim from `.chain` (never re-typed, never summarized):

```
1) .chain[0]
2) .chain[1]
...
```

If `.chain` is empty, there is nothing any candidate could ever gate — skip straight to
step 6 for the same reason zero candidates does.

Then ask with `AskUserQuestion`, **one question per OUTSTANDING candidate**, options built from the
real chain list above: first option always **"No — leave undeclared"**, followed by one
option per chain command, **"Yes — gate `<chain[i]>`"**, `AskUserQuestion`'s multi-select
so a human can pick more than one command for the same name when that is genuinely true.
Cap the interaction at no more than 1 AskUserQuestion round trip per 4 candidates (batch
beyond that). Example question: *"`<NAME>` is a committed candidate, read at `<read_at>` —
which of these commands, if any, should `verify-gate` skip when `<NAME>` is unset in this
checkout? (Nothing here was derived — you are the only source of this pairing.)"*

**`AskUserQuestion` IS the human confirmation. Never test for a terminal here.** The
requirement that a human authorises every pairing is absolute and unchanged — but the
authorising surface is the `AskUserQuestion` tool call above, which is a tool call, not a
terminal. `/quetrex-setup:init` only ever executes through Claude Code's Bash tool, where
neither stdin nor stdout is ever a terminal, so a terminal test in this step is not a
conservative fallback: it is an unconditional off switch. One shipped, and the
consequence was measured — `quetrex-env-derive declare`, the ONLY writer of
`requiredEnv`, became structurally unreachable, so no repo `/quetrex-setup:init` ever armed
carried a `requiredEnv` map, `verify-gate`'s declarative env skip never fired anywhere,
and the first cloud build of any repo whose chain needs a credential died on an unset
variable no sandbox could hold. The one existing map in the wild had to be typed by hand.

**The only suppressor — propose nothing, write nothing.** When the literal env var
`QUETREX_INIT_NONINTERACTIVE` is set, skip 5c's question entirely: propose nothing, write
nothing. Nothing else suppresses it. If `AskUserQuestion` genuinely cannot be used in this
session, leave `CONFIRM_CMD_ENV`/`CONFIRM_DECLINE` empty — the block below then writes
nothing — and report `requiredEnv` as **outstanding** in step 7 rather than silently
skipped. The guarantee is structural, not merely prose: `declare` called with zero
`--cmd`/`--env`/`--decline` pairs writes nothing at all (see `bin/quetrex-env-derive`'s
own "ONLY WRITER" contract) — so a model that skips the confirmation step can never
manufacture a declaration either way.

```bash
# CONFIRM_CMD_ENV = ("cmd" "NAME") tuples the human answered "Yes" to in 5c.
# CONFIRM_DECLINE  = NAMEs the human answered "No" to in 5c.
# Both stay empty when 5c never ran (nothing to confirm, AskUserQuestion was unusable,
# or the explicit opt-out below fired) — an empty DECLARE_ARGS means the declare call
# below never fires.
#
# NEVER add a terminal test to this condition. Terminal tests are false in every
# Claude Code Bash tool invocation, which is the ONLY way this command runs, so one
# here disables the sanctioned requiredEnv writer outright rather than guarding it.
# The human confirmation happens in AskUserQuestion above; this block only carries
# the answers a human already gave.
DECLARE_ARGS=()
if [ -n "${QUETREX_INIT_NONINTERACTIVE:-}" ]; then
  echo "QUETREX_INIT_NONINTERACTIVE set — non-interactive by explicit opt-out; propose nothing, write nothing for requiredEnv"
else
  for pair in "${CONFIRM_CMD_ENV[@]:-}"; do
    [ -n "$pair" ] || continue
    DECLARE_ARGS+=(--cmd "${pair%%$'\t'*}" --env "${pair##*$'\t'}")
  done
  for name in "${CONFIRM_DECLINE[@]:-}"; do
    [ -n "$name" ] || continue
    DECLARE_ARGS+=(--decline "$name")
  done
  if [ "${#DECLARE_ARGS[@]}" -gt 0 ]; then
    quetrex-env-derive declare "$REPO_ROOT" "${DECLARE_ARGS[@]}"
  fi
fi
```

Same `$REPO_ROOT` pin and "never the global file" rule as step 4. Record whether 4b
created or appended the `## Verification` block, and whether this step wrote
`.quetrex/verify.json` — so step 6 stages the file and step 7 reports it. **The
declaration only has effect once committed:** `verify-gate.sh` reads `requiredEnv` from
`git show HEAD:.quetrex/verify.json` (SEC-2), never the working tree, specifically so
every association a human is ever skipped by first appeared in a reviewed diff. Step 6
already stages `.quetrex/verify.json` when present and opens the PR — that path is what
carries this write into a reviewed commit; nothing further is needed here.

**Already-adopted repos.** Because 5c is union-only and never narrows an existing
`.verify[]` or a pre-existing `requiredEnv`/`requiredEnvDeclined` entry, simply
**re-running `/quetrex-setup:init`** is the complete remediation for a repo whose
`.quetrex/verify.json` predates this field — it re-proposes and, once the human
confirms, merges into whatever is already committed, without touching a command, a
name, or anything a human already wrote by hand. `/quetrex-setup:doctor` Check 5 detects
exactly this state (a committed candidate covered by neither `requiredEnv` nor
`requiredEnvDeclined`) and points back here.

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
    "Bash(git commit:*)","Bash(jq:*)","Bash(mkdir:*)","Edit(/**)"
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

**The file-edit grant is `Edit(/**)`, never a bare `Write`/`Edit`.** Two reasons, both
load-bearing:

- **Scope.** Under `defaultMode: "dontAsk"` the allow-list is the *complete* grant set, not
  a prompt-suppression list. A bare `Edit` matches every path on the machine — `~/.ssh/*`,
  `~/.zshrc`, `~/.claude/settings.json` — with no prompt to catch it. `Edit(/**)` anchors at
  the customer's project root (a `/path` pattern resolves against the settings source), so a
  write outside the repo is auto-denied instead of silently permitted.
- **`Edit`, not `Write`.** Claude Code checks file permissions against `Edit(path)` and
  `Read(path)` rules ONLY. A `Write(path)` rule is accepted, never consulted, and warns at
  startup. `Edit(path)` already covers Write, NotebookEdit and MultiEdit — writing
  `Write(...)` here would look correct and enforce nothing.

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

## 4g. (removed) — Quetrex does not use the Claude GitHub App

**Deliberately absent. Do not reintroduce a check, a prompt, or a mention.**

Init used to detect the app and ask whether to install it. That is removed, on the operator's
call, for a reason worth recording so nobody adds it back as a convenience:

- **The model cannot run `/install-github-app`.** It is a native interactive command driving a
  GitHub OAuth flow in the operator's own browser. Asking *"Run it?"* and taking a **yes**
  produced nothing while reading as handled. It happened in the field; the operator's words
  were *"my partners would have thought it was taken care of and issues would have happened."*
- **The install then asks a second question with a genuinely harmful answer.** It offers to set
  up GitHub Actions workflows — which creates a **third execution location**, a GitHub runner.
  A runner has no Claude login, so it demands its own `ANTHROPIC_API_KEY`. That is the entire
  origin of this project's "we need an API key" problem, and the workflow it produces was
  already deleted once for exactly that. A prompt where the wrong answer breaks the
  architecture is a prompt that should not be asked.
- **Quetrex gains nothing from it.** The reviewer, QA and security-reviewer all run inside the
  cloud routine and publish to `<prefix><TASK>-gates`; `merge-gate.sh` reads those artifacts.
  GitHub-side PR review is additive, not load-bearing, and the app without workflows delivers
  none of it anyway.

If an operator wants GitHub-side review on a repo real people push to, that is their decision
to make outside Quetrex. Init does not raise it, `/quetrex-setup:doctor` does not check for it, and
neither reports it as outstanding.

---


## 4h. Detect a stack pack, then arm the repo for cloud execution — `quetrex-arm`

**First, detect a stack pack from this repo's own committed evidence.** A stack pack
(`quetrex-nextjs`, `quetrex-python`, `quetrex-rust`, `quetrex-swift`, …) ships stack-specific
skills as a separate marketplace plugin — never guessed at, never installed speculatively,
only enabled when this repo's own root gives real evidence of that stack. Checked in this
order (first match wins; a Next.js `package.json` is checked ahead of a bare `package.json`
so a Next.js repo that also happens to carry an unrelated `requirements.txt` still gets the
Next.js pack); no match writes no pack key and is not an error:

```bash
STACK_PACK=""
if [ -f "$REPO_ROOT/package.json" ] && node -e '
  let o; try { o = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); } catch { process.exit(1); }
  const deps = Object.assign({}, o.dependencies || {}, o.devDependencies || {});
  process.exit(deps.next ? 0 : 1);
' "$REPO_ROOT/package.json" 2>/dev/null; then
  STACK_PACK="quetrex-nextjs"
elif [ -f "$REPO_ROOT/pyproject.toml" ] || [ -f "$REPO_ROOT/requirements.txt" ]; then
  STACK_PACK="quetrex-python"
elif [ -f "$REPO_ROOT/Cargo.toml" ]; then
  STACK_PACK="quetrex-rust"
elif [ -f "$REPO_ROOT/Package.swift" ]; then
  STACK_PACK="quetrex-swift"
fi
[ -n "$STACK_PACK" ] && echo "stack pack detected: $STACK_PACK" || echo "stack pack: none detected"
```

Cloud routines and every teammate read which engine to run from what is **committed** in
this repo — `.claude/settings.json` `enabledPlugins` + `extraKnownMarketplaces` — never from
any one machine's local plugin cache. These writes used to be inline `node` prose right here
in this command; that prose did not reliably execute (a run could finish with empty
`enabledPlugins` and no `extraKnownMarketplaces`), so arming is now a **deterministic
executable**, `quetrex-arm`, shipped on the plugin's `bin/` (which IS on PATH in
slash-command bash, unlike the plugin-root path variable, which is unset in this context —
call it by name, never source it):

```bash
QUETREX_ARM_OUTPUT="$(quetrex-arm "$REPO_ROOT" "$QX_KANBAN_URL" ${STACK_PACK:+"$STACK_PACK"})"; QUETREX_ARM_RC=$?
printf '%s\n' "$QUETREX_ARM_OUTPUT"
if [ "$QUETREX_ARM_RC" -ne 0 ]; then
  echo "quetrex-arm failed — .claude/settings.json may be only partially armed. Re-run /quetrex-setup:init once resolved." >&2
fi
```

`quetrex-arm` idempotently and non-destructively writes, into `$REPO_ROOT`:

- `.claude/settings.json` `enabledPlugins`: `"quetrex@quetrex": true`,
  `"quetrex-factory@quetrex": true`, `"quetrex-setup@quetrex": true`, and — when step 4h's
  detection above found one — the detected stack pack, e.g. `"quetrex-nextjs@quetrex": true`
  — **booleans, never version pins.** A pinned entry (array or string) makes the plugin
  count as *disabled* for dependency resolution, and the whole `/quetrex:*` command layer
  then fails to load: measured across four checkouts, pin absent → enabled, `true` →
  enabled, `["1.2.1"]` (the exact installed version) → **failed to load**, `["1.1.0"]` →
  **failed to load**. Pinning also broke updates — a stale pin, or one naming a version a
  machine lacks, strands the team while every repo looks configured. The engine tracks the
  marketplace via `autoUpdate` and the running version is surfaced in the status bar
  (`quetrex-version`), not frozen into config. Any legacy pin found on any
  `quetrex[-<name>]@quetrex` key — not just the two originally-pinned ones — is rewritten to
  `true`. Arming needs no network for this.
  `quetrex-setup` is enabled here at PROJECT scope too, not only machine-wide: a cloud
  routine and a teammate's fresh clone are provisioned from THIS repo's own
  `.claude/settings.json`, and both need `quetrex-api` / `quetrex-env-derive` on PATH
  (`.claude/lib/cloud-build-routine.md` names them explicitly) — see `bin/quetrex-arm`'s own
  `bin_split` decision notes for the full reasoning.
- `.claude/settings.json` `extraKnownMarketplaces.quetrex.source`:
  `{"source":"github","repo":"Glori-Holdings/quetrex-plugins"}` — without this the
  `quetrex-factory` pin above cannot resolve.
- `.claude/statusline-command.sh` + `.claude/settings.json` `statusLine`:
  `{"type":"command","command":"bash \"${CLAUDE_PROJECT_DIR:-.}/.claude/statusline-command.sh\""}`.
  **A Claude Code plugin cannot register a `statusLine`**, so the repo has to carry it or
  the running engine version is displayed nowhere: nothing is version-pinned, so config
  names no version, and both `/quetrex-setup:update` and `/quetrex-setup:doctor` tell the operator the
  version "lives in the status bar." Before this, that bar was empty in every armed repo,
  and a teammate silently stranded on an old engine had no on-screen signal at all. The
  renderer reads the version at runtime via `quetrex-version`, so the committed copy never
  goes stale. The `${CLAUDE_PROJECT_DIR:-.}` default is load-bearing — the bare form
  resolves to `/.claude/statusline-command.sh` when the variable is unset and bash exits
  127, which the operator reads as a failed build. Union-only as ever: a `statusLine` the
  operator set is left byte-for-byte alone, and an existing
  `.claude/statusline-command.sh` in the repo is never overwritten. The single exception
  is a repair, not a clobber — a registration that already points at *our* script but
  omits the default is rewritten to the guarded form, so **re-running `/quetrex-setup:init` is
  the remediation path**. If the shipped script cannot be located, arming registers
  **nothing** rather than a status bar pointing at a file that does not exist.
It also **removes** one thing, and this is a repair, not an omission:

- `.mcp.json` `mcpServers.quetrex-kanban` — deleted when its url is `<kanbanUrl>/api/mcp`.
  Earlier versions *registered* that http broker. **The endpoint was never built**: the
  kanban has no `/api/mcp` route and the URL answers with the dash's Next.js 404 HTML page,
  so Claude Code opened every armed repo with an MCP server that could never handshake —
  surfacing to the operator as "the plugins cannot connect to the dash." Arming now purges
  the registration, which makes **re-running `/quetrex-setup:init` the remediation path** for a
  repo armed by an older engine. Nothing is lost; the broker never worked. Only that exact
  url is touched — another `mcpServers` entry, another top-level key, or a `quetrex-kanban`
  entry pointing at something real all survive untouched, and `.mcp.json` is deleted only if
  removing our entry leaves it empty. When the broker endpoint is genuinely built, restore
  the write **only** after the live URL answers an MCP `initialize`.

Every write merges — it never clobbers any other `enabledPlugins` entry, any other
`extraKnownMarketplaces` entry, any other `mcpServers` entry, or any other settings key.
Record whatever `quetrex-arm` printed (each concern reports "wrote ...", "already current",
or what it removed/left alone in `.mcp.json`) so step 6 stages `.claude/settings.json` +
`.claude/statusline-command.sh` + `.mcp.json` and step 7 reports it verbatim.

---

## 4i. Register the board webhook so cards move during a cloud build

A cloud routine has **no credential for the kanban** — the bearer token lives in the
operator's `~/.quetrex/auth.json` and never leaves that machine — so the cloud half is told
not to call the board. Every other transition has a local writer (`in_progress` at dispatch,
`merged` by `/quetrex:merge`), but `pr_ready` had none: a card froze the moment work was
dispatched and only moved again when the operator came back. This registers the GitHub
webhook that closes that window.

**A webhook is not GitHub Actions.** No runner, no billed minutes, nothing executing on a
third machine — GitHub POSTs to the board and the board, which already owns status
transitions, does the write. Never add a workflow file here.

Idempotent: an existing hook with the same URL is left alone, never duplicated.

**The shared secret is generated by init, never typed by the operator.** Exactly two
parties need it — GitHub (signs each delivery) and the board (verifies it against THIS
project's vault entry `GITHUB_WEBHOOK_SECRET`). A cloud build agent never needs it. When
the vault has no entry yet, init mints one and stores it through the same
`quetrex-api secret-put` helper step 5b uses; the value is handed to that helper over a
process substitution (never a file on disk), then straight to GitHub, never printed,
`unset` immediately after. If the store fails the hook is NOT registered — a hook GitHub
signs with a value the board cannot see is worse than none. This block runs in the
operator's zsh as well as bash: no unquoted `$VAR` splitting, no `$var:` modifiers.

```bash
# ── quetrex:exec-block qx_register_webhook ─────────────────────────────────────
# Owner/repo from the origin remote — skip silently when there is no GitHub origin.
# `remote.origin.url` can carry an embedded NEWLINE (git config accepts a \n
# escape) and the `grep -Eq` below matches per LINE, so an anchored slug pattern
# succeeds when ANY one line matches while the others flow into what this block
# prints. Refuse a multi-line origin outright — truncating to line 1 would just
# hand the attacker the owner/repo halves.
QX_ORIGIN="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null)"
if [ "$(printf '%s' "$QX_ORIGIN" | wc -l | tr -d ' ')" != 0 ]; then
  echo "webhook: origin remote is not a single-line URL — refusing to read a repo slug from it" >&2
  QX_ORIGIN=""
fi
QX_SLUG="$(printf '%s' "$QX_ORIGIN" | sed -E 's#^(git@github\.com:|(https?|ssh|git)://(git@)?github\.com/)##; s#/+$##; s#\.git$##; s#/+$##')"
QX_HOOK_URL="${QX_KANBAN_URL%/}/api/webhooks/github"

if ! printf '%s' "$QX_SLUG" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
  echo "webhook: no GitHub origin remote — skipped (cards will not auto-move to pr_ready here)"
elif ! command -v gh >/dev/null 2>&1; then
  echo "webhook: gh CLI unavailable — skipped. Re-run /quetrex-setup:init once gh is installed."
else
  QX_HOOK_ID="$(gh api "repos/$QX_SLUG/hooks" --jq '.[] | select(.config.url=="'"$QX_HOOK_URL"'") | .id' 2>/dev/null | head -1)"
  if [ -n "$QX_HOOK_ID" ]; then
    echo "webhook: already registered on $QX_SLUG (id $QX_HOOK_ID) — left alone"
  else
    # POST .../secrets/export is the ONLY endpoint that returns plaintext — the
    # collection GET deliberately returns masked entries (name + last4) and would
    # silently yield an empty value here. POST, not GET, so a decrypted value
    # never lands in a URL, referrer or proxy log.
    QX_WH_SECRET="$(quetrex-api POST "/api/projects/$QX_PROJECT_CODE/secrets/export" \
      '{"names":["GITHUB_WEBHOOK_SECRET"]}' 2>/dev/null | jq -r '.GITHUB_WEBHOOK_SECRET // empty')"
    QX_WH_STORED=1
    if [ -z "$QX_WH_SECRET" ]; then
      # No entry yet: mint one (32 random bytes, hex) and store it in the vault
      # FIRST. The helper reads KEY=value from a file path; <(...) is a /dev/fd
      # pipe, so the value never touches disk. Registration only follows a
      # successful store.
      QX_WH_SECRET="$(node -e "process.stdout.write(require('crypto').randomBytes(32).toString('hex'))")"
      if [ -n "$QX_WH_SECRET" ] \
         && quetrex-api secret-put <(printf 'GITHUB_WEBHOOK_SECRET=%s\n' "$QX_WH_SECRET") GITHUB_WEBHOOK_SECRET GITHUB_WEBHOOK_SECRET >/dev/null 2>&1; then
        echo "webhook: generated GITHUB_WEBHOOK_SECRET and stored it in project $QX_PROJECT_CODE's vault"
      else
        QX_WH_STORED=0
        echo "webhook: could not store GITHUB_WEBHOOK_SECRET in project $QX_PROJECT_CODE's vault — NOT registered (a hook the board cannot verify moves nothing). Re-run /quetrex-setup:init." >&2
      fi
    fi
    if [ "$QX_WH_STORED" = 1 ]; then
      QX_HOOK_OUT="$(jq -cn --arg u "$QX_HOOK_URL" --arg s "$QX_WH_SECRET" \
        '{name:"web",active:true,events:["pull_request"],config:{url:$u,content_type:"json",secret:$s,insecure_ssl:"0"}}' \
        | gh api -X POST "repos/$QX_SLUG/hooks" --input - 2>&1)"
      QX_NEW_ID="$(printf '%s' "$QX_HOOK_OUT" | jq -r '.id // empty' 2>/dev/null)"
      if [ -n "$QX_NEW_ID" ]; then
        echo "webhook: registered on $QX_SLUG (id $QX_NEW_ID) — PRs will move cards to pr_ready"
      else
        echo "webhook: registration FAILED on $QX_SLUG — $(printf '%s' "$QX_HOOK_OUT" | jq -r '.message // .' 2>/dev/null | head -1)" >&2
        echo "         Cards will not auto-move here until this succeeds." >&2
      fi
      unset QX_HOOK_OUT
    fi
    unset QX_WH_SECRET
  fi
fi
# ── end quetrex:exec-block qx_register_webhook ─────────────────────────────────
```

**The project must also record its repo — both halves.** The webhook refuses a delivery
whose repository does not match the project's stored repo — the identifier alone is not
authorisation, since `QDM-5` means something in every project coded QDM. And the board
shows the repository as **linked** only when BOTH `githubOwner` and `githubRepo` are set
(`RepoLink` checks the pair); a project with only `githubRepo` reads "repository not
linked" on every card. So this block derives `owner` and `repo` from the origin slug and
writes the pair whenever either is missing. It never overwrites a non-empty value that
differs — that project belongs to another repo, and init says so, names BOTH stored
halves (never a dangling `Someone-Else/`), and leaves it. Two things the comparison has
to get right. A **failed** board GET is not an unset field: `jq -r '… // empty'` on empty
stdin exits 0 printing nothing, so an outage would otherwise read as "nothing recorded"
and PATCH over another repo's link — the block takes the GET's exit status and proves the
body is a JSON object before it compares anything. And a stored owner/repo is compared **the way the board compares it**. That is four
operations, not one: `repoMatchesProject` in `branch-ref.ts` trims, lowercases, strips a
trailing `.git`, then strips trailing slashes. Lowercasing alone left a stored
`dealerq.git` reading as a different repo from an origin `dealerq`, which refused the link
forever and printed a fix for a problem the board did not have. `quetrex-api repo-norm`
holds that shape in one place and **both** sides of **every** comparison go through it, in
init and in doctor alike, so the two cannot drift from each other or from the board.
Runs in the operator's zsh as well as bash: `${SLUG%%/*}` / `${SLUG##*/}` only and no
`$var:` modifiers (`${v,,}` is bash-4-only and `${v:l}` zsh-only, and neither does the
other three steps anyway).

**Two hostile inputs are refused before anything is compared or printed**, because a cloned
repo carries both. An **origin remote spanning more than one line** is refused unread: `git
config` accepts a `\n` escape in `remote.origin.url`, `grep -Eq` matches per *line*, so an
anchored slug pattern would pass on any one line and the other lines would print as advice
in this block's own voice. Truncating to line 1 is not the fix — that just hands the
attacker the owner and repo halves. And the **project code** is interpolated into the
copy-paste `quetrex-api PATCH` line, so it is offered only for a code the board could have
issued: `deriveCode` mints exactly three `A-Z` letters and `assignUniqueCode` appends a
decimal collision suffix (`quetrex-kanban src/lib/code.ts`) into a `varchar(8)` column, and
`PATCH /api/projects/:code` cannot rename it. That check lives in `resolve_project`, so
**every** consumer of the binding inherits it and no future advisory line has to remember
to guard itself; this block asks the same question through `quetrex-api code-ok`. Anything
else — a hand-written `.quetrex/project.json` — gets a plain instruction naming the board
dialog and no runnable command. Every value rendered into a printed line has its control
characters stripped whatever its source, so an `ESC` byte can never rewrite the operator's
terminal.

```bash
# ── quetrex:exec-block qx_link_project_repo ────────────────────────────────────
# Owner and repo are the two halves of the origin slug. The API validates each
# against ^[A-Za-z0-9._-]+$ — bare halves, never "owner/repo" in one field.
#
# Two inputs here are attacker-controllable in a cloned repo, and both are
# handled before anything is compared, printed or PATCHed:
#   * `remote.origin.url` can carry an embedded NEWLINE (git config accepts a \n
#     escape) and `grep -Eq` matches per LINE, so an anchored pattern succeeds on
#     ANY one line while the remaining lines flow straight into the advice below.
#     Refuse a multi-line origin outright; truncating to line 1 would just hand
#     the attacker the owner/repo halves.
#   * the project code comes from ./.quetrex/project.json, which nothing
#     validates, and it is interpolated into a `quetrex-api PATCH` one-liner the
#     operator is invited to paste. Only a code shaped the way the BOARD mints
#     one gets that treatment. `quetrex-api code-ok` is the single definition of
#     that shape and resolve_project already enforces it, so this block asks
#     rather than re-implementing the pattern next to the line it prints.
# Every value rendered into a printed line also has its control characters
# stripped, whatever its source — an ESC byte rewrites the operator's terminal.
# LC_ALL=C so `tr` deletes bytes 0x00-0x1F and 0x7F and leaves UTF-8 intact.
qx_ctl() { printf '%s' "$1" | LC_ALL=C tr -d '[:cntrl:]'; }
QX_ORIGIN="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null)"
if [ "$(printf '%s' "$QX_ORIGIN" | wc -l | tr -d ' ')" != 0 ]; then
  echo "origin remote is not a single-line URL — refusing to read a repo slug from it" >&2
  QX_ORIGIN=""
fi
QX_SLUG="$(printf '%s' "$QX_ORIGIN" | sed -E 's#^(git@github\.com:|(https?|ssh|git)://(git@)?github\.com/)##; s#/+$##; s#\.git$##; s#/+$##')"
QX_CODE_SHOWN="$(qx_ctl "$QX_PROJECT_CODE")"
if printf '%s' "$QX_SLUG" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
  QX_OWNER_NAME="${QX_SLUG%%/*}"
  QX_REPO_NAME="${QX_SLUG##*/}"
  # A board OUTAGE must never read as "nothing recorded yet". `jq -r '… // empty'`
  # on empty stdin exits 0 printing nothing, so an unread GET would fall into the
  # PATCH arm below and overwrite a link belonging to a different repo. Take the
  # GET's exit status AND prove the body is a JSON object; anything else says so
  # and touches nothing.
  QX_LINKED_JSON="$(quetrex-api GET "/api/projects/$QX_PROJECT_CODE" 2>/dev/null)"; QX_GET_RC=$?
  if [ "$QX_GET_RC" -ne 0 ] || ! printf '%s' "$QX_LINKED_JSON" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "could not read project $QX_CODE_SHOWN from the board — leaving the repo link alone" >&2
  else
    QX_LINKED_OWNER="$(printf '%s' "$QX_LINKED_JSON" | jq -r '.githubOwner // empty' 2>/dev/null)"
    QX_LINKED_REPO="$(printf '%s' "$QX_LINKED_JSON" | jq -r '.githubRepo // empty' 2>/dev/null)"
    # Compare the way the BOARD compares (quetrex-kanban src/lib/branch-ref.ts
    # repoMatchesProject): trim, lowercase, strip a trailing `.git`, then strip
    # trailing slashes. Lowercasing alone was only one of the four — a stored
    # `dealerq.git` against an origin `dealerq` read as a different repo and
    # refused the link forever, the same way `DealerQ` used to. `quetrex-api
    # repo-norm` holds that shape once, and BOTH sides of every comparison go
    # through it, so init and doctor cannot drift from each other or from the
    # board. (It is also why there is no ${v,,}/${v:l} here — neither is
    # portable across bash and zsh, and neither does the other three steps.)
    QX_OWNER_LC="$(quetrex-api repo-norm "$QX_OWNER_NAME")"
    QX_REPO_LC="$(quetrex-api repo-norm "$QX_REPO_NAME")"
    QX_LINKED_OWNER_LC="$(quetrex-api repo-norm "$QX_LINKED_OWNER")"
    QX_LINKED_REPO_LC="$(quetrex-api repo-norm "$QX_LINKED_REPO")"
    if { [ -n "$QX_LINKED_OWNER" ] && [ "$QX_LINKED_OWNER_LC" != "$QX_OWNER_LC" ]; } \
       || { [ -n "$QX_LINKED_REPO" ] && [ "$QX_LINKED_REPO_LC" != "$QX_REPO_LC" ]; }; then
      # Name BOTH halves. A half-set link rendered as "Someone-Else/" reads as a
      # repository nobody owns.
      if [ -n "$QX_LINKED_OWNER" ] && [ -n "$QX_LINKED_REPO" ]; then
        QX_LINKED_SHOWN="$(qx_ctl "$QX_LINKED_OWNER")/$(qx_ctl "$QX_LINKED_REPO")"
      elif [ -n "$QX_LINKED_OWNER" ]; then
        QX_LINKED_SHOWN="owner $(qx_ctl "$QX_LINKED_OWNER"), repo unset"
      else
        QX_LINKED_SHOWN="owner unset, repo $(qx_ctl "$QX_LINKED_REPO")"
      fi
      echo "project $QX_CODE_SHOWN is linked to a different repo ($QX_LINKED_SHOWN), not $QX_SLUG — left alone" >&2
      # The one-liner is offered ONLY for a code the board could have issued.
      if quetrex-api code-ok "$QX_PROJECT_CODE"; then
        echo "  re-running init will not change it. Set the pair on the board's repo-link dialog, or as a project admin: quetrex-api PATCH \"/api/projects/$QX_PROJECT_CODE\" '{\"githubOwner\":\"$QX_OWNER_NAME\",\"githubRepo\":\"$QX_REPO_NAME\"}'" >&2
      else
        echo "  re-running init will not change it. Set the pair on the board's repo-link dialog. (This repo's .quetrex/project.json holds a project code the board could not have issued, so there is no command to offer — fix the binding with /quetrex-setup:init first.)" >&2
      fi
      unset QX_LINKED_SHOWN
    elif [ -z "$QX_LINKED_OWNER" ] || [ -z "$QX_LINKED_REPO" ]; then
      quetrex-api PATCH "/api/projects/$QX_PROJECT_CODE" \
        "$(jq -cn --arg o "$QX_OWNER_NAME" --arg r "$QX_REPO_NAME" '{githubOwner:$o,githubRepo:$r}')" >/dev/null 2>&1 \
        && echo "project $QX_CODE_SHOWN linked to $QX_OWNER_NAME/$QX_REPO_NAME" \
        || echo "could not link project $QX_CODE_SHOWN to $QX_OWNER_NAME/$QX_REPO_NAME — the board shows it unlinked and the webhook will ignore its deliveries" >&2
    fi
    unset QX_LINKED_OWNER QX_LINKED_REPO QX_LINKED_OWNER_LC QX_LINKED_REPO_LC QX_OWNER_LC QX_REPO_LC
  fi
  unset QX_LINKED_JSON QX_GET_RC
fi
unset QX_CODE_SHOWN
unset -f qx_ctl
# ── end quetrex:exec-block qx_link_project_repo ────────────────────────────────
```

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

Stage the arming artifacts — fail loud, never silently:

```bash
# Use the project's own prefix — a cloud routine is only guaranteed to be able to push claude/*.
BRANCH="${BRANCH_PREFIX}quetrex-init-adopt"
git -C "$REPO_ROOT" checkout -b "$BRANCH" 2>/dev/null || git -C "$REPO_ROOT" checkout "$BRANCH"

# F4 (CONFIRMED, QDM-4). Every line below used to end in `2>/dev/null || true`,
# which threw away the diagnostic AND the exit code — so a `git add` that failed
# staged NOTHING while init went on to report success. That is how
# Glori-Holdings/quetrex-demo ended up with no `permissions` key in
# .claude/settings.json at all: step 4e computed the union correctly, this step
# failed to stage it, nobody was told, and the next unattended cloud build ran the
# whole pipeline and then STALLED at `gh pr create`, paging the operator on his
# phone to approve a step that is supposed to be automatic. The documented trigger
# is a .gitignore that blanket-ignores a path init must commit (`.quetrex/*` is
# the common one, and a repo that gitignores local Claude settings is the
# settings.json one): `git add` exits 1 with "The following paths are ignored by
# one of your .gitignore files" and the whole failure disappears.
#
# A silently unarmed repo has NO gates at all, which is strictly worse than a
# visible error. So every REQUIRED arming artifact is staged through
# stage_required(), which stops the command and says what to fix. This does not
# make init brittle: `git add` on an unchanged, already-tracked path is a no-op
# that exits 0, so a re-run over an already-adopted repo still succeeds.
stage_required() {  # stage_required <repo-relative-path>
  git -C "$REPO_ROOT" add -- "$1" && return 0
  echo "FATAL: /quetrex-setup:init could not stage the required arming artifact '$1'." >&2
  echo "  The usual cause is a .gitignore rule that covers it (e.g. a blanket '.quetrex/*')." >&2
  echo "  Add a negation for it ('!$1'), or drop the rule, then re-run /quetrex-setup:init." >&2
  echo "  NOT continuing: an unstaged arming artifact means this repo has NO gates," >&2
  echo "  and an unattended cloud build would stall at 'gh pr create' waiting for a human." >&2
  return 1
}

# The binding itself — without it nothing resolves this repo to a project.
stage_required .quetrex/project.json || exit 1
# Any CLAUDE.md cleanups from step 4 and the Verification rules from step 4b —
# QA and verify-gate.sh read the chain from here.
if [ -f "$REPO_ROOT/CLAUDE.md" ]; then
  stage_required CLAUDE.md || exit 1
fi
if [ -f "$REPO_ROOT/.claude/CLAUDE.md" ]; then
  stage_required .claude/CLAUDE.md || exit 1
fi
# The pipeline permissions union from step 4e. THIS is the QDM-4 artifact: a
# plugin cannot ship permissions.allow, so if this does not get committed the
# terminal `git push` / `gh pr create` prompt with nobody there to answer.
if [ -f "$REPO_ROOT/.claude/settings.json" ]; then
  stage_required .claude/settings.json || exit 1
fi
# F3 (CONFIRMED): .quetrex/* is commonly gitignored wholesale in a target repo,
# and a future install-time hardening (SEC-2's own remediation) is expected to
# assert exactly that — which would silently kill the whole requiredEnv mechanism
# everywhere unless that same hardening also adds `!.quetrex/verify.json` as an
# exception.
if [ -f "$REPO_ROOT/.quetrex/verify.json" ]; then
  stage_required .quetrex/verify.json || exit 1
fi
# Without this every pipeline developer lands in a worktree with no deps and no
# env and burns its self-heal budget "fixing" code that was never broken.
if [ -f "$REPO_ROOT/.worktreeinclude" ]; then
  stage_required .worktreeinclude || exit 1
fi
# The status bar is the ONLY place the running engine version is ever named — nothing
# is version-pinned — and a plugin cannot register a `statusLine`, so arming has to put
# the renderer in the repo itself. Conditional, because step 4h installs it only when the
# repo has none and registers nothing at all if the shipped script cannot be located: a
# genuinely optional path. But if it EXISTS and cannot be staged, that is the same silent
# half-arming F4 closed — so it fails loudly rather than being swallowed.
if [ -f "$REPO_ROOT/.claude/statusline-command.sh" ]; then
  stage_required .claude/statusline-command.sh || exit 1
fi
# NOT required-arming, and deliberately still tolerant: `.mcp.json` may not exist
# at all, and `add -A` on an absent, never-tracked path is an error rather than a
# no-op. `add -A` (not a `[ -f ]` guard) is on purpose: step 4h now REMOVES the
# dead quetrex-kanban broker and may delete the file outright, and a `[ -f ]`
# guard would skip a vanished file — leaving the repair uncommitted, so every
# teammate and every cloud routine kept the failing MCP server.
git -C "$REPO_ROOT" add -A .mcp.json 2>/dev/null || true
```

```bash
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

**FIRST LINE OF THE REPORT, ALWAYS — the restart.** Step 4h wrote `enabledPlugins`. Claude
Code registers a plugin's command layer at SESSION START, so a plugin this command just
enabled is NOT loaded in the session you are standing in: the marketplace shows it checked,
and `/quetrex:task-new` and every other `/quetrex:*` command still does not exist. This is the
single most confusing thing init does, and it reads as a broken install. Say so before
anything else, in these words:

> **Restart Claude Code before doing anything else.** This session cannot see the commands
> init just enabled — `/quetrex:*` will not exist until you restart, even though the plugin
> shows as installed. Quit and reopen, then run `/quetrex-setup:doctor` to confirm.

Print it whenever `enabledPlugins` was written or changed. Skip it ONLY when step 4h reported
*"already current"* and nothing else in `.claude/settings.json` changed — in that case the
commands are already loaded and telling them to restart is noise.

**Never report init as fully succeeded without it.** Adoption is not complete until the
restart happens; a partner who reads "done" and then finds no commands concludes the product
is broken. State it as the required next action, not as a footnote.

Then summarize for the user:

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
- **Branch prefix** — the value recorded in the binding (`claude/` by default), and, if it
  is not `claude/`, the one-line note that cloud routines need the repo's branch restriction
  loosened to push it.
- **Permissions** — which pipeline entries were added to the customer's own
  `.claude/settings.json` `permissions.allow` (or *"already covered"*), stated as additions
  they can see and revoke. Nothing was removed or narrowed.
- **Worktree environment** — the `.worktreeinclude` entries written (or *"already
  current"*), and the note that they are git-ignored paths copied into worktrees, never
  committed.
- **Engine pin** — the `enabledPlugins` written (`quetrex@quetrex: true` and the concrete
  `quetrex-factory@quetrex: <version>` pin), or *"already current"*; if the marketplace was
  unreachable, the note to run `/quetrex-setup:update` once online to write the concrete factory pin.
- **MCP broker** — what step 4h did to `.mcp.json`: removed the dead `quetrex-kanban`
  registration (and whether the emptied file was deleted), or nothing to remediate. If it
  removed one, say plainly that this repo had a broker pointing at an endpoint that was never
  built, that it is why MCP failed to connect on every session, and that the repair lands for
  the whole team with this commit.
- **Legacy cleanup** — *"already offered on this machine"*, *"nothing to clean"*, or the
  per-item outcome (quarantined / stripped / kept / flagged), noting that everything is
  reversible from the timestamped backup dir and that `secrets.env` was only flagged.
- **Secrets** — which local env creds were imported into the vault (by CANON name +
  masked last-4, never values), and the `dash.quetrex.com/keys` reminder for any missing
  ones.
- **Delivery** — the PR URL, or the local-commit note if no remote.

---

## Error-handling rules

- Reuse the helper's messaging verbatim: `401 → Run /quetrex-setup:login`,
  `403/404 → No access — contact your administrator`. The **only** override is the
  create-project 403, where you print the admin-specific hint instead.
- Never print the bearer token. Build all JSON with `node` / `JSON.stringify`.
- Idempotent: re-running on a linked repo never re-creates the binding and never
  prompts for a name — it re-verifies access and can re-clean / re-PR.
- Non-destructive: the only files this command creates are `.quetrex/project.json`,
  `.worktreeinclude` (step 4f) and `.claude/statusline-command.sh` (step 4h, and only when
  the repo has none — an existing one is never overwritten). The single deletion it performs anywhere is step 4h's purge of
  the `quetrex-kanban` broker whose url is the never-built `/api/mcp` endpoint — scoped to that
  one key, and to the file only when that key was all it held; `CLAUDE.md` edits only excise stale tracker
  blocks, never wholesale rewrites; `.claude/settings.json` is merged, never clobbered —
  step 4e only ever **adds** to `permissions.allow` and step 4h (`quetrex-arm`) only ever
  adds/updates the `enabledPlugins` pin, `extraKnownMarketplaces.quetrex` and the
  `statusLine` registration (added only when absent, or repaired when it is our own
  unguarded string — an operator's own `statusLine` is never touched), never removing
  or narrowing an entry, and never touching `permissions.deny`/`ask`. The only removals are
  user-confirmed stale old-Quetrex
  project commands/skills (step 4c) — never auto-deleted, never anything in the global
  `~/.claude`. The build gates (`verify-gate.sh`/`merge-gate.sh`/`secret-scan.sh` and the
  fat pipeline agents) are delivered by the `quetrex-factory` plugin pin (4h), never
  copied into the repo — this command never writes a hook or agent file.
- Never hardcode a branch prefix, and never ask the user to pick one: `branchPrefix`
  defaults to `claude/` in step 3d, is recorded in the binding, and is used for this
  command's own adoption branch and by every downstream command.
- Quetrex never asks about the Claude GitHub App: it is not used, not checked, and not reported. See 4g for why.
