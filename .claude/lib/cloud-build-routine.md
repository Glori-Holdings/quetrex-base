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
| `{{REPO_URL}}` | the repo's `https://` clone URL |
| `{{SPEC_BRANCH}}` | the helper branch carrying the approved spec, `quetrex-spec/{{TASK}}` |
| `{{BASE_BRANCH}}` | the branch the resulting PR targets (`main`, or an epic's integration branch) |
| `{{BRANCH_PREFIX}}` | the project's branch prefix (`feature/`, or `claude/` where push rules are tighter) |

---

## The prompt (verbatim, placeholders substituted, pasted as `message.content`)

```
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
