---
name: worktree-workflow
description: Run any unit of code work in an isolated git worktree + branch, make that worktree actually runnable, and tear it down cleanly. Use whenever you (orchestrator or agent) will commit/push code, branch off main, open a PR, or coordinate parallel work — especially when the enforce-branch hook blocks commits on main, or to guarantee no dangling worktrees/branches/PRs are left behind.
allowed-tools: Bash, Read
---

# Worktree Workflow

The standing procedure for isolated, self-cleaning code work. `main` (and `master`) are
protected: a PreToolUse hook (`enforce-branch.sh`, "HARD-RULE #6") **blocks `git commit` /
`git push` whenever the working branch resolves to main/master**, and remote `main`
requires a PR. So all code work happens on a branch in a worktree, merges via PR, and is
cleaned up immediately.

The golden rule: **never leave a dangling worktree, an open/unmerged PR, or a stale
local/remote branch.** Clean as you go.

## 0. Where worktrees live, and what to call the branch

Put worktrees in a dedicated sibling dir, never on top of an existing path:
`../<project>-worktrees/<unit-name>`. Before creating, `ls` the target — if a dir already
exists that you did not create, pick another name; do not delete unknown dirs.

**Branch names use the project's prefix, never a hardcoded one.** Read it from the
binding, defaulting to `claude/`:

```bash
BIND="$(git rev-parse --show-toplevel)/.quetrex/project.json"
PFX="$(node -e 'try{process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).branchPrefix||"claude/"))}catch{process.stdout.write("claude/")}' "$BIND" 2>/dev/null || echo claude/)"
BRANCH="${PFX}<unit>"
```

`claude/` is the default because it is the only prefix an Anthropic cloud routine can push
to without a repo admin loosening the branch restriction first. A team that prefers another
convention sets `"branchPrefix"` in `.quetrex/project.json` and every branch this skill
creates follows.

## 1. Create the branch + worktree

```bash
WT="../<project>-worktrees/<unit>"
git worktree add -b "$BRANCH" "$WT" main
```
For an existing branch, omit `-b`: `git worktree add "$WT" "$BRANCH"`.

## 2. Hydrate it — a bare worktree is NOT runnable (do not skip)

**A worktree carries only tracked files.** `node_modules/`, `.env*`, and everything else
in `.gitignore` are absent. `.worktreeinclude` is applied by the harness to the worktrees
*it* creates — **it does not apply to a worktree you created with `git worktree add`.**
Copy the entries yourself, then install dependencies:

```bash
ROOT="$(git rev-parse --show-toplevel)"
if [ -f "$ROOT/.worktreeinclude" ]; then
  while IFS= read -r pat; do
    case "$pat" in ''|'#'*) continue ;; esac
    for src in $ROOT/$pat; do
      [ -e "$src" ] || continue
      rel="${src#$ROOT/}"
      mkdir -p "$WT/$(dirname "$rel")"
      cp -R "$src" "$WT/$(dirname "$rel")/"
    done
  done < "$ROOT/.worktreeinclude"
fi

# Install deps with the manager the lockfile names — never assume one.
if   [ -f "$WT/pnpm-lock.yaml" ];   then (cd "$WT" && pnpm install --frozen-lockfile)
elif [ -f "$WT/yarn.lock" ];        then (cd "$WT" && yarn install --immutable)
elif [ -f "$WT/bun.lockb" ] || [ -f "$WT/bun.lock" ]; then (cd "$WT" && bun install --frozen-lockfile)
elif [ -f "$WT/package-lock.json" ];then (cd "$WT" && npm ci)
elif [ -f "$WT/package.json" ];     then (cd "$WT" && npm install)
elif [ -f "$WT/uv.lock" ];          then (cd "$WT" && uv sync)
elif [ -f "$WT/poetry.lock" ];      then (cd "$WT" && poetry install)
elif [ -f "$WT/requirements.txt" ]; then (cd "$WT" && python -m pip install -r requirements.txt)
fi
```

Then confirm the tree is live before writing any code — one cheap command from the verify
chain (a typecheck or a single test) must exit 0.

**If hydration fails, that is a SETUP failure, not a code failure.** Report it and stop.
Never "fix" a build that is red only because the worktree has no deps or no env — an
agent self-healing against a missing `.env` is how hardcoded credentials and weakened
tests get written.

## 3. Do the work — commit/push with `git -C` (CRITICAL)

The enforce-branch hook decides which branch you're on by, in order: a `git -C <path>`
token in the command, a `cd <path> && …` token, else the **session's primary cwd**
(usually `main`). A bare `cd <path>` on its own line is NOT detected — the hook falls back
to the primary cwd, sees `main`, and **blocks you**.

```bash
git -C "$WT" add -A
git -C "$WT" -c user.name='<name>' -c user.email='<email>' commit -q -m "feat(<unit>): …"
git -C "$WT" push -u origin "$BRANCH"
```

When delegating to a subagent, tell it to work **exclusively** under the absolute worktree
path and to use `git -C <abs-path>` for every git command.

## 4. PR → CI → merge

```bash
gh pr create --base main --head "$BRANCH" --title "…" --body "…"
gh pr checks <num> --watch
gh pr merge <num> --squash --delete-branch
```
Merge only when CI is green. `--delete-branch` removes the remote branch (and tries local).

## 5. Tear down — every time

```bash
git worktree remove "$WT" --force   # BEFORE deleting the branch — a branch in use
git worktree prune                  # by a worktree cannot be deleted
git branch -D "$BRANCH"             # if --delete-branch couldn't
git fetch --prune origin            # drop the stale origin/<branch> ref
```

## 6. Final audit — prove it's clean

At the end of any multi-unit effort, run and confirm only `main` remains:
```bash
git worktree list            # only the primary checkout on main
git branch                   # only main
git branch -r                # only origin/main (+ origin/HEAD)
gh pr list --state open      # none
ls ../<project>-worktrees/ 2>/dev/null   # empty / absent
```

Gotchas hit in practice, one-time repo hardening, and branch-protection setup:
see [reference.md](reference.md).
