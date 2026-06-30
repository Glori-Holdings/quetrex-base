---
description: Link this repo to a Quetrex project (writes ./.quetrex/project.json) or create one, then non-destructively adopt the repo (clean stale tracker refs, point to /keys, open a PR). Usage: /quetrex-init [project name]
argument-hint: "[project name — only used when the repo is not yet linked]"
---

# Quetrex Init

Bind this repository to a Quetrex project. If the repo is **already linked**
(`./.quetrex/project.json` exists), re-verify access and re-run adoption — never
re-create the binding and never prompt for a name. If it is **not linked**, create
the project (or surface the admin-only guidance on 403) and write the binding.

This command is **non-destructive**: it only ever ADDs `.quetrex/project.json` and
auto-cleans stale tracker references from `CLAUDE.md`. It never overwrites or deletes
existing `.claude/`, `CLAUDE.md` body content, commands, settings, or any git/Claude
history. Secrets are never prompted for here — they live at `dash.quetrex.com/keys`.

**Token safety:** never echo or print the bearer token. The helper's `qapi` injects
it via a `0600` temp config and never exposes it. Build all JSON with
`node` / `JSON.stringify`, never with `echo`. No `set -x`, no `curl -v`.

---

## 1. Resolve auth

Run a single bash block. The helper owns all auth messaging — do not reinvent it.

```bash
source ~/.claude/lib/quetrex-api.sh
resolve_auth || exit 1   # prints "Run /quetrex-login" on miss/expiry
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
  echo "Creating a project requires admin — ask a super_admin to create it, or get added to an existing project, then re-run /quetrex-init." >&2
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

## 5. Point to /keys (never prompt for secrets)

Print exactly:

> Set this project's deploy secrets at https://dash.quetrex.com/keys — do not paste keys here.

Do not prompt for, read, or store any key values in this command.

---

## 6. Commit the additions — PR if possible, else local

Follow the `worktree-workflow` conventions. Stage **only** the additions/cleanups:
`.quetrex/project.json` plus any `CLAUDE.md` edits made in step 4. Use
`git -C "$REPO_ROOT"` so the enforce-branch hook sees the branch rather than blocking
on `main`.

```bash
BRANCH="feature/quetrex-init-adopt"
git -C "$REPO_ROOT" checkout -b "$BRANCH" 2>/dev/null || git -C "$REPO_ROOT" checkout "$BRANCH"

# Stage only what this command added/cleaned.
git -C "$REPO_ROOT" add .quetrex/project.json 2>/dev/null || true
[ -f "$REPO_ROOT/CLAUDE.md" ]        && git -C "$REPO_ROOT" add CLAUDE.md 2>/dev/null || true
[ -f "$REPO_ROOT/.claude/CLAUDE.md" ] && git -C "$REPO_ROOT" add .claude/CLAUDE.md 2>/dev/null || true

if git -C "$REPO_ROOT" diff --cached --quiet; then
  echo "Nothing to commit — repo already adopted."
else
  git -C "$REPO_ROOT" commit -m "chore: adopt repo into Quetrex project $CODE

Add .quetrex/project.json binding and clean stale tracker references." >/dev/null

  # Open a PR only if there is a remote AND gh is available.
  if git -C "$REPO_ROOT" remote get-url origin >/dev/null 2>&1 && command -v gh >/dev/null 2>&1; then
    git -C "$REPO_ROOT" push -u origin "$BRANCH" >/dev/null 2>&1
    PR_URL="$(gh pr create --repo "$(git -C "$REPO_ROOT" remote get-url origin)" \
      --head "$BRANCH" \
      --title "chore: adopt repo into Quetrex project $CODE" \
      --body "Links this repo to Quetrex project \`$CODE\` (adds \`.quetrex/project.json\`) and cleans stale tracker references from CLAUDE.md. Non-destructive: no existing config or history was overwritten." 2>/dev/null)"
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
- **Secrets** — the `dash.quetrex.com/keys` reminder.
- **Delivery** — the PR URL, or the local-commit note if no remote.

---

## Error-handling rules

- Reuse the helper's messaging verbatim: `401 → Run /quetrex-login`,
  `403/404 → No access — contact your administrator`. The **only** override is the
  create-project 403, where you print the admin-specific hint instead.
- Never print the bearer token. Build all JSON with `node` / `JSON.stringify`.
- Idempotent: re-running on a linked repo never re-creates the binding and never
  prompts for a name — it re-verifies access and can re-clean / re-PR.
- Non-destructive: the only file created is `.quetrex/project.json`; `CLAUDE.md`
  edits only excise stale tracker blocks, never wholesale rewrites.
