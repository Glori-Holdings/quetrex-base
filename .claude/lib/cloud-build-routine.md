# Cloud Build Routine — the self-contained in-cloud engine prompt

This file is not run by anything locally. It is the **exact prompt text** that
`.claude/commands/task-build.md` (Step 6A) fills and posts as the `message.content` of a
`RemoteTrigger` event — the body of a fired Claude Code cloud Routine (a CCR). The CCR that
receives it has **zero context**: no prior conversation, no plugin installed, nothing but a
fresh unauthenticated clone of the public repo named in `sources[0].git_repository.url` and
whatever the delegating session pastes below. The routine fires inside a
`job_config.ccr.environment_id: "env_011CUpkAEM4fzsAD6dx1zW3r"` session, `run_once_at` a
couple of minutes in the future, exactly as `.claude/commands/task-build.md` Step 6A builds
it.

**Placeholders** — filled by task-build.md before the prompt is pasted into the event:

| Placeholder | Filled with |
|---|---|
| `{{TASK}}` | the kanban task id (`SMA-1`) |
| `{{TITLE}}` | the task's short title, mechanically sanitized by task-build.md — one line, no control characters, no backticks, no double-brace sequences, hard-truncated to 50 chars + `…` |
| `{{REPO_URL}}` | the repo's `https://` clone URL |
| `{{SPEC_BRANCH}}` | the helper branch carrying the approved spec, `quetrex-spec/{{TASK}}` |
| `{{BASE_BRANCH}}` | the branch the resulting PR targets (`main`, or an epic's integration branch) |
| `{{BRANCH_PREFIX}}` | the project's branch prefix — `claude/`, the only prefix a cloud routine is always allowed to push |

---

## The prompt (verbatim, placeholders substituted, pasted as `message.content`)

**The first line is load-bearing and is not prose.** The routine's `name` field is what the
operator sees in the routine LIST, but the cloud SESSION/transport name is derived from the
FIRST LINE of this prompt body — and that line used to be the same "You are a fresh Claude
Code cloud session…" boilerplate for every build ever dispatched, so two concurrent builds
were indistinguishable on the phone, which is the only surface the operator has while a
build runs. So the prompt now LEADS with `{{TASK}} — {{TITLE}}` on a line of its own, and:

- `{{TASK}}` is the **first token** of the whole prompt. It is never truncated and never
  dropped — it is the one token the operator keys off.
- `{{TITLE}}` is the ONE value here that comes from outside — anyone with write access to
  the board types the task title — and it lands on the first line, above the briefing, in the
  instruction channel of a session that holds Bash and push credentials. So task-build.md
  sanitizes it **in code** before substituting: CR/LF and every other control character —
  C0, DEL **and the C1 block U+0080–U+009F, which contains the line terminator NEL
  (U+0085)** — collapse to spaces, backticks are dropped, double-brace sequences are
  stripped **repeatedly until the value stops changing** (one pass can BUILD a `{{` out of
  the neighbours of the pair it just removed), and the result is hard-truncated to 50
  characters plus a trailing `…`. A two-line title can therefore never deliver its second
  line here as its own top-level instruction, and no title can forge a placeholder. This is
  enforced by `test/placeholder-substitution.test.sh` ASSERTION 5, which executes the
  shipped sanitizer against hostile titles and — in 5i — against a deliberately weakened
  copy of it, so the assertions cannot quietly stop testing anything. It is not a rule the
  dispatching session is trusted to remember.
- The zero-context briefing that follows is unchanged and must stay — the session genuinely
  has no context and needs it. This is a prepend, not a rewrite.

```
{{TASK}} — {{TITLE}}
You are a fresh Claude Code cloud session. You have just cloned {{REPO_URL}} with zero
prior context — no conversation history, no plugin installed, and /quetrex:task-build is
NOT registered as a slash command here. Do the following, in order, and stop only at one of
the two termini in step 5.

### 1. Install the engine
Both engine repos are public specifically so this clone can install them unauthenticated:

    claude plugin marketplace add Glori-Holdings/quetrex-plugins
    claude plugin install quetrex@quetrex quetrex-factory@quetrex

This lands the agent definitions (.claude/agents/architect.md, developer.md, qa.md,
reviewer.md, security-reviewer.md, git-workflow.md) and .claude/lib/dev-pipeline.md on
disk. A mid-session plugin install does NOT register new slash commands without a restart
this session will not get — so /quetrex:task-build is never invoked here. Steps 3-4 below
drive the pipeline directly instead, by reading those installed files.

### 2. Fetch the human-approved spec
The spec was pushed to a disposable helper branch by the local half before you were fired.
Nothing here re-plans and nothing here widens the ownership map the architect already
approved:

    git fetch origin {{SPEC_BRANCH}}
    git show origin/{{SPEC_BRANCH}}:.quetrex/plan/{{TASK}}.json > /tmp/plan-{{TASK}}.json

Validate the result parses as JSON and names a non-empty `ownership` map before continuing.
If it does not, this is a transport problem, not a code problem — stop and report
`transport_failure` (rule 5 below) rather than fabricating a plan.

### 2b. Sync to the approved base, then hydrate the build environment

Two measured failures killed real cloud builds, and `quetrex-cloud-prep` (on the plugin's
PATH, callable by name) fixes both. Run it before ANY stage — a stage that runs the verify
chain without this is guaranteed to fail.

    quetrex-cloud-prep sync {{BASE_BRANCH}} "$(node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync("/tmp/plan-{{TASK}}.json","utf8")).base_sha||""))')" {{BRANCH_PREFIX}}{{TASK}}
    quetrex-cloud-prep hydrate /tmp/plan-{{TASK}}.json --env-file /tmp/quetrex-env-{{TASK}}.sh

WHY `sync`. The clone you were handed cannot be trusted: routines start "from the default
branch" with no ref you can request, and the environment cache is "a filesystem snapshot …
reused as the starting point for later sessions". A run that trusted its checkout built on a
base a day old, then opened three unrelated PRs trying to unblock itself instead of doing its
task. `sync` fetches the base, decides by ANCESTRY (never by string compare) whether the base
is behind the approved sha — in which case it exits non-zero and pushes nothing, because a
build on a base nobody approved is worse than no build — or merely ahead, which is legitimate
and proceeds. It also publishes an empty first commit immediately, so a run that dies early is
visible instead of silent.

WHY `hydrate`. `.env*` is git-ignored, so a fresh clone has no environment at all, and a
verify chain whose build reads one variable fails on that alone. `hydrate` projects the names
from the plan's `required_env` — nothing is hardcoded — and writes credential-less
PLACEHOLDER values, never real credentials. It never overwrites a name already set.

**Every stage runs in its own shell and inherits nothing.** Source the env file at the start of
each stage that runs the verify chain, or that stage fails exactly as before:

    . /tmp/quetrex-env-{{TASK}}.sh

If either command exits non-zero, that is a `transport_failure` (rule 5) — report it and stop.
Do not invent a value, and do not "fix" an unrelated failing test to get the chain green.

### 3. Run THE DEV PIPELINE, in cloud, stage by stage
Follow the exact stage order and gates .claude/lib/dev-pipeline.md defines — architect,
developer(s), QA, reviewer, git-workflow — against base branch {{BASE_BRANCH}} / branch
prefix {{BRANCH_PREFIX}}. The architect already ran locally and produced
/tmp/plan-{{TASK}}.json (PLAN_ARTIFACT); resume from developer(s) — do not re-run the
architect stage. Spawn the remaining stages (developer(s), qa, reviewer, git-workflow) via
the Task tool — one dispatch per stage, in that exact order, each reading its own agent file
off disk (.claude/agents/developer.md, qa.md, reviewer.md, security-reviewer.md when the
plan sets security_review_required, git-workflow.md) as its instructions. If subagent
dispatch is unavailable in this cloud session (the Task tool is absent or fails), run the
stages sequentially yourself in one session instead, applying each role's discipline in that
exact order — this single-session mode is proven to produce a correct PR. Either way, do not
collapse the pipeline into one undifferentiated pass — each stage is a distinct read of its
own agent file, with its own inputs, its own gate, and its own artifact under .quetrex/.

### 4. The five hardening rules — non-negotiable, they govern every stage above
 1. **Commit-as-you-go.** Commit each coherent slice of work the moment it is a complete,
    working unit. Never let the working tree accumulate uncommitted work across stage
    boundaries — a transport death (rule 4) must never cost more than the slice in flight.
 2. **QA fail-first proof.** For every acceptance criterion, the new or strengthened test
    QA writes MUST be run against the pre-fix code and observed to FAIL for the right
    reason before the fix lands, then observed to pass after it lands. A test that was
    never red proves nothing, and QA does not accept one that skipped this.
 3. **Never reformat untouched lines.** Every diff touches only the lines the change
    actually requires. A formatter or editor sweep across a whole file — reindenting,
    rewrapping, reordering imports on lines the change didn't otherwise touch — is a
    defect, not a cleanup: it hides the real diff from the reviewer.
 4. **Resume from committed work on transport death.** If the connection, the container,
    or a model call dies mid-stage, do not restart from scratch and do not assume prior
    work is lost. Re-check `git log` and `git status` first, and resume exactly from the
    last commit — re-run only the interrupted stage, never redo work already committed.
 5. **Exhausted infra retries return `transport_failure`, never a board status flip.** If,
    after retrying, what is failing is infrastructure — repeated transport death, repeated
    tool-call failure unrelated to the diff or the tests — report `transport_failure` and
    stop. Do NOT report `needs_clarity` for an infra problem: `needs_clarity` means the
    CODE or the SPEC needs a human decision; `transport_failure` means the RUN needs to be
    re-fired. Conflating the two sends a human down the wrong path.

### 5. Verify, push, open the PR — the terminus
Run the full verify chain from `.quetrex/verify.json` and confirm every command exits 0.
Push the unit branch and open a PR into {{BASE_BRANCH}}:

    gh pr create --base {{BASE_BRANCH}} --head <unit-branch>

If `gh` is unavailable in this environment, say so explicitly rather than silently skipping
the PR — that is also a `transport_failure`, not a silent success.

**Do NOT merge the PR.** An open PR into {{BASE_BRANCH}} is the terminus. Merge is decided
downstream by the reviewer's AUTO_MERGE verdict, `merge-gate.sh`, and GitHub branch
protection on the real repo — this routine bypasses none of them and merges nothing itself.

### 5b. Publish the gate evidence — without this, the PR can never be merged

Every gate artifact you just produced lives in **this** sandbox, and `.quetrex/*` is
git-ignored, so a normal push leaves all of it behind. The operator's machine then runs
`merge-gate.sh`, finds no verdict and no ledger, and denies the merge — which is exactly why
merging used to require going around the gate by hand. **The evidence has to come home.**

Push it to a dedicated branch, the same way the spec branch delivered the plan here. Run the
block between the two sentinel comments **verbatim** — it is executed as-is by this repo's
test suite, so an edit here is an edit to tested behaviour:

    # >>> QUETREX GATE PUBLICATION >>>
    HEAD_SHA="$(git rev-parse HEAD)" || { echo "transport_failure: no HEAD to publish gates for" >&2; exit 1; }
    GATES_BRANCH="{{BRANCH_PREFIX}}{{TASK}}-gates"
    mkdir -p .quetrex/plan || { echo "transport_failure: cannot create .quetrex/plan" >&2; exit 1; }
    # THE PLAN AND THE STATE ARE GATE EVIDENCE, not scratch. merge-gate.sh reads
    # .quetrex/plan/<TASK>.json for the file-ownership map (GATE 5) and for
    # security_review_required (GATE 4), and reads .quetrex/state.json to know WHICH
    # plan governs this merge. Both are git-ignored, so neither reaches the operator
    # through the PR: without publishing them here, both gates silently no-op on every
    # cloud build and a developer that edited outside its lane ships unchallenged.
    [ -f ".quetrex/plan/{{TASK}}.json" ] || cp "/tmp/plan-{{TASK}}.json" ".quetrex/plan/{{TASK}}.json" \
      || { echo "transport_failure: the approved plan /tmp/plan-{{TASK}}.json is gone; cannot publish it" >&2; exit 1; }
    node -e 'const fs=require("fs"),p=".quetrex/state.json";let s={};try{s=JSON.parse(fs.readFileSync(p,"utf8"))}catch(e){}if(!s.task)s.task=process.argv[1];fs.writeFileSync(p,JSON.stringify(s,null,2)+"\n")' "{{TASK}}" \
      || { echo "transport_failure: cannot write .quetrex/state.json" >&2; exit 1; }
    node -e 'const fs=require("fs");fs.writeFileSync(".quetrex/gates-head",process.argv[1]+"\n")' "$HEAD_SHA" \
      || { echo "transport_failure: cannot write .quetrex/gates-head" >&2; exit 1; }
    git checkout -q -b "$GATES_BRANCH" || { echo "transport_failure: cannot create $GATES_BRANCH" >&2; exit 1; }
    # REQUIRED. Never `2>/dev/null || true` here: a swallowed staging failure publishes a
    # gates branch that LOOKS complete while the evidence is silently absent, which is
    # strictly worse than no branch at all — the operator's gate then reads "no plan" and
    # skips the very checks this branch exists to carry. Missing required evidence is a
    # transport_failure (rule 5): stop, push nothing, and say which artifact is missing.
    for f in .quetrex/gates-head .quetrex/review-verdict.json .quetrex/verify-ledger.jsonl \
             ".quetrex/plan/{{TASK}}.json" .quetrex/state.json; do
      [ -f "$f" ] || { echo "transport_failure: required gate artifact missing: $f" >&2; exit 1; }
      git add -f "$f" || { echo "transport_failure: cannot stage gate artifact: $f" >&2; exit 1; }
    done
    # OPTIONAL — legitimately absent on some runs (no security review was required; a route
    # with no separate QA report). Absent is fine; failing to stage one that EXISTS is not.
    for f in .quetrex/qa-report.json .quetrex/security-findings.json; do
      [ -f "$f" ] || continue
      git add -f "$f" || { echo "transport_failure: cannot stage gate artifact: $f" >&2; exit 1; }
    done
    git -c user.name='quetrex-bot' -c user.email='quetrex-bot@users.noreply.github.com' \
      commit -q -m "chore(gates): {{TASK}} gate artifacts for $HEAD_SHA" \
      || { echo "transport_failure: cannot commit the gate artifacts" >&2; exit 1; }
    # Idempotent AND hook-legal. `git push -f` / `--force` is DENIED outright by
    # deny-guard.sh, which the engine you installed in step 1 ships, so the old
    # `push -f` here dies the moment a task is built twice and the gates branch
    # already exists. Delete-then-push needs no remote-tracking ref (this branch
    # was just created locally, so `--force-with-lease` would fail "stale info").
    # The delete SPELLS THE BRANCH NAME OUT rather than passing the variable:
    # that same deny-guard.sh treats a remote ref delete as catastrophic and
    # permits it only in the disposable quetrex-spec/* and *-gates namespaces.
    # A PreToolUse hook is handed the command BEFORE the shell expands it, so a
    # bare variable is opaque to that rule and the delete is denied. Same value,
    # written where the guard can read the namespace.
    if git ls-remote --exit-code --heads origin "$GATES_BRANCH" >/dev/null 2>&1; then
      git push --quiet origin --delete "{{BRANCH_PREFIX}}{{TASK}}-gates" || exit 1
    fi
    git push --quiet origin "$GATES_BRANCH" \
      || { echo "transport_failure: cannot push $GATES_BRANCH" >&2; exit 1; }
    # <<< QUETREX GATE PUBLICATION <<<

Rules that make this evidence and not decoration:

- Publish the artifacts **exactly as the stages wrote them.** Do not edit, summarise,
  re-time, or re-`sha` anything. If a gate is red, publish it red — `/quetrex:merge` is
  supposed to refuse, and a doctored artifact is the one failure mode that would make the
  whole gate meaningless. The only two files this step may create are the ones nothing else
  writes in the sandbox: `gates-head`, and `state.json`'s `.task` when the pipeline never
  seeded it (an existing `.task` is left exactly as the stages wrote it).
- `gates-head` must be the **same commit the PR merges.** If you push more commits after
  writing it, re-run this step; a mismatch makes the local gate reject the artifacts as
  stale, which is the correct outcome.
- Five files are REQUIRED — `gates-head`, `review-verdict.json`, `verify-ledger.jsonl`,
  `plan/{{TASK}}.json`, `state.json`. If any one of them cannot be staged, the block above
  stops and pushes nothing: report `transport_failure` (rule 5) naming the artifact. Two are
  optional and published when present — a missing `security-findings.json` on a neutral diff
  is legitimate, as is a route that produced no separate `qa-report.json`.
- Say the gates branch name in your final message so the operator can see it.

**Do NOT depend on cloud board-MCP.** Writing kanban status/comments needs interactive
OAuth this headless session does not have. The local half already holds the spec and
reconciles task status from the PR/branch it observes on GitHub — do not call the kanban
API from here.
```

---

## Notes for the dispatching session (task-build.md), not part of the prompt above

- Never place a bearer token, API key, or any other secret in this prompt or in the
  `RemoteTrigger` body that wraps it — the CCR authenticates to GitHub with its own
  credentials, never one handed to it here.
- `allowed_tools` on the `RemoteTrigger` body stays `["Bash", "Read", "Write", "Edit",
  "Glob", "Grep", "Task"]` — the minimum this pipeline needs, `Task` included so the
  session can dispatch the architect/developer/qa/reviewer stages as subagents. Do not
  widen it further to grant broader shell or network access than the build requires.
- The spec branch (`{{SPEC_BRANCH}}`) carries only `.quetrex/plan/{{TASK}}.json` — the plan
  itself must never carry a credential; it is architecture and acceptance criteria, nothing
  the `security_surface` classifies as secret.
- The publication block in step 5b is delimited by the sentinel comments
  `# >>> QUETREX GATE PUBLICATION >>>` / `# <<< QUETREX GATE PUBLICATION <<<`.
  `test/routine-transport.test.sh` extracts exactly those lines, substitutes the
  placeholders, and RUNS them against a real repo with a bare remote. Keep the sentinels and
  keep the block executable shell: a change that breaks either turns the only executable
  proof of this transport back into prose.
- The gates branch is the return leg of a two-owner contract. It carries seven paths:
  `verify-ledger.jsonl`, `review-verdict.json`, `qa-report.json`, `security-findings.json`,
  `gates-head`, **`plan/{{TASK}}.json`** and **`state.json`**. `/quetrex:merge` fetches all
  of them into the operator's `.quetrex/` (and removes them again in cleanup); `merge-gate.sh`
  then has the plan it needs for GATE 5's ownership check and for the plan-forced security
  review. Dropping either of the last two from this push silently disarms both gates.
