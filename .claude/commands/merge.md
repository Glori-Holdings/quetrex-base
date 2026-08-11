---
description: Merge a Quetrex task's reviewed PR — brings the cloud build's gate evidence home, verifies it against the PR head, squash-merges, sets the task to merged, and tears the branch down. Usage: /quetrex:merge SMA-1
argument-hint: "<TASK-ID>  (e.g. DEA-1, or DEA-1.2 for an epic child)"
---

# Quetrex Merge

Merge the pull request for one task, and finish the job: status moved, branches and worktree
gone. One command, no manual GitHub visit.

"One task" means a standalone unit, an **epic child** (`<CODE>-<N>.<C>`), or an epic's
integration → main terminus — all three are ordinary PRs judged by the same gate. The child
case is not a variant: `/quetrex:merge <child>` is what the epic's dispatch tick calls to
**reap** each finished child, and it is the only thing in the engine that sets a child to
`merged` — the one status that satisfies a dependency and releases the next wave of the DAG.

## Why this command exists

The build runs on Anthropic's servers. Every gate artifact — the verify ledger, the review
verdict, the security findings, the architect's plan — is written **in that cloud sandbox**,
and `.quetrex/*` is git-ignored, so none of it travels with the pushed branch. `merge-gate.sh`
then runs on the operator's machine, finds no verdict, and denies the merge. That is not a bug
in the gate; it is a missing delivery step, and it is why merging always ended up being done by
hand on GitHub — which meant none of the pipeline's bookkeeping ever ran, and tasks stranded in
`in_progress`.

So this command's real job is **transport plus verification**: fetch the evidence the cloud
build published, prove it describes the exact commit being merged, then let the same gate
that always ran make the decision.

**It bypasses nothing.** `merge-gate.sh` still fires on the merge and re-checks every
artifact independently. If the evidence is missing, stale, or red, the merge is denied and
this command says so plainly. There is no flag to force it.

---

## 0. Two rules that govern every step below

**Rule A — state does not survive a Bash call.** Claude Code starts a fresh shell for every
Bash tool call, so a variable assigned in §1 is gone by §2. Step 1 therefore writes every
value it resolves to `.quetrex/merge-facts.env`, and each later block starts by sourcing it.
Do not assume a `$VAR` from an earlier block is still set.

**Rule B — a hook reads the command's TEXT, before the shell expands it.** `merge-gate.sh`,
`deny-guard.sh` and `enforce-branch.sh` are `PreToolUse` hooks: they are handed the command
string you are about to run, **not** the string a shell would produce from it. So
`gh pr merge "$PR_NUM"` arrives at `merge-gate.sh` as the literal eight characters `$PR_NUM`;
the gate runs `gh pr view $PR_NUM --json headRefOid,baseRefOid`, that fails, and — correctly
fail-closed — it **denies the merge**, blaming `gh` authentication. The identical command with
the number typed in resolves the PR and proceeds to the real gates.

So: in the commands of **§4** and **§5d** — the ones a hook must be able to parse — **type the
values in as literal text**. Not `"$PR_NUM"`, not `"$GATES_BRANCH"`, not `"$SLUG"`. Read them
off the line §1 prints and write them into the command. Rule A applies everywhere else; Rule B
overrides it for those two blocks.

---

## 1. Resolve the task and its PR

```bash
TASK="$(echo "$ARGUMENTS" | tr -d '[:space:]')"
[ -n "$TASK" ] || { echo "Usage: /quetrex:merge <TASK-ID>   (e.g. /quetrex:merge DEA-1)" >&2; exit 1; }

# A Quetrex task id is <CODE>-<number>, and an epic CHILD is <CODE>-<number>.<child> —
# exactly one level deep, because the decomposition forbids grandchildren. The server is
# authoritative on the shape: quetrex-kanban's `src/lib/task-ref.ts` matches
# `^([A-Za-z][A-Za-z0-9]*)-(\d+)(?:\.(\d+))?$` and `src/lib/dto.ts` renders it with
# `childIdent(n, cn, code) => cn == null ? code-n : code-n.cn`.
#
# **The child form must be accepted here.** `/quetrex:merge <child>` is the reaper of an
# epic's DAG — it is the only thing in the engine that sets a child to `merged`, and `merged`
# is the only status that satisfies a dependency. While this validator required the plain
# form, every `/quetrex:merge QDM-2.1` died on this line, so no wave after the first could
# ever be unblocked and every epic stranded.
#
# Validating the shape still matters for the same reason as before — it catches a typo before
# it is matched against a hundred branch names, and it keeps a shell metacharacter out of the
# ref names and paths §2/§5 build from it. What it no longer buys is regex safety: a child id
# contains a literal `.`, so the matcher below MUST escape it (see there).
printf '%s' "$TASK" | grep -qE '^[A-Za-z][A-Za-z0-9]*-[0-9]+(\.[0-9]+)?$' || {
  echo "Not a Quetrex task id: '$TASK' — expected <CODE>-<number>, or <CODE>-<number>.<child> for an epic child (e.g. DEA-1, DEA-1.2)." >&2; exit 1; }

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
BIND="$REPO_ROOT/.quetrex/project.json"
[ -f "$BIND" ] || { echo "This repo is not linked to a Quetrex project — run /quetrex:init." >&2; exit 1; }
BRANCH_PREFIX="$(quetrex-api json-get "$BIND" branchPrefix 2>/dev/null || echo "claude/")"
[ -n "$BRANCH_PREFIX" ] || BRANCH_PREFIX="claude/"
SLUG="$(git -C "$REPO_ROOT" remote get-url origin | sed -E 's#.*[:/]([^/]+/[^/]+?)(\.git)?$#\1#')"

# Epic or single unit? They merge through the same gate, but their terminus branch and their
# teardown differ: a unit's PR head is `<prefix><TASK>-<slug>`, an epic's is its integration
# branch `<prefix><EPIC>`, and an epic also owns its children's leftover refs (§5d).
TASK_JSON="$(quetrex-api GET "/api/tasks/$TASK" 2>/dev/null || echo '{}')"
IS_EPIC="$(printf '%s' "$TASK_JSON" | node -e '
  let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    let o={}; try{o=JSON.parse(s)||{}}catch{}
    const t=String(o.type||"").toLowerCase();
    const kids=Array.isArray(o.children)?o.children:(Array.isArray(o.childTasks)?o.childTasks:[]);
    process.stdout.write((t==="project"||t==="epic"||kids.length>0)?"1":"0");
  })')"
[ -n "$IS_EPIC" ] || IS_EPIC=0

# Find the open PR whose head branch carries this task id. Matching on the branch rather
# than the title: titles get edited, branch names do not.
PR_JSON="$(gh pr list --repo "$SLUG" --state open --limit 100 \
  --json number,headRefName,headRefOid,title,isDraft,mergeable,mergeStateStatus 2>/dev/null)"
PR="$(printf '%s' "$PR_JSON" | node -e '
  let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    let a; try{a=JSON.parse(s)}catch{process.exit(1)}
    const task=process.argv[1].toLowerCase();
    // WHOLE-SEGMENT match, never a substring. `"claude/qdm-10-manifest".includes("qdm-1")`
    // is TRUE, so the moment a project reaches its tenth task every single-digit id became
    // ambiguous with its tenth sibling — and once the single-digit PR was closed, the
    // matcher silently returned the WRONG PR as its single hit. Require a non-alphanumeric
    // boundary (or the string edge) on BOTH sides: qdm-1 matches claude/qdm-1 and
    // claude/qdm-1-manifest, and does not match claude/qdm-10-manifest.
    //
    // ESCAPE THE ID FIRST. It used to be concatenated straight in, on the claim that a
    // validated id carries no metacharacter. An epic CHILD id does: `qdm-2.1`, where `.`
    // is a regex WILDCARD — unescaped, it matched `claude/qdm-231-manifest` as one
    // confident, unambiguous, WRONG hit. Escaping is what makes accepting the child form
    // safe rather than a silent wrong-PR merge.
    const lit=task.replace(/[.*+?^${}()|[\]\\]/g,"\\$&");
    // `.` IS EXCLUDED FROM THE RIGHT-HAND BOUNDARY, and only there. It is non-alphanumeric,
    // so the old class let a PARENT id select one of its CHILDREN's PRs: qdm-2 matched
    // claude/qdm-2.1-manifest. With the epic's integration PR not yet open and one child
    // PR still open, that is again a single unambiguous hit on the wrong PR. Excluding it
    // means `<EPIC>` only ever matches the epic's own head and `<EPIC>.<n>` only its own —
    // and a child's worktree/refs are torn down by that child's own reap, not the epic's.
    const re=new RegExp("(^|[^a-z0-9])"+lit+"([^a-z0-9.]|$)");
    const hit=a.filter(p=>re.test(String(p.headRefName).toLowerCase()));
    if(hit.length!==1){
      process.stderr.write(hit.length+" candidate(s)\n");
      for(const p of hit) process.stderr.write("  #"+p.number+"  "+p.headRefName+"\n");
      process.exit(2)
    }
    process.stdout.write(JSON.stringify(hit[0]));
  })' "$TASK")" || {
  echo "Could not identify a single open PR for $TASK in $SLUG. List them with: gh pr list --repo $SLUG" >&2
  exit 1
}
PR_NUM="$(printf '%s' "$PR" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).number)))')"
PR_HEAD="$(printf '%s' "$PR" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).headRefName)))')"
PR_SHA="$(printf '%s' "$PR" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).headRefOid)))')"

GATES_BRANCH="${BRANCH_PREFIX}${TASK}-gates"
SPEC_BRANCH="quetrex-spec/${TASK}"

# Rule A: persist everything, because none of it survives to the next Bash call.
mkdir -p "$REPO_ROOT/.quetrex"
{
  printf 'TASK=%q\n'          "$TASK"
  printf 'REPO_ROOT=%q\n'     "$REPO_ROOT"
  printf 'SLUG=%q\n'          "$SLUG"
  printf 'BRANCH_PREFIX=%q\n' "$BRANCH_PREFIX"
  printf 'IS_EPIC=%q\n'       "$IS_EPIC"
  printf 'PR_NUM=%q\n'        "$PR_NUM"
  printf 'PR_HEAD=%q\n'       "$PR_HEAD"
  printf 'PR_SHA=%q\n'        "$PR_SHA"
  printf 'GATES_BRANCH=%q\n'  "$GATES_BRANCH"
  printf 'SPEC_BRANCH=%q\n'   "$SPEC_BRANCH"
} > "$REPO_ROOT/.quetrex/merge-facts.env"

echo "$TASK → PR #$PR_NUM ($PR_HEAD @ ${PR_SHA:0:12})"
echo "repo=$SLUG  gates=$GATES_BRANCH  spec=$SPEC_BRANCH  epic=$IS_EPIC"
```

If zero or several PRs match, stop and show them — the block already printed each candidate's
number and branch on stderr. Never guess which PR a task means.

**Write down the four values that line printed** — `PR_NUM`, `SLUG`, `GATES_BRANCH`,
`SPEC_BRANCH`. §4 and §5d need them as literal text (Rule B).

---

## 2. Bring the gate evidence home

Seven artifacts, not five. The plan (`.quetrex/plan/<TASK>.json`) and the pipeline state
(`.quetrex/state.json`) are gate inputs too: `merge-gate.sh` reads the plan for GATE 5's
file-ownership map and for the architect's `security_review_required` flag, and reads
`state.json` for the task id. Without them every cloud build silently took the gate's
"no plan → skip ownership" branch — a gate that cannot fail is not a gate.

```bash
. "$(git rev-parse --show-toplevel)/.quetrex/merge-facts.env"

git -C "$REPO_ROOT" fetch -q origin "$GATES_BRANCH" 2>/dev/null && GATES_OK=1 || GATES_OK=0

if [ "$GATES_OK" -eq 1 ]; then
  mkdir -p "$REPO_ROOT/.quetrex/plan"
  for f in verify-ledger.jsonl review-verdict.json qa-report.json security-findings.json gates-head state.json; do
    git -C "$REPO_ROOT" show "FETCH_HEAD:.quetrex/$f" > "$REPO_ROOT/.quetrex/$f" 2>/dev/null || rm -f "$REPO_ROOT/.quetrex/$f"
  done
  git -C "$REPO_ROOT" show "FETCH_HEAD:.quetrex/plan/$TASK.json" > "$REPO_ROOT/.quetrex/plan/$TASK.json" 2>/dev/null \
    || rm -f "$REPO_ROOT/.quetrex/plan/$TASK.json"
  GATES_SHA="$(tr -d '[:space:]' < "$REPO_ROOT/.quetrex/gates-head" 2>/dev/null || echo "")"
  echo "Fetched gate evidence from $GATES_BRANCH (pinned to ${GATES_SHA:0:12})"
  [ -s "$REPO_ROOT/.quetrex/plan/$TASK.json" ] \
    && echo "  plan/$TASK.json present — GATE 5 (ownership) and the plan's security_review_required are live" \
    || echo "  NOTE: no plan/$TASK.json on the gates branch — merge-gate.sh will skip GATE 5 (ownership)."
else
  echo "No gates branch ($GATES_BRANCH) — this PR carries no published gate evidence."
fi
```

**Then check the pin yourself, before attempting anything.** The local gate will check it
too; catching it here produces a message that explains what to do instead of a denial:

```bash
. "$(git rev-parse --show-toplevel)/.quetrex/merge-facts.env"
GATES_SHA="$(tr -d '[:space:]' < "$REPO_ROOT/.quetrex/gates-head" 2>/dev/null || echo "")"
if [ -n "$GATES_SHA" ] && [ "$GATES_SHA" != "$PR_SHA" ]; then
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

**If `IS_EPIC=1` and the gates branch is missing, say this instead** — the remedy is
different, and the generic message sends the operator to GitHub for a reason that is not
their fault:

> `<TASK>` is an epic. Its terminus is the integration → main PR #`<n>`
> (`<prefix><TASK>` → `main`), and it needs its own gate evidence on
> `<prefix><TASK>-gates`, pinned to the integration branch's head — the children's
> per-unit evidence pins to the children's own commits and cannot vouch for the
> integration head. Nothing has published it. Re-run the epic's terminus so the epic's
> verify/review/security gates run against `<prefix><TASK>` and publish
> `<prefix><TASK>-gates`, then re-run `/quetrex:merge <TASK>`.

Everything downstream of this point is identical for an epic and a unit: an epic's PR is an
ordinary PR, its evidence is an ordinary gates branch pinned to its head, and `merge-gate.sh`
judges it by exactly the same rules. Only §5d's teardown differs.

---

## 3. Check the PR itself

Artifacts prove our gates; GitHub's own state proves the PR is mergeable at all.

```bash
. "$(git rev-parse --show-toplevel)/.quetrex/merge-facts.env"
PR="$(gh pr view "$PR_NUM" --repo "$SLUG" --json isDraft,mergeable 2>/dev/null)"
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
verdict, the ledger, the security findings and the ownership map against the PR's real head.
That is the decision point. If it denies, **surface its reason verbatim and stop** — it is
reading the same artifacts you just fetched, so its complaint is about the evidence, not
about tooling.

**Rule B applies here.** Take the number and slug §1 printed and type them into the command.
This is a template, not a script to paste:

```text
gh pr merge <PR_NUM> --repo <OWNER/REPO> --squash --delete-branch
```

For PR 97 in `Glori-Holdings/quetrex-base` that is exactly:

```text
gh pr merge 97 --repo Glori-Holdings/quetrex-base --squash --delete-branch
```

Never write `gh pr merge "$PR_NUM" --repo "$SLUG" ...`. The hook is handed that text
unexpanded, cannot resolve `$PR_NUM` to a pull request, fails closed, and denies the merge
with `MERGE GATE (ESCALATE_HUMAN): could not resolve the PR's head commit` — a message about
`gh` authentication for a problem that is purely this command's own phrasing.

`--delete-branch` removes the remote branch and, when the local branch is checked out
nowhere, the local one too.

---

## 5. Finish the job — the part that never used to happen

None of this ran while merges were done by hand, which is why tasks sat in `in_progress`
long after they shipped.

```bash
. "$(git rev-parse --show-toplevel)/.quetrex/merge-facts.env"

# a. The board.
quetrex-api task-status "$TASK" merged && echo "$TASK → merged"

# b. Return to the base branch and fast-forward. `pull --ff-only` is a SYNC, and the merge
#    gate exempts syncing the protected branch from its own upstream.
git -C "$REPO_ROOT" switch -q main 2>/dev/null || git -C "$REPO_ROOT" switch -q master
git -C "$REPO_ROOT" fetch --prune -q origin
git -C "$REPO_ROOT" pull --ff-only -q origin "$(git -C "$REPO_ROOT" branch --show-current)"

# c. Tear down the worktree for this task, if the pipeline made one.
#
# ── quetrex:exec-block qx_remove_task_worktrees ─────────────────────────────
# Executable, and executed: test/merge-child-ids.test.sh drives this function
# against real `git worktree`s holding real uncommitted files.
#
# WHY A BOUNDED MATCH, AND WHY IT IS NOT A NICETY. This used to be
# `case "$wt" in *"$TASK"*)` — an UNBOUNDED SUBSTRING. `/quetrex:merge QDM-1`
# therefore force-removed the worktrees of QDM-10, QDM-100 and QDM-1.2 along
# with its own, and `--force` is exactly the flag that overrides git's refusal
# to delete a worktree containing modified or untracked files. Merging one task
# silently destroyed another task's in-progress work, with no prompt and no
# recovery — the destructive twin of the wrong-PR match §1 fixes.
#
# The rule is the same one §1's matcher uses, so an id can never reach into a
# longer id or into one of its own children:
#   - left  boundary: a non-alphanumeric character, or the start of the path;
#   - right boundary: a character that is neither alphanumeric NOR `.`, or the
#     end of the path. Excluding `.` is what stops the epic QDM-2 from taking
#     child QDM-2.1's worktree; each child is torn down by its own reap.
# Every pattern quotes "$task", so the `.` in a child id is a literal here too,
# not a glob wildcard.
#
# The MAIN checkout is never a candidate. `git worktree list` puts it first,
# and the operator's own repo directory may perfectly well be named after a
# task (…/QDM-7-app); attempting to remove it fails harmlessly today, but not
# offering it as a candidate at all is the honest way to say "never".
qx_remove_task_worktrees() {   # qx_remove_task_worktrees <repo-root> <task-id>
  local root="$1" task="$2" main_wt wt
  main_wt="$(git -C "$root" worktree list --porcelain | sed -n 's/^worktree //p' | head -1)"
  git -C "$root" worktree list --porcelain | sed -n 's/^worktree //p' | while IFS= read -r wt; do
    [ -n "$wt" ] && [ "$wt" != "$main_wt" ] || continue
    case "$wt" in
      "$task"|"$task"[!A-Za-z0-9.]*|*[!A-Za-z0-9]"$task"|*[!A-Za-z0-9]"$task"[!A-Za-z0-9.]*)
        git -C "$root" worktree remove "$wt" --force 2>/dev/null && echo "removed worktree $wt" ;;
    esac
  done
  git -C "$root" worktree prune
}
# ── end quetrex:exec-block qx_remove_task_worktrees ─────────────────────────
qx_remove_task_worktrees "$REPO_ROOT" "$TASK"

# Print the refs §5d has to delete, so their names can be typed in literally.
echo "delete locally : $PR_HEAD  $GATES_BRANCH  $SPEC_BRANCH"
echo "delete on origin: $GATES_BRANCH  $SPEC_BRANCH"
if [ "$IS_EPIC" = "1" ]; then
  node -e '
    const fs=require("fs");
    const p=process.argv[1]+"/.quetrex/build/"+process.argv[2]+".json";
    let o={}; try{o=JSON.parse(fs.readFileSync(p,"utf8"))}catch{ process.exit(0) }
    const ids=(o.children||[]).map(c=>c.id).filter(Boolean);
    if(ids.length) console.log("epic children (also delete their refs): "+ids.join(" "));
  ' "$REPO_ROOT" "$TASK"
fi
```

### 5d. Delete the branches — spelled out, never in a variable

Three refs outlive the merge and all three are ours to remove: the unit/integration branch,
the **gates** branch, and the **spec** branch (`quetrex-spec/<TASK>` — the throwaway branch
§6A of `/quetrex:task-build` pushed carrying the approved plan). The spec branch was never
deleted by anything in the engine, so every task ever built left one behind on the customer's
origin, permanently, carrying that task's acceptance criteria, ownership map and security
surface. Leaving them is the exact dangling-branch failure the worktree-workflow doctrine
forbids.

**Rule B applies here too, and there are two separate reasons:**

- `deny-guard.sh` and `enforce-branch.sh` read this text before expansion — a branch name
  hiding inside `"$GATES_BRANCH"` is unreadable to them, so the carve-outs that permit
  deleting a `quetrex-spec/*` ref cannot recognise it.
- `git push origin --delete <branch>` is **denied outright** here: §5b just switched the
  checkout to `main`, and `enforce-branch.sh` blocks every `git push` made while on
  `main`/`master`. That is why the remote deletes below go through `gh api` — a REST ref
  delete, not a push — which both hooks allow. (The old `git push --delete` spelling meant
  the gates branch was never actually removed either.)

Type each branch name in. For task `DEA-1` on `Glori-Holdings/quetrex-base` with prefix
`claude/` and PR head `claude/DEA-1-manifest`, the four calls are exactly:

```text
git -C <REPO_ROOT> branch -D claude/DEA-1-manifest
git -C <REPO_ROOT> branch -D claude/DEA-1-gates
gh api --method DELETE repos/Glori-Holdings/quetrex-base/git/refs/heads/claude/DEA-1-gates
gh api --method DELETE repos/Glori-Holdings/quetrex-base/git/refs/heads/quetrex-spec/DEA-1
```

Each may legitimately fail — the local branch may never have existed, `--delete-branch`
may already have taken the head branch, a ref may already be gone. Run them all, ignore a
404/"not found", and report anything else that did not clean up rather than leaving it
silent.

**For an epic**, run the same two `gh api` deletes for **every child id** the block above
printed (`quetrex-spec/<child>` and `<prefix><child>-gates`), plus the epic's own integration
branch — again with each name typed in literally.

### 5e. Drop the transported artifacts

```bash
. "$(git rev-parse --show-toplevel)/.quetrex/merge-facts.env"
# The fetched artifacts described a branch that no longer exists. Leaving them behind is
# how a stale verdict ends up denying an unrelated merge days later. The plan and state
# came home with them in §2 and go the same way.
rm -f "$REPO_ROOT/.quetrex/review-verdict.json" "$REPO_ROOT/.quetrex/qa-report.json" \
      "$REPO_ROOT/.quetrex/security-findings.json" "$REPO_ROOT/.quetrex/verify-ledger.jsonl" \
      "$REPO_ROOT/.quetrex/gates-head" "$REPO_ROOT/.quetrex/state.json" \
      "$REPO_ROOT/.quetrex/plan/$TASK.json" "$REPO_ROOT/.quetrex/merge-facts.env"
```

---

## 6. Report

- **PR** — number, title, the commit that merged.
- **Evidence** — which gate artifacts backed it (including whether the plan came home, and
  so whether GATE 5's ownership check was live), and the sha they were pinned to.
- **Board** — `<TASK>` → `merged`.
- **Cleanup** — unit/integration branch, gates branch, spec branch and worktree removed;
  base branch fast-forwarded. Name anything that did not delete.
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
- Never put a PR number, repo slug or branch name behind a `$` in a command a hook has to
  read (§0 Rule B). Every one of those denials looks like a tooling failure and is not.
