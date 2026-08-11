---
description: Discuss why a failed Quetrex task didn't pass, agree a fix plan, apply non-blocking nits with /code-review --fix instead of rebuilding for them, then re-queue and re-fire the build as a cloud routine (off the epic integration branch for a child). Usage: /quetrex:task-rework SMA-1
argument-hint: <TASK-ID like SMA-1>
---

# Rework

Take a task that came back from the pipeline (typically `needs_clarity`), understand **why it
failed**, **discuss the fix with the user until you are confident it will work**, write the agreed
plan to the kanban, re-queue the task, and **re-fire the build as a cloud Routine** — the same
`RemoteTrigger` dispatch `/quetrex:task-build` Step 6A makes, carrying the same self-contained
prompt (`.claude/lib/cloud-build-routine.md`), which runs THE DEV PIPELINE defined once in
`.claude/lib/dev-pipeline.md` and **not restated here**.

**The build never runs on this machine.** Compute runs on Anthropic's servers, so closing the lid
cannot strand a rework, and — the part that used to be silently broken — the run publishes its gate
evidence to `<prefix><TASK>-gates`. `/quetrex:merge` fetches that branch and `merge-gate.sh` needs
what it carries: an `AUTO_MERGE` verdict pinned to the PR head plus a green ledger for that same
commit. A rework built locally produces neither where the gate looks, so its PR can never merge.
This command is therefore intake + discussion + **cloud re-dispatch**; nothing heavy happens here
and the terminal stays free.

All kanban I/O goes through the token-safe `quetrex-api` tool (shipped on the plugin's PATH —
raw `quetrex-api <METHOD> <path> [body]` calls plus the `quetrex-api task-*` subcommands): never
echo the token, never `set -x` / `curl -v` around `quetrex-api`, always build JSON with
`node` / `JSON.stringify`.

Argument: `$ARGUMENTS` is a single human task identifier, e.g. `SMA-1`. Works on **any** single
unit — standalone task or epic child. Not on an epic **parent**: rework the child that failed,
then re-run `/quetrex:task-build <EPIC-ID>` to drain the rest of the DAG.

---

## Step 1 — Parse, resolve, fetch context

```bash
TASK_ID="$(echo "$ARGUMENTS" | tr -d '[:space:]')"
```

If `TASK_ID` is empty, print usage and stop:

> Usage: `/quetrex:task-rework SMA-1`

Resolve context in one bash block — the `quetrex-api` tool (shipped on the plugin's PATH) owns
all auth/access messaging; do not reinvent it:

```bash
QX_KANBAN_URL="$(quetrex-api kanban-url)"     || exit 1   # prints "Run /quetrex:login" on failure
QX_PROJECT_CODE="$(quetrex-api project-code)" || exit 1   # prints "Run /quetrex:init" on failure
quetrex-api GET "/api/projects/$QX_PROJECT_CODE" >/dev/null || exit 1   # validate access
TASK="$(quetrex-api GET "/api/tasks/$TASK_ID")"            || exit 1

REPO_ROOT="$(git rev-parse --show-toplevel)"
# Branch prefix: NEVER hardcode one. It is data, read from .quetrex/project.json.
# The default is "claude/" — the only prefix an Anthropic cloud routine can push to
# without a repo admin loosening the branch restriction first.
BRANCH_PREFIX="$(quetrex-api json-get "$REPO_ROOT/.quetrex/project.json" branchPrefix 2>/dev/null || echo 'claude/')"
[ -n "$BRANCH_PREFIX" ] || BRANCH_PREFIX="claude/"

echo "Project: $QX_PROJECT_CODE @ $QX_KANBAN_URL   branchPrefix=$BRANCH_PREFIX"
```

If any context fetch or `quetrex-api` call exits non-zero, the tool already printed the correct message
(401 → `Run /quetrex:login`; 403/404 → `No access — contact your administrator`; other →
`Quetrex API error (HTTP <code>)`). Just stop.

### 1a. Resolve the cloud environment — before the discussion, not after it

The re-dispatch in Step 4 fires into the operator's **own** Claude Code cloud environment, and that
id is data exactly like `branchPrefix` — read from the repo binding, never a literal. Resolve it
now, using **task-build.md's `qx_cloud_env_id` block** (Step 1a there; it is the single definition
and is not restated here), so a missing binding costs one line of setup instead of a whole rework
conversation:

```bash
QX_CLOUD_ENV_ID="$(qx_cloud_env_id "$REPO_ROOT")" || exit 1
```

Read the fields from `$TASK` — including the **AI-notes** the engine left on failure. Read the
**identifier fields** too: they are what Step 4a resolves the base branch from, and the parent
link is **not** what its name suggests (see 4a):

```bash
node -e '
  let o; try{o=JSON.parse(process.argv[1])}catch{process.exit(1)}
  const g=k=>o[k]==null?"":String(o[k]);
  console.log(["status="+g("status"),"type="+g("type"),"title="+g("title"),
               "identifier="+g("identifier"),
               "parentIdentifier="+g("parentIdentifier"),
               "parentTaskId(UUID)="+g("parentTaskId"),
               "childNumber="+g("childNumber"),
               "---AI-NOTES---",g("aiNotes")].join("\n"));
' "$TASK"
```

Read the recent discussion the same way — comments ship **inside** `$TASK` (the task GET already
embeds them), and the engine posts the failure reason as a comment too:

```bash
node -e '
  let o; try{o=JSON.parse(process.argv[1])}catch{o={}}
  const list=Array.isArray(o.comments)?o.comments:(o.data||[]);
  for(const c of list.slice(-15))
    console.log("• ["+(c.createdAt||"")+"] "+String(c.body||c.text||"").trim());
' "$TASK"
```

**Discover the failed branch / PR.** The engine names the unit branch
`${BRANCH_PREFIX}<TASK_ID>-<slug>`, so match the **whole token** — `SMA-1` must not match
`SMA-12`:

```bash
# Whole-token match: branch is exactly <prefix>SMA-1 or starts with <prefix>SMA-1-<slug>.
gh pr list --state all --json number,headRefName,state,url \
  --jq ".[] | select(.headRefName == \"${BRANCH_PREFIX}$TASK_ID\" or (.headRefName | startswith(\"${BRANCH_PREFIX}$TASK_ID-\")))" \
  2>/dev/null || true
```

**Keep the branch name it printed** as `UNIT_BRANCH` — Step 4 pins the approved base against it,
and the cloud routine **resumes** it rather than starting over, so the existing PR is updated
instead of a second one being opened. If nothing matched (the failed run never pushed), set
`UNIT_BRANCH="-"`.

If a PR is found, read its diff for grounding (`gh pr diff <number>`); if only a branch exists,
inspect it with `git diff main...${BRANCH_PREFIX}$TASK_ID-<slug>`. Then **read the relevant repo
code** (Glob / Grep / Read) around the changed surface so your explanation and fix plan are
grounded in reality, not just the notes.

**State warning (non-blocking).** `/quetrex:task-rework` expects a task in a rework-expecting state —
canonically `needs_clarity`. If `status` is something else (e.g. `pr_ready`, `merged`, `deployed`,
`complete`, `backlog`, `queued`, or already `in_progress`), **warn clearly**:

> ⚠️ `SMA-1` is in `<status>`, not `needs_clarity` — `/quetrex:task-rework` is meant for tasks the pipeline sent
> back. Re-running may duplicate in-flight or finished work. Do you want to continue anyway?

and **wait for the user to confirm** before proceeding. Do not auto-continue.

---

## Step 2 — Explain WHY it failed, then DISCUSS

- **Explain to the user why it failed**, grounded in the AI-notes, the comments, the PR/branch
  diff, and the code you read. Be concrete: which acceptance criterion went unmet, which QA exit
  code was non-zero, which reviewer/security finding blocked, or what ambiguity stalled it.
- **Discuss the fix interactively.** Propose a fix plan, then iterate with the user — ask sharp
  questions on any genuine gap, fold in their answers, and refine — until **you are confident the
  fix will actually work**. Do **not** jump straight to re-dispatching. This discussion is
  the whole point of `/quetrex:task-rework`; a re-run without a corrected, agreed plan will just fail again.

**This discussion IS the scope gate.** `/quetrex:task-build` refuses to build a payload with no
`scopeApprovedAt`, and Step 4c stamps one — because the human just approved this scope, in this
conversation, sentence by sentence. That stamp is legitimate **only** after the agreement in this
step actually happened. Never stamp it to get moving.

---

## Step 2b — Nit fast path (`/code-review --fix`) — before you re-dispatch anything

Most reworks carry a mix: one real defect plus a handful of naming / minor-style /
opportunistic-cleanup findings. `reviewer.md` calls those **non-blocking quality nits** and
they explicitly do **not** block `AUTO_MERGE`. Spinning a full rebuild for them — or
letting them consume a `review_iter` on the next pass — is waste. Handle them here.

**1. Triage every finding into two tiers.**

| Tier | What it is |
|---|---|
| **BLOCKING** | correctness, security, an architecture / file-ownership violation, a red verify command, an unmet acceptance criterion |
| **NIT** | naming, minor style, dead code, opportunistic cleanup — anything the reviewer itself would report without blocking |

**When in doubt it is BLOCKING.** Never downgrade a finding to NIT to reach the fast path;
that is the one way this step can do damage.

**2. Apply the nit tier locally** in the failed unit's worktree — a working-tree edit, no
rebuild:

```bash
/code-review --fix
```

Review what it changed before accepting it; `--fix` is a convenience, not an authority.

**3. Commit and PUSH the nit fixes onto the existing unit branch**, using the
`worktree-workflow` skill's `git -C <path>` form so the enforce-branch hook sees the branch.
Pushing is not optional: the cloud run in Step 4 **resumes** `UNIT_BRANCH` from its pushed tip
(`quetrex-cloud-prep sync`, which never rebases and never force-pushes), so anything left
uncommitted or unpushed here is simply not part of the rework.

**4. Then go to Step 3 — always.** What the triage changes is the *content* of the agreed note
in Step 3, not *where the gates run*:

- **Any BLOCKING finding** → the note names the defect to fix. The nit fixes ride along in the
  same run, so the rebuilt change does not re-surface them and the reviewer spends its
  iteration on the real defect.
- **Zero BLOCKING findings** (the whole rework was trivia) → the note says exactly that: the
  code is already correct, the nits are applied and pushed, and what this run must do is
  **re-run the gates against the new HEAD**. The cloud stages find the work already committed
  (hardening rule 4) and spend the run on the verify chain and a fresh reviewer pass.

**There is no local-gate fast path, and its absence is the fix, not an oversight.** HEAD moved,
so `merge-gate.sh` needs a green ledger *and* an `AUTO_MERGE` verdict whose `.sha` equals the new
HEAD. Running those gates on this laptop produces both — **somewhere `/quetrex:merge` never
looks.** `/quetrex:merge` §2 fetches `<prefix><TASK>-gates` and overwrites (or `rm -f`s) the local
`.quetrex/` copies with whatever that branch carries, which is still the *failed* run's evidence
pinned to the *old* sha; the merge is then correctly refused as STALE EVIDENCE for a PR that was
in fact repaired. Only the cloud routine's step 5b republishes that branch. So the gates re-run in
cloud, on the same dispatch as everything else — one path, and the evidence lands where the gate
reads it.

---

## Step 3 — Persist the agreed plan + re-queue

Once you and the user agree on the fix, record it on the kanban and move the task to `queued` so
the re-dispatch starts from a clean state:

```bash
quetrex-api task-comment "$TASK_ID" "REWORK PLAN (agreed):
<the concrete, agreed fix plan — what changes, why it addresses the failure, and the acceptance
criteria it must now satisfy>"
# Optional: also append an AI-note so the failure→fix trail lives on the record.
quetrex-api task-ainote "$TASK_ID" "Rework re-queued: <one-line summary of the agreed fix>"
quetrex-api task-status "$TASK_ID" queued
```

**Write the same agreed text to a file** — Step 4c folds it into the plan the cloud session reads.
That is the only channel it has: the routine is explicitly forbidden to call the kanban API
("Do NOT depend on cloud board-MCP" — `.claude/lib/cloud-build-routine.md`), so a fix plan that
exists only as a board comment never reaches the session that has to implement it.

```bash
REWORK_NOTE="$REPO_ROOT/.quetrex/rework-$TASK_ID.md"
mkdir -p "$REPO_ROOT/.quetrex"
cat > "$REWORK_NOTE" <<'EOF'
<the SAME agreed fix plan text you just posted as the kanban comment>
EOF
```

---

## Step 4 — Re-dispatch the build as a CLOUD ROUTINE

Four small resolutions, then **task-build.md Step 6A verbatim**. Nothing below rebuilds anything
locally and nothing below re-plans: the architect's ownership map is the one the human already
approved, plus the fix agreed in Step 2.

### 4a. Resolve what is being reworked, and where its PR goes

```bash
# ── quetrex:exec-block qx_rework_target ───────────────────────────────────────
# Executable, and executed: test/rework-cloud.test.sh sources this exact block
# and drives it over standalone tasks, epic children and epic parents. Pure
# function of (task JSON, branch prefix) — no network, no kanban call.
#
# Prints exactly three lines and returns 0 when the task is reworkable:
#     KIND=single|child
#     BASE=<the branch this unit's PR targets>
#     EPIC=<the epic identifier, or "-">
# Returns 1 with the reason on stderr when it is not.
#
# WHY THE EPIC IS NOT READ OUT OF `parentTaskId`. The kanban DTO
# (quetrex-kanban, src/lib/dto.ts serializeTask) emits `parentTaskId` as the
# parent's **UUID** and puts the human form in `parentIdentifier`
# (`${code}-${number}`), while the child's own `identifier` is `CODE-N.C`
# (childIdent()). `${BRANCH_PREFIX}${parentTaskId}` therefore names
# `claude/9f3c8e21-…`, a branch no epic ever had: the child would PR into a
# branch of its own invention and its work would never reach the integration
# branch. The epic id comes from `parentIdentifier`, or is derived from the
# child's own CODE-N.C identifier; a UUID is never used as one.
qx_rework_target() {           # qx_rework_target <task-json> <branch-prefix>
  local task="$1" prefix="${2:-}"
  [ -n "$prefix" ] || prefix="claude/"
  node -e '
    const [raw, prefix] = process.argv.slice(1);
    let o; try { o = JSON.parse(raw); }
    catch (e) { console.error("the task JSON did not parse — nothing to rework"); process.exit(1); }
    const S = v => (v == null ? "" : String(v).trim());
    // CODE-N (top-level) or CODE-N.C (epic child) — the identifier grammar
    // quetrex-kanban parses in src/lib/task-ref.ts (IDENTIFIER_RE).
    const IDENT = /^([A-Za-z][A-Za-z0-9]*-\d+)(?:\.(\d+))?$/;
    const self = S(o.identifier);
    const selfM = IDENT.exec(self);
    const parentIdent = S(o.parentIdentifier);
    const parentRaw = S(o.parentTaskId);
    const kids = Array.isArray(o.children) ? o.children.length
               : Array.isArray(o.childTasks) ? o.childTasks.length : 0;
    if (kids > 0) {
      console.error("EPIC PARENT (" + kids + " children): /quetrex:task-rework reworks ONE unit and would dispatch a single routine for the whole epic.");
      console.error("Rework the child that failed, then re-run /quetrex:task-build " + (self || "<EPIC-ID>") + " to resume the dispatcher and drain the DAG.");
      process.exit(1);
    }
    const isChild = !!parentRaw || !!parentIdent || o.childNumber != null
                 || (selfM && selfM[2] != null);
    if (!isChild) {
      console.log("KIND=single"); console.log("BASE=main"); console.log("EPIC=-");
      process.exit(0);
    }
    let epic = "";
    if (IDENT.test(parentIdent)) epic = parentIdent;        // the human form the API ships
    else if (selfM && selfM[2] != null) epic = selfM[1];    // CODE-N.C -> CODE-N
    else if (IDENT.test(parentRaw)) epic = parentRaw;       // legacy: a human id in parentTaskId
    if (!epic) {
      console.error("This task is a child (parentTaskId=" + (parentRaw || "?") + ") but nothing on the record yields the EPIC identifier:");
      console.error("parentIdentifier is empty and its own identifier (" + (self || "empty") + ") is not CODE-N.C.");
      console.error("parentTaskId is a UUID, never a branch name — refusing to invent an integration branch from it.");
      process.exit(1);
    }
    console.log("KIND=child");
    console.log("BASE=" + prefix + epic);
    console.log("EPIC=" + epic);
  ' "$task" "$prefix"
}
# ── end quetrex:exec-block qx_rework_target ───────────────────────────────────

eval "$(qx_rework_target "$TASK" "$BRANCH_PREFIX" | sed 's/^/QX_/')" || exit 1
BASE_BRANCH="$QX_BASE"
echo "Rework target: $TASK_ID  kind=$QX_KIND  base=$BASE_BRANCH  epic=$QX_EPIC"
```

A **standalone** task PRs into `main`. An **epic child** PRs into the epic's integration branch
`${BRANCH_PREFIX}<EPIC-ID>` — never `main`. On pass it auto-merges into that integration branch and
**unblocks** its dependents; unblocking only flips their readiness, it does not dispatch them, so
the user then re-runs `/quetrex:task-build <EPIC-ID>` to resume the DAG dispatcher (the epic stays
`in_progress`). Surface that next step in the report.

### 4b. Recover the approved plan

The cloud session reads one artifact and nothing else: `.quetrex/plan/<TASK>.json`, delivered on
the spec branch. A rework does not re-run the architect, so that plan has to be **found**, and
where it lives depends on how the task was built:

```bash
# ── quetrex:exec-block qx_rework_plan_source ──────────────────────────────────
# Executable, and executed: test/rework-cloud.test.sh drives every branch of
# this against a real repo with a bare remote.
#
# Writes the recovered plan to <out-file>, prints PLAN_SOURCE=<where>, and
# returns 1 when no source yields a usable plan.
#
# "Usable" is not "parses": the cloud routine's step 2 validates that the plan
# names a NON-EMPTY `ownership` map and aborts as transport_failure without
# one. Checking it here costs nothing; checking it there costs a whole cloud
# run to learn the same fact.
#
# FOUR SOURCES, in order of authority. An epic CHILD is why there are four:
# children never get a payload of their own — task-build.md 4a writes ONE
# payload per epic and keeps each child's plan in `children[].plan` — so
# source 1 always misses for a child and source 2 is the one that hits.
qx_rework_plan_source() {   # qx_rework_plan_source <repo-root> <task-id> <epic-id|-> <branch-prefix> <out-file>
  local root="$1" task="$2" epic="${3:--}" prefix="${4:-claude/}" out="$5"
  local cand="$out.candidate" b

  _qx_rework_usable_plan() {   # _qx_rework_usable_plan <candidate> <out>
    node -e '
      const fs=require("fs"); const [i,o]=process.argv.slice(1);
      let p; try{ p=JSON.parse(fs.readFileSync(i,"utf8")); }catch(e){ process.exit(1); }
      if(!p || typeof p!=="object" || Array.isArray(p)) process.exit(1);
      const own=p.ownership;
      if(!own || typeof own!=="object" || Array.isArray(own) || !Object.keys(own).length) process.exit(1);
      fs.writeFileSync(o, JSON.stringify(p,null,2)+"\n");
    ' "$1" "$2"
  }

  # 1. this task's own build payload (a standalone unit always has one)
  if [ -f "$root/.quetrex/build/$task.json" ]; then
    if node -e '
        const fs=require("fs"); const [f,o]=process.argv.slice(1);
        let p; try{ p=JSON.parse(fs.readFileSync(f,"utf8")); }catch(e){ process.exit(1); }
        if(!p.planSnapshot) process.exit(1);
        fs.writeFileSync(o, JSON.stringify(p.planSnapshot,null,2)+"\n");
      ' "$root/.quetrex/build/$task.json" "$cand" && _qx_rework_usable_plan "$cand" "$out"; then
      rm -f "$cand"; printf 'PLAN_SOURCE=payload:.quetrex/build/%s.json\n' "$task"; return 0
    fi
  fi

  # 2. the EPIC payload's children[] — where an epic child's approved plan lives
  if [ "$epic" != "-" ] && [ -n "$epic" ] && [ -f "$root/.quetrex/build/$epic.json" ]; then
    if node -e '
        const fs=require("fs"); const [f,id,o]=process.argv.slice(1);
        let p; try{ p=JSON.parse(fs.readFileSync(f,"utf8")); }catch(e){ process.exit(1); }
        const c=(p.children||[]).find(x=>x && String(x.id)===id);
        if(!c || !c.plan) process.exit(1);
        fs.writeFileSync(o, JSON.stringify(c.plan,null,2)+"\n");
      ' "$root/.quetrex/build/$epic.json" "$task" "$cand" && _qx_rework_usable_plan "$cand" "$out"; then
      rm -f "$cand"; printf 'PLAN_SOURCE=epic-payload:.quetrex/build/%s.json\n' "$epic"; return 0
    fi
  fi

  # 3/4. the two disposable branches the failed run left on origin: its published
  #      gate evidence carries the plan (cloud-build-routine.md step 5b stages
  #      .quetrex/plan/<TASK>.json), and so does the spec branch that fired it.
  for b in "${prefix}${task}-gates" "quetrex-spec/$task"; do
    git -C "$root" fetch --quiet --no-tags origin "$b" >/dev/null 2>&1 || continue
    git -C "$root" show "FETCH_HEAD:.quetrex/plan/$task.json" > "$cand" 2>/dev/null || continue
    if _qx_rework_usable_plan "$cand" "$out"; then
      rm -f "$cand"; printf 'PLAN_SOURCE=branch:%s\n' "$b"; return 0
    fi
  done

  rm -f "$cand"
  echo "No approved plan with a non-empty ownership map could be recovered for $task." >&2
  echo "Looked in: .quetrex/build/$task.json, .quetrex/build/$epic.json (children[]), origin/${prefix}${task}-gates, origin/quetrex-spec/$task." >&2
  echo "Nothing here may invent one — run /quetrex:task-build $task to re-plan and re-approve the scope." >&2
  return 1
}
# ── end quetrex:exec-block qx_rework_plan_source ──────────────────────────────

REWORK_PLAN="$REPO_ROOT/.quetrex/rework-plan-$TASK_ID.json"
qx_rework_plan_source "$REPO_ROOT" "$TASK_ID" "$QX_EPIC" "$BRANCH_PREFIX" "$REWORK_PLAN" || exit 1
```

### 4c. Pin the approved base, then write the build payload

```bash
# ── quetrex:exec-block qx_rework_base_sha ─────────────────────────────────────
# Executable, and executed: test/rework-cloud.test.sh drives this against a real
# origin whose base branch has moved on, and then feeds the result to the REAL
# `quetrex-cloud-prep sync` to prove the chosen sha is one that syncs.
#
# Prints the sha to pin as the payload's approvedBaseSha.
#
# WHY THIS EXISTS AT ALL. `quetrex-cloud-prep sync` asks the ancestry question
# TWICE: the approved sha must be an ancestor of origin/<base>, AND — when the
# unit branch already exists on origin, which after a failed build it always
# does — an ancestor of that branch's tip, since the run RESUMES it and never
# rebases it. A rework that pinned the live tip of origin/<base> would satisfy
# the first and fail the second the moment anything else merged: exit 3,
# transport_failure, forever, for the one command whose entire job is recovery.
#   - a sha already pinned by the original dispatch satisfies both by
#     construction, so it is reused (this is also the correct semantics: the
#     human approved a scope against a snapshot);
#   - otherwise the merge-base of the failed branch and the base branch is the
#     newest commit that is provably an ancestor of both;
#   - with no unit branch (the failed run never pushed) there is nothing to
#     resume and the live base tip is right.
qx_rework_base_sha() {   # qx_rework_base_sha <repo-root> <base-branch> <unit-branch|-> <prev-sha|->
  local root="$1" base="$2" unit="${3:--}" prev="${4:--}" base_tip="" unit_ref="" sha=""
  git -C "$root" fetch -q --no-tags origin "+refs/heads/$base:refs/remotes/origin/$base" 2>/dev/null \
    || { echo "cannot fetch origin/$base — refusing to pin a base nobody can see" >&2; return 1; }
  base_tip="$(git -C "$root" rev-parse -q --verify "refs/remotes/origin/$base^{commit}" 2>/dev/null)" || base_tip=""
  [ -n "$base_tip" ] || { echo "origin/$base does not resolve to a commit" >&2; return 1; }
  if [ -n "$unit" ] && [ "$unit" != "-" ]; then
    if git -C "$root" fetch -q --no-tags origin "+refs/heads/$unit:refs/remotes/origin/$unit" 2>/dev/null; then
      unit_ref="$(git -C "$root" rev-parse -q --verify "refs/remotes/origin/$unit^{commit}" 2>/dev/null)" || unit_ref=""
    fi
  fi
  _qx_rework_base_ok() {   # <sha> — ancestor of the base, and of the resume point when there is one
    git -C "$root" cat-file -e "$1^{commit}" 2>/dev/null || return 1
    git -C "$root" merge-base --is-ancestor "$1" "$base_tip" || return 1
    [ -z "$unit_ref" ] || git -C "$root" merge-base --is-ancestor "$1" "$unit_ref" || return 1
    return 0
  }
  if [ -n "$prev" ] && [ "$prev" != "-" ] && _qx_rework_base_ok "$prev"; then
    printf '%s\n' "$prev"; return 0
  fi
  if [ -n "$unit_ref" ]; then
    sha="$(git -C "$root" merge-base "$unit_ref" "$base_tip" 2>/dev/null)" || sha=""
    if [ -n "$sha" ] && _qx_rework_base_ok "$sha"; then printf '%s\n' "$sha"; return 0; fi
    echo "the failed branch $unit and origin/$base share no common commit — this branch was not built from that base; rework cannot resume it" >&2
    return 1
  fi
  printf '%s\n' "$base_tip"
}
# ── end quetrex:exec-block qx_rework_base_sha ─────────────────────────────────

PAYLOAD="$REPO_ROOT/.quetrex/build/$TASK_ID.json"
PREV_SHA="$(quetrex-api json-get "$PAYLOAD" approvedBaseSha 2>/dev/null || true)"
[ -n "$PREV_SHA" ] || PREV_SHA="-"
APPROVED_BASE_SHA="$(qx_rework_base_sha "$REPO_ROOT" "$BASE_BRANCH" "${UNIT_BRANCH:--}" "$PREV_SHA")" || exit 1
```

Now write the payload `/quetrex:task-build` Step 5 and Step 6A read. It is the **same artifact in
the same place and the same shape** as task-build.md 4a writes — that is what lets Step 6A be
reused verbatim instead of re-implemented here:

```bash
# ── quetrex:exec-block qx_rework_payload ──────────────────────────────────────
# Executable, and executed: test/rework-cloud.test.sh runs this and then feeds
# the payload it produces to the REAL gate node-snippets extracted out of
# task-build.md (Step 5's scopeApprovedAt refusal and Step 6A's planSnapshot
# extraction), so the two files cannot drift apart silently.
#
# THE AGREED FIX HAS TO TRAVEL IN THE PLAN. The cloud session is forbidden to
# call the kanban ("Do NOT depend on cloud board-MCP"), so a fix plan that
# lives only in a board comment reaches nobody and the routine faithfully
# rebuilds the thing that already failed. It is written into `rework` for
# machines AND into `notes[0]` + `summary` — the two fields every stage of
# dev-pipeline.md already reads — so no downstream agent has to know the
# `rework` key exists.
qx_rework_payload() {   # qx_rework_payload <payload> <task> <title> <base-branch> <prefix> <plan-file> <note-file> <approved-base-sha>
  node -e '
    const fs=require("fs"), path=require("path");
    const [file,task,title,base,prefix,planFile,noteFile,baseSha]=process.argv.slice(1);
    let plan; try{ plan=JSON.parse(fs.readFileSync(planFile,"utf8")); }
    catch(e){ console.error("the recovered plan did not parse: "+planFile); process.exit(1); }
    const own=plan.ownership;
    if(!own || typeof own!=="object" || Array.isArray(own) || !Object.keys(own).length){
      console.error("the recovered plan names no ownership map — the cloud routine aborts as transport_failure without one");
      process.exit(1);
    }
    let note=""; try{ note=fs.readFileSync(noteFile,"utf8"); }catch(e){}
    if(!note.trim()){
      console.error("no agreed rework note at "+noteFile+" — Step 2 has not happened; refusing to re-dispatch a rework with no fix in it");
      process.exit(1);
    }
    note=note.replace(/\s+$/,"");
    let prev={}; try{ prev=JSON.parse(fs.readFileSync(file,"utf8")); }catch(e){}
    const now=new Date().toISOString();
    const iter=(Number(plan.rework && plan.rework.iteration)||0)+1;
    plan.rework={ iteration:iter, agreedAt:now, note };
    const oneLine=note.replace(/[\r\n]+/g," ").replace(/\s+/g," ").trim();
    plan.notes=(Array.isArray(plan.notes)?plan.notes:[])
      .filter(n=>!/^REWORK #\d+ /.test(String(n)));           // supersede, never stack
    plan.notes.unshift("REWORK #"+iter+" ("+now+"): "+oneLine);
    plan.summary="REWORK #"+iter+" — "+String(plan.summary==null?"":plan.summary)
      .replace(/^REWORK #\d+ — /,"");
    const out={
      task, title,
      kind:"single",                    // a rework rebuilds ONE unit; a child is a unit whose
                                        // base happens to be its epic integration branch
      branchPrefix:prefix,
      baseBranch:base,
      integrationBranch:null,
      planPath:".quetrex/plan/"+task+".json",
      worktreePath:prev.worktreePath||null,
      planSnapshot:plan,
      sessionId:null,                   // never resume the failed build session
      scopeApprovedAt:now,              // the Step 2 dialog IS the gate — see Step 2
      scopeApprovedBy:"task-rework",
      approvedBaseSha:(baseSha && baseSha!=="-") ? baseSha : (prev.approvedBaseSha||null),
      dispatch:null,                    // cleared: 6A writes the new record after it fires,
                                        // and a stale one reads as "a run is in flight"
      children:[], edges:[], edgeIds:[], childDispatch:{},
      concurrencyCap:prev.concurrencyCap||4,
      tickIntervalMinutes:prev.tickIntervalMinutes||3,
      rework:{ iteration:iter, agreedAt:now, previousDispatch:prev.dispatch||null }
    };
    fs.mkdirSync(path.dirname(file),{recursive:true});
    fs.writeFileSync(file, JSON.stringify(out,null,2)+"\n");
    console.log("PAYLOAD="+file);
    console.log("REWORK_ITERATION="+iter);
    console.log("BASE_BRANCH="+base);
    console.log("APPROVED_BASE_SHA="+(out.approvedBaseSha||"-"));
  ' "$@"
}
# ── end quetrex:exec-block qx_rework_payload ──────────────────────────────────

TASK_TITLE="$(node -e '
  let o; try{o=JSON.parse(process.argv[1])}catch{process.exit(1)}
  process.stdout.write(o.title==null?"":String(o.title));
' "$TASK")" || exit 1

qx_rework_payload "$PAYLOAD" "$TASK_ID" "$TASK_TITLE" "$BASE_BRANCH" "$BRANCH_PREFIX" \
  "$REWORK_PLAN" "$REWORK_NOTE" "$APPROVED_BASE_SHA" || exit 1
```

### 4d. Fire the cloud routine — task-build.md Step 6A, verbatim

Run **`.claude/commands/task-build.md` Step 6A ("A) Single unit") exactly as written**, against
the payload 4c just produced. Do not restate it, do not paraphrase its shell, and do not
substitute a local run for any part of it. It already does, in this order:

1. publishes `.quetrex/plan/<TASK_ID>.json` to the disposable spec branch `quetrex-spec/<TASK_ID>`
   (delete-then-push, never `push -f` — `deny-guard.sh` denies that outright),
2. sanitizes the title, fills `.claude/lib/cloud-build-routine.md`'s `{{TASK}}`, `{{TITLE}}`,
   `{{REPO_URL}}`, `{{SPEC_BRANCH}}`, `{{BASE_BRANCH}}`, `{{BRANCH_PREFIX}}` placeholders, and calls
   the **`RemoteTrigger`** tool with that body — `action:"create"` (enabled, `run_once_at`), then
   `action:"run"` on the returned id, then `action:"update"` with `{"enabled": false}`
   **immediately**, confirming `next_run_at` comes back null. Never report a dispatch while
   `next_run_at` is still set: that is a second, concurrent build of the same task,
3. records `dispatch` (routine id, monitor URL, spec branch, base sha) into the payload.

The inputs it needs are already resolved above: `TASK_ID`, `PAYLOAD`, `REPO_ROOT`,
`BRANCH_PREFIX`, `QX_CLOUD_ENV_ID`, and `baseBranch` (read out of the payload — `main` for a
standalone unit, `${BRANCH_PREFIX}<EPIC-ID>` for a child).

Then mark the board, **after** the routine is actually firing — the pair (`in_progress` +
a recorded `dispatch`) is exactly what task-build.md's Step 1 guard reads to tell a run in flight
from a wedged card:

```bash
quetrex-api task-status "$TASK_ID" in_progress
quetrex-api task-comment "$TASK_ID" "Rework re-dispatched to a cloud routine: <monitor URL>. Base branch $BASE_BRANCH; gate evidence will be published to ${BRANCH_PREFIX}${TASK_ID}-gates."
```

### 4e. The gate evidence — the whole reason this runs in cloud

The routine's step 5b publishes `gates-head`, `review-verdict.json`, `verify-ledger.jsonl`,
`plan/<TASK>.json` and `state.json` (plus `qa-report.json` / `security-findings.json` when they
exist) to **`${BRANCH_PREFIX}<TASK_ID>-gates`**, pinned to the commit the PR merges. That branch is
what `/quetrex:merge` fetches and what `merge-gate.sh` judges. Nothing here writes those artifacts
by hand, edits them, or re-`sha`s them: if a gate comes back red, it must arrive red and the merge
must be refused.

---

## Step 5 — Report (do not block the terminal)

Report:

- the **monitor URL** `https://claude.ai/code/routines/{id}` — the routine is running on
  Anthropic's servers, so this session, this terminal and this laptop are all free,
- the spec branch (`quetrex-spec/<TASK_ID>`), the base branch, and the unit branch the run
  **resumes** (so the existing PR is updated, not duplicated),
- the gates branch `${BRANCH_PREFIX}<TASK_ID>-gates`, and that `/quetrex:merge <TASK_ID>` is what
  brings it home and re-checks it against the PR head,
- which findings were triaged NIT and pushed ahead of the run (Step 2b), and that the gates
  themselves were **re-run in cloud against the new HEAD** — never that they were skipped.

For an **epic child**, also state that on pass it auto-merges into `${BRANCH_PREFIX}<EPIC-ID>` and
unblocks its dependents, and that the user should then **re-run `/quetrex:task-build <EPIC-ID>`** to
resume the dispatcher and drain those dependents.

Do **not** poll the routine, parse its output, or block the terminal.

---

## Error-handling rules

- Any `quetrex-api` or resolver non-zero exit → the helper already printed the correct user-facing
  message. Just stop; do not add your own auth/access explanation.
- Not in a rework-expecting state → warn and wait for explicit confirmation (Step 1); never
  silently re-run a `pr_ready` / `merged` / finished task.
- Always discuss to confidence before re-dispatching — a re-run without a corrected, agreed plan
  just reproduces the failure, and Step 4c refuses an empty rework note for exactly that reason.
- **Never run the rework build on this machine, and never hand-write gate artifacts.** Compute runs
  on Anthropic's servers; the only evidence `merge-gate.sh` can see is what the routine publishes to
  `<prefix><TASK>-gates`.
- Never downgrade a finding to NIT to reach the Step 2b fast path — it skips the *rebuild*, never
  the gates, and the gates now always run in the same cloud dispatch as everything else.
- An **epic parent** is not a rework target (4a refuses it): rework the failing child, then re-run
  `/quetrex:task-build <EPIC-ID>`.
- Never build a branch name out of `parentTaskId` — it is a UUID. The epic identifier comes from
  `parentIdentifier` or from the child's own `CODE-N.C` identifier.
- Never hardcode a branch prefix — construct every branch from `$BRANCH_PREFIX`.
- Reference the shared engine in `.claude/lib/dev-pipeline.md` and the dispatch in task-build.md
  Step 6A; do **not** restate either here.
- Never print or echo the bearer token. Never run `set -x` / `curl -v` around `quetrex-api`. Build every
  JSON payload with `node` / `JSON.stringify`, never `echo`.
