---
description: Merge a standalone task's PR (squash) with full branch/worktree cleanup, then set the kanban task to merged. Usage: /task-merge SMA-1
argument-hint: <TASK-ID like SMA-1>
---

# Task Merge

The manual merge gate for a **standalone (non-epic) task**: find the task's open PR,
confirm it is green and approved, **squash-merge** it, do THOROUGH local + remote cleanup
(zero dangling branches or worktrees), then set the kanban task's status to `merged`.

This command is governed by the **`worktree-workflow`** skill — read it and reuse its
teardown + final-audit steps rather than improvising. Use `git -C "$REPO_ROOT"` for every git
command so the enforce-branch hook sees the real branch instead of blocking on main.

Argument: `$ARGUMENTS` is a single human task identifier, e.g. `SMA-1`.

---

## 1. Parse the argument

```bash
TASK_ID="$(echo "$ARGUMENTS" | tr -d '[:space:]')"
```

If `TASK_ID` is empty, print usage and stop:

> Usage: `/task-merge SMA-1`

---

## 2. Source the helper and resolve context

```bash
source ~/.claude/lib/quetrex-api.sh
resolve_auth    || exit 1
resolve_project || exit 1
REPO_ROOT="$(git rev-parse --show-toplevel)"
echo "Project: $QX_PROJECT_CODE @ $QX_KANBAN_URL — repo: $REPO_ROOT"
```

---

## 3. Validate project access and fetch the task

```bash
qapi GET "/api/projects/$QX_PROJECT_CODE" >/dev/null || exit 1
TASK="$(qapi GET "/api/tasks/$TASK_ID")" || exit 1
```

Parse any recorded PR hints from the task record (used as the preferred path in step 4):

```bash
PRNUM="$(node -e 'try{const o=JSON.parse(process.argv[1]);process.stdout.write(String(o.prNumber||o.pullRequestNumber||""))}catch{}' "$TASK")"
```

---

## 4. Find the open PR

**a. If the task carries a PR number**, use it directly:

```bash
[ -n "$PRNUM" ] && gh pr view "$PRNUM" \
  --json number,title,headRefName,state,mergeStateStatus,statusCheckRollup,reviewDecision
```

**b. Otherwise discover by branch-name convention.** Glori branches embed the task
identifier: `feature/<TASK_ID>-...` (and sub-branches `-api` / `-ui`). Search open PRs by
head branch:

```bash
gh pr list --state open \
  --json number,title,headRefName,mergeStateStatus,statusCheckRollup,reviewDecision \
  --search "head:feature/$TASK_ID"
```

If that search yields nothing, list all open PRs and match `headRefName` on the task
identifier as a **whole token**, not a loose substring. A plain `includes("SMA-1")` would
also match `feature/SMA-12-...`, which could squash-merge the **wrong** PR; require the id to
be bounded by a non-alphanumeric, **non-dot** char (or string start/end) on both sides so
`SMA-1` matches `feature/SMA-1-foo` and `feature/SMA-1-api`, never `feature/SMA-12-bar`, and —
critically — never a child branch `feature/SMA-1.2-...` (the `.` is excluded from the boundary
class, so an epic id can't match its `CODE-N.C` children):

```bash
gh pr list --state open --json number,title,headRefName | \
  node -e '
    const id=process.argv[1].toLowerCase();
    const esc=id.replace(/[.*+?^${}()|[\]\\]/g,"\\$&");
    // Boundaries exclude "." so epic SMA-1 never matches child feature/SMA-1.2-...
    const re=new RegExp("(^|[^a-z0-9.])"+esc+"([^a-z0-9.]|$)","i");
    let a=""; process.stdin.on("data",d=>a+=d).on("end",()=>{
      const m=JSON.parse(a).filter(p=>re.test(p.headRefName));
      m.forEach(p=>console.log(`${p.number}\t${p.headRefName}\t${p.title}`));
      process.exit(m.length?0:3);
    });
  ' "$TASK_ID"
```

The `head:feature/$TASK_ID` search in the previous sub-step can also surface a longer-id
branch as a prefix match; apply the same whole-token check to anything it returns before
treating it as the match.

- **0 matches** → tell the user no open PR was found for `$TASK_ID`, and stop.
- **>1 matches** → list them and ask the user to disambiguate. Do **not** guess.
- **Exactly 1** → capture its `number` into `PRNUM` and `headRefName` into `HEADREF`.

---

## 5. Confirm CI + review state before merging

Read the PR's JSON (`gh pr view "$PRNUM" --json mergeStateStatus,statusCheckRollup,reviewDecision,headRefName,title`)
and require ALL of:

- `statusCheckRollup` — every check `SUCCESS` (or none configured). If any check is
  `PENDING`/`IN_PROGRESS` or `FAILURE`/`ERROR`, report the exact failing/pending checks and
  **stop**. Do not wait-loop and do not force-merge.
- `mergeStateStatus` — not `BLOCKED` and not `DIRTY`. If blocked or dirty, report the state
  and stop.
- `reviewDecision` — surface it. PRs require human approval per workflow rules; if it is
  `CHANGES_REQUESTED`, stop. (`REVIEW_REQUIRED`/`APPROVED`/empty: report and continue only
  when `mergeStateStatus` is mergeable.)

Capture `HEADREF` from this view for cleanup.

---

## 6. Squash-merge and delete the remote branch

```bash
gh pr merge "$PRNUM" --squash --delete-branch
```

`--delete-branch` removes the remote branch (and tries the local one).

---

## 7. Local teardown — worktree first, then branch

A branch checked out in a worktree cannot be deleted, so remove the worktree first. Find any
worktree whose branch is `$HEADREF`:

```bash
WT_PATH="$(git -C "$REPO_ROOT" worktree list --porcelain | node -e '
  const ref="refs/heads/"+process.argv[1];
  let a=""; process.stdin.on("data",d=>a+=d).on("end",()=>{
    let path="";
    for(const line of a.split("\n")){
      if(line.startsWith("worktree ")) path=line.slice(9);
      if(line==="branch "+ref){ process.stdout.write(path); break; }
    }
  });
' "$HEADREF")"

if [ -n "$WT_PATH" ] && [ "$WT_PATH" != "$REPO_ROOT" ]; then
  git -C "$REPO_ROOT" worktree remove "$WT_PATH" --force
  echo "Removed worktree: $WT_PATH"
else
  echo "No worktree was checked out on $HEADREF."
fi

git -C "$REPO_ROOT" worktree prune
git -C "$REPO_ROOT" branch -D "$HEADREF" 2>/dev/null && echo "Deleted local branch $HEADREF." || echo "No local branch $HEADREF to delete."
git -C "$REPO_ROOT" fetch --prune origin    # drop the stale origin/$HEADREF remote-tracking ref
```

---

## 8. Set the kanban task to merged

```bash
PAYLOAD="$(node -e 'process.stdout.write(JSON.stringify({status:"merged"}))')"
qapi PATCH "/api/tasks/$TASK_ID" "$PAYLOAD" >/dev/null || {
  echo "PR #$PRNUM was squash-merged and cleaned up, but updating $TASK_ID to 'merged' on the kanban FAILED. Re-run /task-merge or set its status to merged manually." >&2
  exit 1
}
echo "$TASK_ID → merged."
```

If the PATCH fails **after** a successful merge, report that the merge + cleanup succeeded but
the kanban update did not, and tell the user to re-run or set the status manually (above).

---

## 9. Final audit — prove nothing is dangling

Run the `worktree-workflow` final audit and include the all-clear in your report:

```bash
git -C "$REPO_ROOT" worktree list      # expect only the primary checkout
git -C "$REPO_ROOT" branch             # $HEADREF gone
git -C "$REPO_ROOT" branch -r          # origin/$HEADREF gone
gh pr list --state open                # PR #$PRNUM gone
```

Then report exactly what happened:
- PR **#$PRNUM** "<title>" squash-merged,
- remote branch deleted, local branch deleted (or "none found"),
- worktree removed (path) or "none found", prune + fetch --prune done,
- kanban `$TASK_ID` → merged,
- final audit clean (or call out anything still present).

---

## Error-handling rules

- No PR found → tell the user, stop. Multiple PRs → list them, ask, do not guess.
- Checks pending/failing or PR `BLOCKED`/`DIRTY`/`CHANGES_REQUESTED` → report exact state,
  stop. Never force-merge.
- No local worktree/branch → report "none found" and still PATCH the kanban status.
- PATCH fails after merge → report merge succeeded, kanban update failed; tell the user to
  fix it manually.
- Any `qapi` or resolver non-zero exit → the helper already printed the correct message.
- Never print or echo the bearer token. Never run `set -x` around `qapi`.
