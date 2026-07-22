# PIPELINE — The Quetrex Factory Engine

**Status:** authoritative. This document defines the pipeline that runs a task from
plan to PR. `commands/quetrex-task-build.md` *enacts* this state machine; every other
command that builds code (`quetrex-task-rework`) re-enters it. When this doc and a
command disagree, this doc wins — fix the command.

**Design axiom (repeated from the system blueprint):** every gate in this pipeline is
enforced by a **hook or an on-disk artifact a hook reads**, never by an agent's prose.
Agents navigate; deterministic checkers decide. A stage "passes" only when it has
written its `.quetrex/*` artifact and that artifact is green — the next stage reads the
artifact, not the previous stage's chat output. "Done" is mechanically impossible while
any artifact is red.

---

## 0. The truth store — `./.quetrex/`

Every stage communicates through machine-readable artifacts under the repo root. Hooks
resolve `$ROOT` from `git rev-parse --show-toplevel` (worktree-safe), never from a `cwd`
guess. See `docs/ARTIFACTS.md` for the full schema; the pipeline-relevant subset:

| Artifact | Written by | Read by | Meaning |
|---|---|---|---|
| `project.json` | `/quetrex-init` | orchestrator | repo↔project binding |
| `verify.json` | `/quetrex-init` | verify-gate, qa, qa-verify skill | **single source of truth** for the ordered verify chain (`.verify[]`), coverage threshold, `.format` cmd |
| `state.json` | orchestrator | orchestrator, git-workflow | `{task, route, stage, qa_iter, review_iter, security_iter}` |
| `plan/<TASK>.json` | architect | developer, qa, reviewer, security-reviewer, git-workflow | ownership map, acceptance criteria, security surface, verify chain, flags |
| `verify-ledger.jsonl` | verify-gate (append-only) | verify-gate, git-workflow, enforce-merge-approval | every verify run `{ts,cmd,cwd,exit,tail20}` |
| `verify-attempts` | verify-gate | verify-gate | integer self-heal counter; reset to 0 on green |
| `security-findings.json` | security-reviewer | enforce-merge-approval, orchestrator | `[{severity,category,cwe,file,line,exploit,status}]` |
| `review-verdict.json` | reviewer | enforce-merge-approval, orchestrator | `{verdict:APPROVE\|BLOCK, confirmed:[…], plausible:[…]}` |
| `merge-approval.json` | `/quetrex-task-merge` (after human OK) | enforce-merge-approval | `{task, approvedBy, sha, ts}` |
| `ESCALATION` | verify-gate / orchestrator | enforce-merge-approval, orchestrator | present ⇒ a bounded loop hit its cap; blocks merge, surfaces to user |

**Rule of the store:** a stage that has not written its artifact has not passed,
regardless of what it said in chat. git-workflow and the merge hook read files; they do
not read the transcript.

---

## 1. Routing — the entry decision (SPEED pillar)

Before any stage runs, the task is sized. Sizing is deterministic and happens in the
`right-size-router.sh` hook on `UserPromptSubmit` (sub-100ms, no model call in the common
case). The router injects an authoritative `ROUTE:` line as `additionalContext`; the
orchestrator **does not re-decide** — it obeys the injected route.

### 1.1 Classification

| Tier | Trigger signals | Path taken |
|---|---|---|
| **TRIVIAL** | typo/comment/copy fix, single-value config change, dependency version bump, rename within one file, docs-only, single-function edit in one named file | single agent, direct edit in the working tree — **no** worktree, architect, parallel devs, or reviewer |
| **STANDARD** | everything not caught by the TRIVIAL or COMPLEX signal sets | one worktree, one developer + qa; reviewer only if security paths are touched |
| **COMPLEX** | any one of: new dependency; schema/DB migration; >3 files or crosses layers (api+ui+db); ambiguous/underspecified ask; public-API change; prompt/paths touch **auth / authz / payment / crypto / secrets / infra / CI** | full architect → parallel developers → qa → reviewer → security-reviewer → git-workflow |

### 1.2 Two rules that keep the fast path safe

1. **Conservative round-up.** Low-confidence or contradictory signals round **up** one
   tier. Mis-sizing a hard task as trivial ships silent bad code; the reverse only wastes
   tokens. If genuinely ambiguous the router emits `AMBIGUOUS`, and the orchestrator
   spawns the `triage` agent (haiku) for one token: `TRIVIAL|STANDARD|COMPLEX`.
2. **Hard security override.** Any path matching `auth|authz|secret|migration|infra|ci|payment`
   forces **minimum STANDARD** and forces `security_review_required=true`, regardless of
   score and regardless of the architect's own judgment. Security is mandatory
   **by detection**, not by discretion.

### 1.3 Ceremony is optional; the floor is not

The fast path lowers *orchestration* cost, never the *safety* floor. On **every** tier —
including TRIVIAL — these hooks still fire:

- `verify-gate.sh` (Stop + SubagentStop) — no red finish
- `deny-guard.sh` — destructive-command deny
- `secret-scan.sh` — secret/entropy deny on Write/Edit **and** Bash
- `enforce-branch.sh` — no commit on `main`/`master`
- `enforce-merge-approval.sh` — artifact-gated merge

A TRIVIAL edit that breaks the build is blocked by verify-gate exactly like a COMPLEX one.

---

## 2. The state machine

```
route (hook) ──TRIVIAL──▶ [single agent: edit → verify-gate green] ──▶ PR (if repo change) ──▶ human merge
             ──STANDARD─▶ architect(light) → developer → qa ─┐
             ──COMPLEX──▶ architect → developers(∥ disjoint) → qa ─┐
                                                                    ▼
                                        ┌──────── qa proves green (ledger) ────────┐
                                        │  fail → developer (bounded: qa_iter ≤3)  │
                                        └──────────────┬───────────────────────────┘
                                                       ▼
                                              reviewer (adversarial)
                                     BLOCK → developer (bounded: review_iter ≤3)
                                                       ▼ APPROVE
                                    security-reviewer  (MANDATORY when flagged/detected)
                                   Critical → developer (bounded: security_iter ≤3)
                                                       ▼ clean
                                              git-workflow  (artifact gate → squash PR)
                                                       ▼
                                    HUMAN approval → /quetrex-task-merge → enforce-merge-approval → squash to main
                                                       ▼
                                         worktree-workflow teardown (audit: no dangling worktree/branch/PR)
```

---

## 3. Stage-by-stage contract

Each stage below states: **entry** (what must be true to run it), **agent + I/O
artifacts**, **the gate that decides pass/fail**, and the **exit transition**. A stage
never advances on chat — only on its written, green artifact.

### 3.0 TRIVIAL fast path (bypasses stages 3.1–3.6)

- **Entry:** `ROUTE: TRIVIAL`.
- **Do:** a single agent (sonnet, direct Edit in the working tree) makes the change.
  No worktree, no architect, no ownership map, no parallel devs, no separate QA agent,
  no reviewer.
- **Gate:** `verify-gate.sh` fires on that agent's Stop. It runs the `verify.json` chain
  by exit code; a red chain blocks the finish (bounded self-heal, §4). The agent cannot
  report "done" while any command is non-zero.
- **Exit:** if the change touches the repo, open a squash PR (git-workflow may be invoked
  directly, or the orchestrator opens it); human merges via `/quetrex-task-merge`. A
  docs-only or comment-only change with no shippable artifact may skip the PR only if the
  project does not require a PR for that path — otherwise it PRs like anything else.

TRIVIAL skips ceremony, not gates. The four floor hooks (§1.3) all fire.

### 3.1 architect — the plan (STANDARD light / COMPLEX full)

- **Entry:** `ROUTE: STANDARD` or `COMPLEX`. (STANDARD gets a *light* plan — a single
  workstream, minimal ownership map; COMPLEX gets the full parallel decomposition.)
- **Agent:** `architect` (opus, high). Read/Grep/Glob + Write scoped to the plan file.
- **IN:** task id, refined spec, repo snapshot, path to `.quetrex/verify.json`. The
  delegation message **restates all load-bearing rules** — subagents are context-blind.
- **OUT:** `.quetrex/plan/<TASK>.json` (see `docs/ARTIFACTS.md` for the schema):
  `workstreams[]`, a total `ownership` map, `acceptance[]` (Given/When/Then + numeric
  `measure`), `security_surface[]`, `verify[]`, `security_review_required`, `db_migration`.
- **Gate (mechanical contract rules):**
  1. `ownership` is a **total function over every touched file with zero overlap** — two
     workstreams may not name the same path. Overlap ⇒ plan rejected, re-run.
  2. Every acceptance criterion is Given/When/Then with a **numeric `measure`**. Any
     criterion containing an unquantified adjective (`fast`, `secure`, `reasonable`) ⇒
     the architect returns **`needs_clarity`** (the one valid early exit — §5) instead of
     a plan.
  3. `security_review_required` is advisory; the router's path-detection can force it on
     (§1.2) and the architect cannot turn it off.
- **Exit:** valid plan written → developer(s). `needs_clarity` → pause, ask the user.

### 3.2 developer(s) — implementation (parallel, disjoint)

- **Entry:** a valid `plan/<TASK>.json` exists.
- **Agent:** `developer` (sonnet, high, `isolation: worktree`). On COMPLEX, **one
  developer per workstream, all in parallel**, each in its own worktree on a sub-branch
  (`feature/<desc>-<workstream>`). Each is told: *you may write ONLY files whose ownership
  maps to your workstream.* Disjoint ownership guarantees no write conflicts.
- **IN:** `plan/<TASK>.json` + the single workstream id it owns. Not the reasoning of
  other developers.
- **OUT:** commits on its sub-branch. **Definition of Done — all must hold:**
  (a) every owned acceptance criterion has a test that **fails before, passes after**;
  (b) the full `verify` chain exits 0 locally;
  (c) no secret literals; all external inputs validated; every user-scoped query carries
  an ownership predicate; no whole-body binding to models.
- **Gate:** the developer's own **SubagentStop verify-gate** runs the chain by exit code.
  (b) is not a claim — the gate blocks the subagent from finishing while the chain is red
  (bounded self-heal, §4). A developer physically cannot end green on a red tree.
- **Exit:** all developers green → regular-merge sub-branches into the feature branch →
  qa. (Merge order is arbitrary because ownership is disjoint; conflicts are impossible by
  construction — a conflict means the architect's map overlapped, a §3.1 gate failure.)

### 3.3 qa — prove green, independently (EXCELLENT CODE pillar)

- **Entry:** developer work merged onto the feature branch.
- **Agent:** `qa` (sonnet, high). **Has Write/Edit** — QA authors its own tests; it does
  not merely re-run the developer's suite.
- **IN:** `plan/<TASK>.json`, the acceptance criteria, and the developer's **diff** (via
  `git diff`). It does **not** receive the developer's reasoning transcript
  (anchoring prevention).
- **OUT:** additional, independently-authored adversarial/edge tests, then a green
  `verify-ledger.jsonl` run. Verification ladder, in order:
  `grep/static → typecheck → lint → build → test (real exit codes) →
  changed-file coverage ≥ threshold (`verify.json`, default 80%) →
  mutation (`npx stryker`) where configured`.
- **Gate:**
  1. The ledger's last run must be all-exit-0 (verify-gate writes the ledger; git-workflow
     and the merge hook read it).
  2. **Vacuous-suite guard:** every changed unit must have ≥1 test with a **non-trivial
     assertion**. A suite that passes with zero assertions on changed code is a **FAIL**,
     not a pass — QA must reject it.
  3. QA ends by explicitly listing **what it did NOT verify** (honest coverage boundary).
- **Exit:** green ledger + coverage met + no vacuous suites → reviewer. Red or vacuous →
  developer (bounded, `qa_iter`, §4).

### 3.4 reviewer — refute the diff (adversarial)

- **Entry:** qa green.
- **Agent:** `reviewer` (opus, xhigh, `disallowedTools: Write, Edit` — read-only, cannot
  fix-and-hide; Bash allowed only for read-only inspection like `git diff` and running the
  existing suite).
- **IN:** the diff + minimal spec + acceptance criteria **only**. Explicitly **not** the
  developer's or QA's narrative. Function-level and dependency context around the hunks is
  provided.
- **Stance:** assume the diff is broken. **REFUTE it.** Construct concrete failing inputs.
- **OUT:** `.quetrex/review-verdict.json` **and** a `ReportFindings` call. Each finding
  carries `file:line` + a reproducible `failure_scenario`, tagged:
  - `CONFIRMED` — a repro was built and run, or
  - `PLAUSIBLE` — reasoned but not executed.
- **Gate:** `verdict = BLOCK` **iff ≥1 CONFIRMED correctness/security defect survives**;
  otherwise `APPROVE`. Default stance is suspicion, not approval.
- **Exit:** `APPROVE` → security-reviewer (if required) else git-workflow. `BLOCK` →
  developer (bounded, `review_iter`, §4).

### 3.5 security-reviewer — mandatory when flagged/detected (SECURITY pillar)

- **Entry:** `security_review_required == true` — set by the architect **or forced** by
  the router's path-detection (§1.2). When forced, this stage cannot be skipped.
- **Agent:** `security-reviewer` (opus, xhigh, `disallowedTools: Edit`; Write scoped to
  the findings file; Bash read-only).
- **IN:** the diff, the plan's `security_surface`, full dependency context on touched
  data-access / auth / input paths.
- **OUT:** `.quetrex/security-findings.json`. Runs the OWASP checklist in `docs/SECURITY.md`
  (loadable via the `security-review` skill). Each Critical/High requires a **concrete
  exploit path** (attacker input → wrong outcome) + `file:line` + CWE/OWASP-API id.
  Unsubstantiated findings are downgraded to `PLAUSIBLE` (so parameterized-query false
  positives don't gridlock merges). Unresolved findings carry `status:"open"`.
- **Gate:** any finding with `severity:"critical", status:"open"` blocks the PR — enforced
  by `enforce-merge-approval.sh` reading the artifact (§6), not by prose.
- **Exit:** no open Critical → git-workflow. Open Critical → developer (bounded,
  `security_iter`, §4). A **CONFIRMED Critical** is also one of the three valid reasons to
  pause the whole pipeline (§5).

**database-architect note:** schema changes route through `database-architect` (opus)
*before* this stage. It authors expand→migrate→contract, forward+reverse, data-preserving
migrations with FK indexes/constraints, runs in a worktree with **no blanket
bypassPermissions** (destructive DDL passes the deny-guard like everyone else), then hands
off to qa (full chain) and security-reviewer (migration-safety checklist, §9 of SECURITY).
Self-certification is forbidden.

### 3.6 git-workflow — the artifact-gated PR

- **Entry:** all prior stages passed.
- **Agent:** `git-workflow` (sonnet, medium — Bash + Read only).
- **IN — read from disk, not chat:**
  - `verify-ledger.jsonl` — last run all exit 0
  - `security-findings.json` — no `severity:"critical", status:"open"`
  - `review-verdict.json` — `APPROVE`
  - **absence** of `.quetrex/ESCALATION`
- **OUT:** a **squash PR to `main`**. If any artifact gate fails → **refuse**, write the
  failing reason to `state.json`, do not open the PR.
- **Hard rule:** git-workflow **never merges.** Merge is a separate, human-gated command
  (§7).
- **Exit:** PR opened → wait for human approval.

---

## 4. Bounded loops — mechanical, not advisory

Every repair loop is bounded by a counter that lives on disk, so the "max 3 then escalate"
rule from `CLAUDE.md` is enforced by arithmetic, not by an agent remembering it.

**Two counter systems, both real:**

1. **`verify-attempts`** (a file). The verify-gate hook's self-heal loop. Algorithm each
   time a Stop/SubagentStop fires with a red chain:
   ```
   n = read(verify-attempts) + 1 ; write(verify-attempts, n)
   if n < 3:  block  {"decision":"block","reason":"<cmd> exited <code>. Fix and re-verify. Last 20 lines:\n<tail>"}   # exit 0
   else:      touch .quetrex/ESCALATION
              block  {"decision":"block","reason":"ESCALATE: <cmd> still red after 3 self-heal attempts. STOP self-healing. Surface to the user with this output and do not report the task done:\n<tail>"}   # exit 0
   ```
   A green chain resets the counter to 0. The counter *is* the termination mechanism, so
   the hook never loops forever — we do **not** blanket-exit on `stop_hook_active` (that
   would let a blocked agent stop red); we run every time, and the counter guarantees ≤3
   cycles.

2. **`state.json` stage counters** — `qa_iter`, `review_iter`, `security_iter`. The
   orchestrator increments the relevant counter each time it bounces work back to a
   developer from qa / reviewer / security-reviewer. On **any counter ≥ 3**: write
   `.quetrex/ESCALATION`, **stop the loop**, and surface to the user. Never loop forever.

**`ESCALATION` is load-bearing.** Once written it is read by the merge gate (§6) — red or
unresolved work **physically cannot merge** even after the agent is permitted to stop. The
orchestrator must surface the escalation to the user with the failing output and must not
report the task done.

---

## 5. Pipeline Mode — no stops, and the three exits

Once the pipeline starts, run **every** stage to completion without asking for
confirmation, plan review, or approval at any intermediate point. Never ask "does this
look right?", "should I proceed?", or "want to review before continuing?". Fire-and-forget
is the product.

**The only valid reasons to pause:**

1. A question **only the user can answer** — no reasonable assumption exists.
2. A **bounded loop hit its cap** (`ESCALATION` written — QA/reviewer/security 3× or
   verify-attempts 3×). Surface the failing output; do not report done.
3. A **CONFIRMED Critical** security finding.

**The one early exit inside a stage:** the architect may return **`needs_clarity`** when a
task's acceptance criteria cannot be made measurable (§3.1). That bounces the task back to
refinement — it is not a pipeline failure, it is the correct terminus for an
unspecifiable ask.

Nothing else pauses the pipeline.

---

## 6. The merge gate — where "done" is finally decided

`enforce-merge-approval.sh` (PreToolUse on Bash) intercepts `gh pr merge`, `git merge`
into `main`, and `git push` to `main`. It **denies** unless **every** condition holds:

- `.quetrex/merge-approval.json` exists, its `sha` equals `git rev-parse HEAD` of the PR
  head, and `approvedBy` is set — this file is written **only** by `/quetrex-task-merge`
  **after a human approves**.
- `.quetrex/verify-ledger.jsonl` — last run all exit 0.
- `.quetrex/security-findings.json` — no `severity:"critical", status:"open"`.
- `.quetrex/review-verdict.json` — `APPROVE`.
- No `.quetrex/ESCALATION` file present.

Any failure ⇒ deny, naming the specific failing artifact. This is the artifact-consuming
gate the standard demands: a Critical or a BLOCK from any stage mechanically prevents the
PR from merging, and **human approval cannot bypass a red ledger** — the human gate and
the artifact gates are ANDed, not ORed.

---

## 7. Human approval & teardown

- **PRs require human approval before merge.** git-workflow opens the PR and stops. A human
  reviews and runs `/quetrex-task-merge <TASK>`, which — only after the human confirms —
  writes `merge-approval.json` and performs the squash merge (which the merge gate then
  permits because all five conditions in §6 now hold).
- **Teardown is mandatory.** After merge, the `worktree-workflow` skill governs cleanup: no
  dangling worktree, no open/unmerged PR, no stale local or remote branch. Run its final
  audit at the end of any multi-unit effort. A left-behind worktree/branch/PR is a defect.

---

## 8. Branching rules (enforced by `enforce-branch.sh`)

- All work on feature branches — **never commit directly to `main`/`master`.**
- One branch per unit of work: `feature/<short-description>`.
- Sub-branches for parallel developers: `feature/<desc>-<workstream>`
  (e.g. `-api`, `-ui`, `-db`).
- Regular-merge sub-branches → feature branch. **Squash-merge** feature branch → main.
- Commit inside a worktree with `git -C <worktree>` so the enforce-branch hook resolves the
  worktree's branch (via `git -C <path> rev-parse --abbrev-ref HEAD`) instead of blocking.
- `enforce-branch.sh` matches the **actual command being run**, not the literal substring
  "git commit" appearing in echoed docs, and allows the first commit on a freshly-created
  branch. It uses `permissionDecision:"ask"` (not hard deny) so a human can intentionally
  override.

---

## 9. What each pillar's guarantee reduces to (traceability)

| Pillar | Guaranteed in this pipeline by |
|---|---|
| **1 — Excellent code** | verify-gate on **Stop AND SubagentStop** binds every finish to real exit codes of the `verify.json` chain (§3.2, §3.3, §4); merge gate re-reads the ledger (§6). QA authors independent tests + coverage + vacuous-suite guard (§3.3). |
| **2 — Solid process** | this state machine (§2), where each stage's pass = a written green artifact the next stage reads (§0). Zero-overlap ownership → disjoint parallel devs (§3.1–3.2). Bounded loops (§4). Single early exit = architect `needs_clarity` (§5). git-workflow gates on artifacts, never prose (§3.6). |
| **3 — Security** | security-reviewer is **mandatory, force-triggered by path detection** (§1.2, §3.5); its findings artifact hard-blocks Critical at the merge gate (§6). secret-scan + deny-guard fire under bypass mode (§1.3). |
| **4 — Speed** | the deterministic router (§1) routes TRIVIAL to a single direct-edit agent and STANDARD to one dev+qa; only COMPLEX pays the full line — while the four floor hooks still fire on every tier (§1.3). |

---

## 10. Command → pipeline map (for command authors)

- `/quetrex-task-build <TASK>` — **the entrypoint.** Fetches/refines the task, lets the
  router size it, then drives this state machine to a PR. Runs in Pipeline Mode (§5).
- `/quetrex-task-rework <TASK>` — re-enters the machine after a failure/escalation; agrees
  a fix plan with the user, clears `ESCALATION`, resets the relevant counters, re-runs.
- `/quetrex-task-merge <TASK>` — the **human-gated** merge (§6, §7): writes
  `merge-approval.json` only after human approval, squash-merges, tears down.
- `/quetrex-task-complete <TASK>` — marks a deployed task complete (post-merge tracker
  transition; no pipeline stages).
- `/quetrex-init` — writes `project.json` + `verify.json` (the verify-chain source of
  truth every gate reads).

A command must never re-implement a gate — it delegates to the agents and lets the hooks
decide. If a command needs to know whether a stage passed, it reads the `.quetrex/*`
artifact.
