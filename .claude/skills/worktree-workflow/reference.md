# worktree-workflow — reference

Detail that would otherwise crowd `SKILL.md`. Read it when something in the main
procedure misbehaves, or when setting a repo up for the first time.

---

## Why a worktree is empty, and what `.worktreeinclude` actually covers

`git worktree add` checks out **tracked files only**. Everything in `.gitignore` —
`node_modules/`, `.env`, `.env.local`, local caches, generated config — simply is not
there. This is not a bug; it is what makes worktrees cheap.

`.worktreeinclude` at the repo root lists the git-ignored paths every worktree needs:

```
.env
.env.local
.claude/settings.local.json
```

**Scope, precisely:** the harness applies it to the worktrees it creates for built-in
agent isolation (`isolation: worktree`). It is **not** a git feature and **not** applied
to a worktree you create yourself with `git worktree add`. Step 2 of the skill copies the
entries by hand for exactly that reason. `/q-init` generates the file from the env files
it already scans during adoption.

**Never commit the file's *contents*.** `.worktreeinclude` lists paths; the paths it lists
stay git-ignored. Copying them into a worktree does not stage them — but a careless
`git add -A` in that worktree would, so keep `.gitignore` authoritative there too.

## Why hydration failure must never be self-healed

An agent that lands in an un-hydrated worktree sees a red build and cannot tell "the code
is wrong" from "there is no environment here". Given three bounded self-heal attempts it
will spend all three making a green build appear — hardcoding a database URL, stubbing an
auth secret, loosening a test — and then escalate. The artefact is a diff that looks like
work and is not.

So: **a missing dependency or missing env var is a setup failure, reported and stopped
on. It is never a code failure to fix.** If you cannot get the worktree green with one
cheap chain command before writing anything, stop there.

## `branchPrefix` — why it is not hardcoded

Cloud routines start from a fresh clone of the default branch and, unless the restriction
is loosened per repo, **can only push to `claude/`-prefixed branches**. Everything else in
this workflow survives that restriction — creating worktrees, committing on local
sub-branches, merging sub-branches locally, basing off an integration branch, diffing
`main...HEAD`. Only the **push** breaks — and with no push there is no PR, and the
pipeline has no terminus.

So the prefix is data, not a constant: `.quetrex/project.json` carries `branchPrefix`,
defaulting to `feature/`. A repo that cannot be loosened sets `"claude/"` and everything
downstream follows. Do not hardcode `feature/` in new code paths.

## Gotchas (all hit in practice)

- **Hook blocks commit on main** → you used a bare `cd` or no path token. Switch to
  `git -C <path>`. A `cd <path> && git commit …` joined with `&&` also works; a bare `cd`
  on its own line does not.
- **"cannot delete branch … used by worktree"** → remove the worktree first, then delete
  the branch.
- **`git branch -r` still shows a merged branch** → the local remote-tracking ref is
  stale; `git fetch --prune`.
- **Built-in agent `isolation: "worktree"` errors "not in a git repository"** → the
  harness cached repo state at session start (e.g. the repo was `git init`'d mid-session).
  Create worktrees manually with `git worktree add` and launch a `general-purpose` agent
  pinned to the absolute path, instead of the `developer`/`architect` types (which force
  built-in isolation).
- **A clean worktree the harness created is removed automatically when its session
  exits.** Worktrees *you* created with `git worktree add` are not — tear them down.

## One-time repo hardening

Auto-delete merged branches:

```bash
gh api -X PATCH repos/<owner>/<repo> -F delete_branch_on_merge=true
```

Branch protection on a private repo requires a **paid org / Pro** plan (free personal
private repos get HTTP 403 "Upgrade to GitHub Pro"). Put the repo under a paid org if
needed.

Standard protection + a required CI check. To add a required check you must PUT the
**full** protection object — PATCHing `…/required_status_checks` 404s if it was
initialized null:

```bash
gh api -X PUT repos/<owner>/<repo>/branches/main/protection --input - <<'JSON'
{ "required_status_checks": { "strict": true, "contexts": ["verify"] },
  "enforce_admins": false,
  "required_pull_request_reviews": { "required_approving_review_count": 0, "dismiss_stale_reviews": true },
  "restrictions": null, "allow_force_pushes": false, "allow_deletions": false }
JSON
```

`required_approving_review_count: 0` lets a solo owner self-merge (GitHub forbids
approving your own PR). Set `contexts` to the names of the checks the repo actually
publishes.
