---
name: worktree-workflow
description: Run any unit of code work in an isolated git worktree + branch and tear it down cleanly. Use whenever you (orchestrator or agent) will commit/push code, branch off main, open a PR, or coordinate parallel work — especially when the enforce-branch hook blocks commits on main, or to guarantee no dangling worktrees/branches/PRs are left behind.
allowed-tools: Bash, Read
---

# Worktree Workflow

The standing procedure for isolated, self-cleaning code work. `main` (and `master`) are protected: a PreToolUse hook (`~/.claude/hooks/enforce-branch.sh`, "HARD-RULE #6") **blocks `git commit`/`git push` whenever the working branch resolves to main/master**, and remote `main` requires a PR + passing CI. So all code work happens on a branch in a worktree, merges via PR, and is cleaned up immediately.

The golden rule: **never leave a dangling worktree, an open/unmerged PR, or a stale local/remote branch.** Clean as you go.

## 0. Where worktrees live

Put worktrees in a dedicated sibling dir, never on top of an existing path:
`../<project>-worktrees/<unit-name>` (e.g. `../glori-worktrees/billing`).
Before creating, `ls` the target — if a dir already exists that you did not create, pick another name; do not delete unknown dirs.

## 1. Create the branch + worktree

```bash
git worktree add -b feature/<unit> ../<project>-worktrees/<unit> main
```
For an existing branch, omit `-b`: `git worktree add ../<project>-worktrees/<unit> feature/<unit>`.

## 2. Do the work — and commit/push with `git -C` (CRITICAL)

The enforce-branch hook decides which branch you're on by, in order: a `git -C <path>` token in the command, a `cd <path> && …` token, else the **session's primary cwd** (usually on `main`). A bare `cd <path>` on its own line (newline-separated, no `&&`) is NOT detected — the hook falls back to the primary cwd, sees `main`, and **blocks you**.

So always address the worktree explicitly. Prefer `git -C`:

```bash
WT=../<project>-worktrees/<unit>
git -C "$WT" add -A
git -C "$WT" -c user.name='<name>' -c user.email='<email>' commit -q -m "feat(<unit>): …

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git -C "$WT" push -u origin feature/<unit>
```
(Equivalently, join with `&&`: `cd "$WT" && git commit …`. Never a bare `cd` on its own line for commit/push.)

When delegating to a subagent, tell it to work **exclusively** under the absolute worktree path and to use `git -C <abs-path>` for every git command.

## 3. PR → CI → merge

```bash
gh pr create --base main --head feature/<unit> --title "…" --body "…"
gh pr checks <num> --watch        # or: gh run watch <run-id> --exit-status
gh pr merge <num> --squash --delete-branch
```
Merge only when CI (the required `qa` check) is green. `--delete-branch` removes the remote branch (and tries the local one).

## 4. Tear down — every time

```bash
git worktree remove ../<project>-worktrees/<unit> --force   # do this BEFORE deleting the local branch —
git worktree prune                                          # a branch in use by a worktree cannot be deleted
git branch -D feature/<unit>                                # if --delete-branch couldn't (worktree had it checked out)
git fetch --prune origin                                    # drop the stale origin/<branch> remote-tracking ref
```

## 5. Final audit — prove it's clean

At the end of any multi-unit effort, run and confirm only `main` remains:
```bash
git worktree list            # only the primary checkout on main
git branch                   # only main
git branch -r                # only origin/main (+ origin/HEAD)
gh pr list --state open      # none
ls ../<project>-worktrees/ 2>/dev/null   # empty / absent
```

## One-time repo hardening (so this stays automatic)

- Auto-delete merged branches: `gh api -X PATCH repos/<owner>/<repo> -F delete_branch_on_merge=true`
- Branch protection on a private repo requires a **paid org/Pro** plan (free personal private repos get HTTP 403 "Upgrade to GitHub Pro"). Put the repo under a paid org if needed.
- Standard protection + required CI check (note: to add a required check you must PUT the **full** protection object — PATCHing `…/required_status_checks` 404s if it was initialized null):
```bash
gh api -X PUT repos/<owner>/<repo>/branches/main/protection --input - <<'JSON'
{ "required_status_checks": { "strict": true, "contexts": ["qa"] },
  "enforce_admins": false,
  "required_pull_request_reviews": { "required_approving_review_count": 0, "dismiss_stale_reviews": true },
  "restrictions": null, "allow_force_pushes": false, "allow_deletions": false }
JSON
```
  `required_approving_review_count: 0` lets a solo owner self-merge (GitHub forbids approving your own PR).

## Gotchas (all hit in practice)
- **Hook blocks commit on main** → you used a bare `cd` or no path token; switch to `git -C <path>`.
- **"cannot delete branch … used by worktree"** → remove the worktree first, then delete the branch.
- **`git branch -r` still shows a merged branch** → local remote-tracking ref is stale; `git fetch --prune`.
- **Built-in Agent `isolation: "worktree"` errors "not in a git repository"** → the harness cached repo-state at session start (e.g. repo was `git init`'d mid-session); create worktrees manually with `git worktree add` and launch a `general-purpose` agent pinned to the absolute path instead of the `developer`/`architect` types (which force built-in isolation).
