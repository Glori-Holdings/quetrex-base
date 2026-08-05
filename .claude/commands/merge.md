---
description: Merge a Quetrex task's reviewed PR — brings the cloud build's gate evidence home, verifies it against the PR head, squash-merges, sets the task to merged, and tears the branch down. Usage: /quetrex:merge SMA-1
argument-hint: "<TASK-ID>  (e.g. DEA-1)"
---

# Quetrex Merge

Merge the pull request for one task, and finish the job: status moved, branch and worktree
gone. One command, no manual GitHub visit.

## Why this command exists

The build runs on Anthropic's servers. Every gate artifact — the verify ledger, the review
verdict, the security findings — is written **in that cloud sandbox**, and `.quetrex/*` is
git-ignored, so none of it travels with the pushed branch. `merge-gate.sh` then runs on the
operator's machine, finds no verdict, and denies the merge. That is not a bug in the gate; it
is a missing delivery step, and it is why merging always ended up being done by hand on
GitHub — which meant none of the pipeline's bookkeeping ever ran, and tasks stranded in
`in_progress`.

So this command's real job is **transport plus verification**: fetch the evidence the cloud
build published, prove it describes the exact commit being merged, then let the same gate
that always ran make the decision.

**It bypasses nothing.** `merge-gate.sh` still fires on the merge and re-checks every
artifact independently. If the evidence is missing, stale, or red, the merge is denied and
this command says so plainly. There is no flag to force it.

---

## 1. Resolve the task and its PR

```bash
TASK="$(echo "$ARGUMENTS" | tr -d '[:space:]')"
[ -n "$TASK" ] || { echo "Usage: /quetrex:merge <TASK-ID>   (e.g. /quetrex:merge DEA-1)" >&2; exit 1; }

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
BIND="$REPO_ROOT/.quetrex/project.json"
[ -f "$BIND" ] || { echo "This repo is not linked to a Quetrex project — run /quetrex:init." >&2; exit 1; }
BRANCH_PREFIX="$(quetrex-api json-get "$BIND" branchPrefix 2>/dev/null || echo "claude/")"
SLUG="$(git -C "$REPO_ROOT" remote get-url origin | sed -E 's#.*[:/]([^/]+/[^/]+?)(\.git)?$#\1#')"

# Find the open PR whose head branch carries this task id. Matching on the branch rather
# than the title: titles get edited, branch names do not.
PR_JSON="$(gh pr list --repo "$SLUG" --state open --limit 100 \
  --json number,headRefName,headRefOid,title,isDraft,mergeable,mergeStateStatus 2>/dev/null)"
PR="$(printf '%s' "$PR_JSON" | node -e '
  let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    let a; try{a=JSON.parse(s)}catch{process.exit(1)}
    const task=process.argv[1].toLowerCase();
    const hit=a.filter(p=>p.headRefName.toLowerCase().includes(task));
    if(hit.length!==1){ process.stderr.write(hit.length+"\n"); process.exit(2) }
    process.stdout.write(JSON.stringify(hit[0]));
  })' "$TASK")" || {
  echo "Could not identify a single open PR for $TASK in $SLUG. List them with: gh pr list --repo $SLUG" >&2
  exit 1
}
PR_NUM="$(printf '%s' "$PR" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).number)))')"
PR_HEAD="$(printf '%s' "$PR" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).headRefName)))')"
PR_SHA="$(printf '%s' "$PR" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).headRefOid)))')"
echo "$TASK → PR #$PR_NUM ($PR_HEAD @ ${PR_SHA:0:12})"
```

If zero or several PRs match, stop and show them. Never guess which PR a task means.

---

## 2. Bring the gate evidence home

```bash
GATES_BRANCH="${BRANCH_PREFIX}${TASK}-gates"
git -C "$REPO_ROOT" fetch -q origin "$GATES_BRANCH" 2>/dev/null && GATES_OK=1 || GATES_OK=0

if [ "$GATES_OK" -eq 1 ]; then
  mkdir -p "$REPO_ROOT/.quetrex"
  for f in verify-ledger.jsonl review-verdict.json qa-report.json security-findings.json gates-head; do
    git -C "$REPO_ROOT" show "FETCH_HEAD:.quetrex/$f" > "$REPO_ROOT/.quetrex/$f" 2>/dev/null || rm -f "$REPO_ROOT/.quetrex/$f"
  done
  GATES_SHA="$(tr -d '[:space:]' < "$REPO_ROOT/.quetrex/gates-head" 2>/dev/null || echo "")"
  echo "Fetched gate evidence from $GATES_BRANCH (pinned to ${GATES_SHA:0:12})"
else
  echo "No gates branch ($GATES_BRANCH) — this PR carries no published gate evidence."
fi
```

**Then check the pin yourself, before attempting anything.** The local gate will check it
too; catching it here produces a message that explains what to do instead of a denial:

```bash
if [ "$GATES_OK" -eq 1 ] && [ -n "$GATES_SHA" ] && [ "$GATES_SHA" != "$PR_SHA" ]; then
  echo "STALE EVIDENCE: the gates describe ${GATES_SHA:0:12}, but the PR head is ${PR_SHA:0:12}." >&2
  echo "Commits landed after the gates were published, so nothing has verified what would actually merge." >&2
  echo "Re-run the build for $TASK (/quetrex:task-build $TASK --build-only) so the gates are re-published against the current head." >&2
  exit 1
fi
```

With no evidence at all, say exactly this and stop — do not merge, and do not suggest a way
around it:

> PR #`<n>` has no published gate evidence, so nothing has verified it. Either re-run
> `/quetrex:task-build <TASK>` so the cloud build publishes its gates, or decide as a human
> that you are merging an unverified change and do it yourself on GitHub. This command will
> not merge what it cannot verify.

---

## 3. Check the PR itself

Artifacts prove our gates; GitHub's own state proves the PR is mergeable at all.

```bash
DRAFT="$(printf '%s' "$PR" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).isDraft)))')"
MERGEABLE="$(printf '%s' "$PR" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).mergeable)))')"
[ "$DRAFT" = "true" ] && { echo "PR #$PR_NUM is a draft — mark it ready first." >&2; exit 1; }
[ "$MERGEABLE" = "CONFLICTING" ] && { echo "PR #$PR_NUM has conflicts with the base branch — resolve them first." >&2; exit 1; }

# Checks: a failing check blocks. NO checks configured is not a failure — many repos have none.
CHECKS="$(gh pr checks "$PR_NUM" --repo "$SLUG" 2>&1 || true)"
if printf '%s' "$CHECKS" | grep -qE '^\S+\s+fail'; then
  echo "PR #$PR_NUM has failing checks:" >&2; printf '%s\n' "$CHECKS" >&2; exit 1
fi
if printf '%s' "$CHECKS" | grep -qE '^\S+\s+pending'; then
  echo "PR #$PR_NUM still has pending checks — wait for them (gh pr checks $PR_NUM --watch)." >&2; exit 1
fi
```

---

## 4. Merge — through the gate, not around it

The local `merge-gate.sh` hook fires on this command and independently re-verifies the
verdict, the ledger, the security findings and the ownership map against `HEAD`. That is the
decision point. If it denies, **surface its reason verbatim and stop** — it is reading the
same artifacts you just fetched, so its complaint is about the evidence, not about tooling.

```bash
gh pr merge "$PR_NUM" --repo "$SLUG" --squash --delete-branch
```

`--delete-branch` removes the remote branch and, when the local branch is checked out
nowhere, the local one too.

---

## 5. Finish the job — the part that never used to happen

None of this ran while merges were done by hand, which is why tasks sat in `in_progress`
long after they shipped.

```bash
# a. The board.
quetrex-api task-status "$TASK" merged && echo "$TASK → merged"

# b. Return to the base branch and fast-forward. `pull --ff-only` is a SYNC, and the merge
#    gate exempts syncing the protected branch from its own upstream.
git -C "$REPO_ROOT" switch -q main 2>/dev/null || git -C "$REPO_ROOT" switch -q master
git -C "$REPO_ROOT" fetch --prune -q origin
git -C "$REPO_ROOT" pull --ff-only -q origin "$(git -C "$REPO_ROOT" branch --show-current)"

# c. Tear down the worktree for this task, if the pipeline made one.
for wt in $(git -C "$REPO_ROOT" worktree list --porcelain | awk '/^worktree /{print $2}'); do
  case "$wt" in
    *"$TASK"*) git -C "$REPO_ROOT" worktree remove "$wt" --force 2>/dev/null && echo "removed worktree $wt" ;;
  esac
done
git -C "$REPO_ROOT" worktree prune

# d. Delete the unit branch locally, and the gates branch everywhere — its evidence is now
#    committed history on the base branch, so keeping it just clutters the ref list.
git -C "$REPO_ROOT" branch -D "$PR_HEAD" 2>/dev/null || true
git -C "$REPO_ROOT" push -q origin --delete "$GATES_BRANCH" 2>/dev/null || true
git -C "$REPO_ROOT" branch -D "$GATES_BRANCH" 2>/dev/null || true

# e. The fetched artifacts described a branch that no longer exists. Leaving them behind is
#    how a stale verdict ends up denying an unrelated merge days later.
rm -f "$REPO_ROOT/.quetrex/review-verdict.json" "$REPO_ROOT/.quetrex/qa-report.json" \
      "$REPO_ROOT/.quetrex/security-findings.json" "$REPO_ROOT/.quetrex/verify-ledger.jsonl" \
      "$REPO_ROOT/.quetrex/gates-head"
```

---

## 6. Report

- **PR** — number, title, the commit that merged.
- **Evidence** — which gate artifacts backed it, and the sha they were pinned to.
- **Board** — `<TASK>` → `merged`.
- **Cleanup** — branches and worktree removed, base branch fast-forwarded.
- **Next** — `/quetrex:deploy`, then `/quetrex:task-complete <TASK>`.

---

## Error-handling rules

- **Never merge without verified evidence**, and never offer a bypass. Missing or stale
  gates mean the honest answer is "re-run the build" or "merge it yourself as a human".
- **Never edit a gate artifact** to make a merge pass. Publish-and-verify only works while
  the artifacts are untouched.
- If `merge-gate.sh` denies, quote its reason verbatim. It is the authority, not this file.
- Always run step 5 after a successful merge, even if part of it fails — report what did not
  clean up rather than leaving it silent.
- Build all JSON with `node`; never `read ... < <(...)` (`read` exits non-zero on a final
  line with no trailing newline, so a fatal guard fires on success).
