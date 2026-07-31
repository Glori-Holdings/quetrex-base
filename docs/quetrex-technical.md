# Quetrex — Technical Reference

The maintainer's document. It states how the system works, why each decision was made, and what it
deliberately does not do. It is the companion to the non-technical partner doc; where that one
explains the product, this one explains the machine.

Every claim below carries a `file:line` citation into this repo. Read it alongside the source.

---

## 0. How to read this document

Two conventions:

- **`[AS BUILT]`** — describes code you can read at the cited line right now.
- **`[INTENT]`** — describes a state specified in `FINDINGS-REF.md` that is not yet in the tree at
  the time of writing, with the finding number. Where intent and current code differ, both are
  stated.

Line numbers are the fragile part. Prefer the function name or the comment-block heading when a
citation does not resolve — the hook scripts are heavily commented and every load-bearing decision
carries its reasoning inline, so the comment is usually easier to find than the line.

One structural fact governs everything else. **A verification design is worth nothing until it is
wired.** This repo's design leads Anthropic's published guidance in about ten places (§12.1), and
for most of its life the wiring lagged it: hooks referenced by paths that did not resolve outside
the author's machine, two flagship gates registered in no settings file, an install assertion that
checked bytes instead of reachability. The fix program that produced this document closed that gap.
Read §10.1 before you trust any gate, including after your own changes: a broken enforcement hook
and a passing one are indistinguishable from inside a session (§6.2).

---

## 1. Architecture — the seven agents

### 1.1 The roster

All seven live in `.claude/agents/*.md`. Frontmatter is an enforcement surface, not documentation:
`tools`, `disallowedTools`, `permissionMode` and `maxTurns` are applied by the runtime.

| Agent | Model / effort | Tools | Denied | Permission mode | maxTurns | Isolation |
|---|---|---|---|---|---|---|
| `architect` | opus / high (`architect.md:5-6`) | Read, Grep, Glob, **Write** (`:4`) | no Edit, no Bash | inherit | — | none |
| `developer` | sonnet / high (`developer.md:5-6`) | Read, Write, Edit, Bash, Grep, Glob (`:4`) | — | **bypassPermissions** (`:7`) | 80 (`:9`) | **worktree** (`:8`) |
| `database-architect` | opus / high (`database-architect.md:5-6`) | Read, Write, Edit, Bash, Grep, Glob (`:4`) | — | **inherit — no bypass** (`:13`) | 60 (`:8`) | **worktree** (`:7`) |
| `qa` | sonnet / high (`qa.md:5-6`) | Read, Write, Edit, Bash, Grep, Glob (`:4`) | — | **bypassPermissions** (`:7`) | 80 (`:8`) | none |
| `reviewer` | opus / **xhigh** (`reviewer.md:6-7`) | Read, Grep, Glob, Bash, SlashCommand (`:4`) | **Write, Edit** (`:5`) | inherit | 60 (`:8`) | none |
| `security-reviewer` | opus / **xhigh** (`security-reviewer.md:7-8`) | Read, Grep, Glob, Bash (`:4`) | **Edit** (`:5`); skill `security-review` (`:6`) | inherit | — | none |
| `git-workflow` | sonnet / medium (`git-workflow.md:5-6`) | Bash, Read (`:4`) | no Write/Edit | **acceptEdits** (`:7`) | 30 (`:8`) | none |

### 1.2 Why each denial exists

The denials are the load-bearing part. Each closes a specific, named failure.

**`reviewer` cannot Write or Edit** (`reviewer.md:5`, restated at `:20`). The reason is stated in
the file: *"`Write`/`Edit` are denied so you cannot 'fix and hide' a defect — a bug you find becomes
a REWORK finding for the developer, never a patch by you."*

A reviewer that can patch has a conflict of interest with its own verdict. The cheapest route to
AUTO_MERGE is to quietly repair what you found; then nobody downstream learns the developer's work
was defective, the loop counter never increments, and the pattern never surfaces. The tool
restriction removes the cheap route.

The reviewer still needs to write three files — the verdict, the loop counter, the escalation
marker — so it writes them through `Bash`/`jq` (`reviewer.md:20`). That is a deliberate hole,
bounded by convention rather than mechanism: `:353` restricts Bash writes to those three artifacts
and forbids `sed -i`, redirection and heredocs into source. This is prose, not enforcement. See
§11.3.

**`security-reviewer` has `disallowedTools: Edit`** (`security-reviewer.md:5`), one notch looser —
it keeps Write for the single findings artifact (`security-reviewer.md:113`). Its stance is at
`:14`: *"Assume the change is exploitable until you have read the code paths that prove
otherwise."*

**`architect` has Write but no Edit and no Bash** (`architect.md:4`). It emits exactly one file,
`./.quetrex/plan/<TASK>.json` (`:37`, `:135`), and cannot modify an existing one. No Bash means it
cannot run the build, install anything, or mutate the repo while "exploring." The planning stage is
structurally incapable of becoming an implementation stage.

**`database-architect` declines a permission bypass it could have had** (`database-architect.md:13`):

> You run in an isolated worktree on your own sub-branch. You have **no permission bypass**: every
> command you run — including destructive DDL — passes through the deny-guard and secret-scan hooks
> exactly like every other agent. If a command is blocked, it is blocked for a reason; do not route
> around it.

It is the only implementation agent without `permissionMode: bypassPermissions`, and it is the one
that runs `DROP`, `ALTER` and live migrations. That is the argument in full: **the agent whose
mistakes are irreversible is the agent that keeps the permission engine in the loop.** `developer`
and `qa` run under bypass (`developer.md:7`, `qa.md:7`) because their blast radius is a worktree
that can be deleted; a migration's blast radius is data.

Note what bypass does *not* switch off — §6.3. A PreToolUse `deny` is evaluated beneath the
permission engine, so the deny-guard / secret-scan / enforce-branch / merge-gate floor applies to
every agent in the table regardless of mode.

**`git-workflow` has Bash and Read only** (`git-workflow.md:4`) and never merges (`:14`). Its
terminus is an open PR. It cannot write code, so it cannot "fix" a red gate; when an artifact is
red it refuses and records the reason.

### 1.3 Pipeline order — what each stage consumes and produces

```
isolate (worktree)
  → architect
    → developer(s) ‖ database-architect        (parallel, disjoint file sets)
      → merge sub-branches into the unit branch
        → qa                                    ── inner loop, bounded ~3
          → reviewer (+ security-reviewer)      ── outer loop, bounded 3
            → git-workflow → PR
              → merge-gate → merge
```

| Stage | Consumes | Produces | Refuses when |
|---|---|---|---|
| architect | refined spec, `.quetrex/verify.json` (`architect.md:31`), route tier + forced flags (`:21`) | `plan/<TASK>.json` (`:44-84`) or a `needs_clarity` stub (`:125-128`) | the spec cannot be made measurable (`:121-129`) |
| developer | plan ownership map, acceptance, `security_surface` (`developer.md:18-23`); `verify.json` (`:24`) | committed code + tests on `feature/<desc>-<workstream>` (`:63-73`) | a needed file is outside its lane (`:32-33`) |
| database-architect | plan `db_migration:true` (`database-architect.md:21`), `verify.json` migrate fields (`:18`) | forward + reverse migrations proven on a shadow DB (`:37`, `:71-72`) | invoked without `db_migration:true` (`:21`) |
| qa | plan acceptance criteria, the diff it fetches itself (`qa.md:25-31`), `verify.json` | sha-pinned ledger lines, committed tests, **`qa-report.json`** (`qa.md:140-193`), PASS/FAIL with a mandatory gap list | any rung non-zero, coverage under threshold, vacuous suite, unrun smoke |
| security-reviewer | diff + plan `security_surface` (`security-reviewer.md:18-19`) | `security-findings.json` (`:60-101`) | — always writes, even when clean (`:103`) |
| reviewer | diff, PR, plan, and the on-disk artifacts incl. `qa-report.json` (`reviewer.md:33`) — explicitly **not** the authors' transcripts (`:37`) | `review-verdict.json`, `state.json.review_iter`, `ESCALATION`, one `ReportFindings` call | never refuses — it always emits one of three verdicts |
| git-workflow | all gate artifacts (`git-workflow.md:28-126`) | re-proven sha-pinned ledger, push, squash PR | any artifact red, **or uncommitted work outside the reviewed commit** (`:146-156`) |

Two properties of the shape, both deliberate:

1. **Every stage reads from disk, not from the conversation.** `git-workflow.md:11`: *"You do not
   trust anything the orchestrator or any prior agent told you in chat. You trust exactly one thing:
   the on-disk artifacts."* `qa.md:18`: QA receives the diff, not the developer's reasoning.
   `reviewer.md:37` is sharpest — a leaked author/QA narrative must be ignored, *"it is an anchoring
   trap"* — with one carefully-drawn exception (§2.2).
2. **No stage self-certifies.** developer → QA → reviewer → git-workflow → merge-gate, each proving
   the previous stage's claim independently. `database-architect.md:76`: *"Self-certification is
   forbidden."*

---

## 2. The control plane

### 2.1 Every artifact

All under `$ROOT/.quetrex/`. `$ROOT` is resolved worktree-safely and never from `cwd`: try
`$CLAUDE_PROJECT_DIR`, then the session `cwd` from the hook payload, then a bare `git rev-parse`
(`verify-gate.sh:80-93`, `merge-gate.sh:142-153`).

Tracked versus ignored is deliberate and is expressed as a **whitelist** in `.gitignore:24-36`:
everything the gates write at runtime is ignored, and only the two project-config artifacts are
tracked, so a newly-invented runtime artifact is ignored by default instead of leaking into a
commit.

| Artifact | Tracked | Written by | Read by | Invariant it carries |
|---|---|---|---|---|
| `project.json` | **yes** | `/q-init` | the `q-task-*` commands | which kanban project this repo is bound to |
| `verify.json` | **yes** | `/q-init`, seeded from `.claude/templates/verify.json` (`quetrex-install-project-gates.sh:245-253`) | verify-gate, merge-gate GATE 3, architect, qa, developer | **the single definition of "green"**: ordered `.verify[]`, optional `.verifyQuick[]`, `.coverage`, `.coverageThreshold`, `.mutation`, `.e2e`, `.migrate*` |
| `plan/<TASK>.json` | no | architect only (`architect.md:37`) | developer, qa, reviewer, security-reviewer, merge-gate GATE 4 + GATE 5 | ownership is *"the enforceable contract developers are held to"* (`architect.md:91`); acceptance criteria are numeric (`:108-111`); `security_review_required` is advisory-**up** only (`:113`) |
| `verify-ledger.jsonl` | no | verify-gate (`:354-359`), qa, git-workflow §2a | merge-gate GATE 3, git-workflow Gate 2 | append-only proof of exit codes, **each line pinned to the commit it proved** |
| `qa-report.json` | no | qa only (`qa.md:140-193`) | reviewer (`reviewer.md:89-102`) | QA's verdict **and its `not_verified[]` coverage gaps**, sha-pinned |
| `security-findings.json` | no | security-reviewer only | merge-gate GATE 4, git-workflow Gate 3 | no open Critical; `head_sha` pins it to the reviewed commit |
| `review-verdict.json` | no | reviewer only | merge-gate GATE 2/2b, git-workflow Gate 4 | exactly one of `AUTO_MERGE｜REWORK｜ESCALATE_HUMAN`, `.sha` == reviewed HEAD, `.inputs.nativeSecurityReview` records what actually ran |
| `state.json` | no | reviewer (`.review_iter`), git-workflow on refusal | merge-gate (to resolve the governing plan), reviewer | the outer loop's iteration count and the current task id |
| `ESCALATION` | no | verify-gate at the self-heal cap, reviewer at the rework cap | merge-gate GATE 1, git-workflow Gate 1, reviewer | **a bounded loop hit its cap.** Cleared only by a genuinely green verify run or a human |
| `verify-attempts` | no | verify-gate only | verify-gate | the self-heal counter — incremented by the **hook**, out of band from the agent it bounds |

### 2.2 Chain of custody, plan to merge

```
architect   → plan/<TASK>.json          ownership · acceptance · security flag · verify chain
developer   → commits (no artifact)     the plan constrains which files it may touch
qa          → verify-ledger.jsonl (+sha)   proves the chain green by exit code
            → qa-report.json    (+sha)     declares what it could NOT verify
security-rv → security-findings.json (+head_sha)   no open Critical
reviewer    → review-verdict.json  (+sha, +inputs.nativeSecurityReview)
              state.review_iter  [+ ESCALATION at the cap]
git-workflow→ adds NO commit (§5.3) → re-proves the chain at that same HEAD
            → push → PR
merge-gate  → GATE 1..5 over all of the above → allow or deny
```

One property matters more than the rest: **each artifact names the commit it describes.** A
signature that does not name what it signed is not a signature. See §5.

`qa-report.json` deserves a note, because it is the one place the anti-anchoring rule is
deliberately relaxed. `reviewer.md:37`:

> Distrusting QA's *claims of green* is correct — you re-prove green yourself. But QA's statement of
> what it could **not** verify is negative-space evidence you cannot reconstruct from the diff.

Right to distrust QA's claims; wrong to discard QA's gaps, which the reviewer most needs and cannot
reproduce. The resolution is to move the gaps out of chat and into an artifact
(`qa.md:20`, `:96`), where they are sha-pinned like everything else and become *inputs to the
verdict rule*: `qa_report_ok` and `qa_gap_security` at `reviewer.md:187-188`, with an unpinned or
missing report treated as an uncertainty that escalates (`:356`).

### 2.3 Why on-disk artifacts and not conversation

The specific failure this defeats: **an agent's summary is not evidence, and a summary is all a
conversation carries.** Course L8 names it — *"a tidy summary that reads perfectly fine, while the
actual diff touched a file you honestly didn't expect it to touch. The summary won't tell you that.
The diff will."* (`COURSE-REF.md:309`).

Six consequences:

1. **A hook can read it.** A hook is a subprocess with stdin and a filesystem; it cannot read the
   conversation. Any rule you want mechanically enforced must be expressible against files. This is
   why `merge-gate.sh` can exist at all.
2. **Compaction cannot lose it.** A multi-hour pipeline will compact. A claim in turn 40 of a
   transcript is gone; a file is not. This is also why the SessionStart re-injection hook is cheap —
   it re-reads ground truth rather than summarizing chat.
3. **A fresh context can consume it.** The reviewer is a cold instance by design
   (`reviewer.md:352`). Cold instances have no transcript.
4. **It is falsifiable.** `sha`, `exit`, `head_sha` are checkable. "Tests pass" is not.
5. **It survives the process.** A crashed agent leaves its artifacts; its context is gone.
6. **It crosses machines.** A cloud routine and the operator's laptop share files in a git repo, not
   a session.

`qa.md:16` is the doctrine in one line: *"A command that prints 'All tests passed' and exits `1` is
a FAIL."* The ledger records `$?`. Nothing in the system records adjectives.

---

## 3. The gates

Two scripts carry the guarantee. Everything else is supporting structure.

### 3.1 `verify-gate.sh` — Stop and SubagentStop

Purpose (`verify-gate.sh:2-13`): an agent must not be able to finish while the project's
verification chain is red. It binds the *finish decision* to real exit codes, never to chat prose.

**Wiring.** Committed, per-project, at `.claude/settings.json:113-133`:

```
Stop         → bash "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/verify-gate.sh"   timeout 900
SubagentStop → bash "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/verify-gate.sh"   timeout 600
```

and reproduced for every customer repo by `quetrex-install-project-gates.sh:207-208`. The command
form is fixed at `:160-166` as `bash "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/<name>"` — the literal
`${CLAUDE_PROJECT_DIR:-.}` is shell syntax resolved by Claude Code's hook runner at invocation, not
by the node script that writes it.

This is the single highest-value correction in the fix program. Every committed hook command
previously read `bash ~/.claude/hooks/...`, which on any machine without the global npm install —
a fresh clone, a CI runner, a cloud routine — is exit 127, and per course L5 *anything other than 0
or 2 is non-blocking* (`COURSE-REF.md:170`). Enforcement failed open, silently, with no warning.
The rule is now stated as a repo invariant in `.claude/CLAUDE.md:6` and asserted mechanically by
`install.js`'s post-install check (§8.1).

**Chain resolution precedence** (`verify-gate.sh:46-56`), stop at the first that resolves:

1. `$ROOT/.quetrex/verify.json` → `.verify[]` (`:167-206`). On `SubagentStop`, `.verifyQuick[]` is
   substituted **if and only if it is a genuine subset** — see below.
2. `$ROOT/.claude/CLAUDE.md` → commands inside a fenced block under a heading matching
   `/verification/i` (`:208-244`).
3. Autodetect (`:246-277`): `package.json` scripts in the order
   `typecheck, type-check, tsc, lint, build, test`; else `Makefile` targets; else pytest; else
   `go build`/`go test`; else `cargo build`/`cargo test`.
4. Nothing resolves → nothing to gate → `exit 0` (`:279-282`).

Rung 4 is the one honest fail-open in the design and it is the right one: a repo with no declared
verification has nothing to prove. It is also why seeding `.quetrex/verify.json` matters — without
it this repo fell through to rung 3 and gated on a single autodetected command. The seeded chain is
now `.quetrex/verify.json`:

```json
{"verify":["npm run check:js","npm run check:sh","npm run check:json","npm test"],
 "verifyQuick":["npm run check:js","npm run check:sh"]}
```

with the scripts defined at `package.json:8-11` — syntax checks for every JS file, `bash -n` for
every shell script, `JSON.parse` for every config file the system reads, and a test script that now
runs **both** `test/install.test.js` and `test/merge-gate.test.sh`. The hook tests are inside the
chain that gates the repo, which is the only arrangement that makes them load-bearing.

**Rung 2's awk rule order is load-bearing** (`:215-244`). The fence toggle is evaluated **first**,
and the heading rule is gated on `!infence`:

```awk
/^[[:space:]]*```/ { infence = !infence; next }
(!infence && $0 ~ /^#{1,6}[[:space:]]/) { insec = (tolower($0) ~ /verification/) ? 1 : 0; next }
(insec && infence) { … emit … }
```

Reversed — which is how it was written — a shell comment *inside* the fenced block matches the
heading pattern, sets `insec = 0` and `next`s, silently ending the section mid-chain. A four-command
chain containing one `# install deps if needed` line extracted as **one** command. That does not
error: it proves a *subset* green, reports green, writes those lines to the ledger, and merge-gate
GATE 3 then reads them as authoritative for the whole chain. A `# skip on CI` comment in a
customer's CLAUDE.md would have silently disabled everything below it, in both gates. Two lines of
rule ordering, and the comment above them explains why, because this is exactly the kind of change a
future editor "cleans up."

**The four fail-open holes the gate deliberately closes** (`verify-gate.sh:14-42`):

| Hole | How a naive Stop gate fails | What this gate does |
|---|---|---|
| **Stale green** | Trusts the last ledger line; a clean tree lets a prior green stand in for the current state | *"There is NO fast-skip"* (`:17-21`). Every Stop runs the chain and writes a fresh cycle; every line carries `sha` (`:104`, `:354-359`) |
| **Environment-error laundering** | Treats exit 127 / ENOENT / "command not found" as "not a real failure" | *"There is NO env-error laundering"* (`:22-29`). Any non-zero exit is RED, full stop. Missing tooling is an honest block the agent fixes or escalates |
| **Missing `jq`** | Block JSON is built with `jq`; no `jq`, no stdout, `exit 0` → read as ALLOW | `block()` (`:150-159`) uses `jq` when present, and **exit 2 + stderr** when not (`:156-157`) |
| **Hook timeout** | The chain outruns the external hook timeout, the hook is killed mid-run, no block is emitted → silent allow | An internal wall-clock budget under the external timeout (`:112-133`), per-command caps (`:303-324`), and **budget exhaustion treated as RED** (`:331-346`) |

The `jq` fallback is worth dwelling on, because the obvious fix is wrong. The original fallback
hand-rolled escaping for backslash, double-quote and newline. The string it escapes is the tail of a
**failing build's stderr**, which routinely carries tabs, carriage returns and ANSI escapes — raw
control bytes that RFC 8259 requires to be escaped inside a JSON string. One of those produces
malformed JSON, the runtime drops the undecodable payload, and "exit 0 + no decision" is read as
ALLOW: verbatim the fail-open the function exists to prevent. So the fallback emits **no JSON at
all** and uses the contract's other blocking channel instead — `printf '%s\n' "$reason" >&2; exit 2`
(`:156-157`). Exit 2 blocks Stop and feeds stderr back to the agent (`COURSE-REF.md:173`). There is
nothing to malform. `merge-gate.sh:170-187` mirrors it exactly.

**The time budget, in detail** (`:112-133`, `:326-346`):

```bash
BUDGET_DEFAULT=840
[ "$EVENT" = "SubagentStop" ] && BUDGET_DEFAULT=540
BUDGET_TOTAL="${QUETREX_VERIFY_BUDGET:-$BUDGET_DEFAULT}"
```

840s internal against a 900s external Stop timeout; 540s against 600s on SubagentStop. Sixty seconds
of headroom either way — enough to notice exhaustion, write the ledger, and emit a block before the
runtime kills the hook.

The loop recomputes `remaining` before each command and passes it as that command's cap. Two
exhaustion paths, both RED: the budget already spent before a command starts (synthesize `code=124`
rather than skip the rest of the chain unproven), and a command killed at 124/137 (annotated as a
time-budget kill). `run_with_cap()` (`:303-324`) prefers `timeout`, then `gtimeout`, and falls back
to a background SIGKILL watchdog if neither is on PATH — the chain is never unbounded regardless of
what is installed.

**Why exhaustion is RED and not "skipped."** A skipped chain and a green chain are indistinguishable
downstream: both produce no block, and the merge gate later reads a ledger that does not say
"unproven," it just says whatever it last said. Treating a timeout as a pass converts the most
common operational condition — a slow build on a loaded machine — into a silent bypass of the entire
product guarantee. Treating it as red produces a specific, actionable message: *"This is a
TIME-BUDGET kill … treat as red; split or speed up the chain."* The agent is told not to hunt a bug
that does not exist.

**`verifyQuick` subset-ness is mechanically enforced** (`:167-206`, and the reasoning at `:47-52`).
`verify.json` lives in the **customer's** repo, so `verifyQuick` is an untrusted input on the finish
path. Unchecked, `"verifyQuick": ["true"]` passes every SubagentStop — the quick chain becomes an
arbitrary *replacement* for the gate rather than a narrowing of it. The check is a set difference:

```bash
jq -e '((.verify // null) | type) == "array" and ((.verifyQuick - .verify) | length) == 0'
```

On any mismatch — a foreign command, a non-array `verify`, a missing `verify` — the quick chain is
discarded, the **full** chain runs, and `QUICK_NOTE` names the offending entries in the block reason
so the misconfiguration is visible rather than silently weakening the gate.

**The bounded self-heal** (`:379-403`). On red, increment `verify-attempts` — note that the **hook**
increments it, not the agent it bounds — and block with the failing command, exit code and last 20
lines. At `QUETREX_VERIFY_MAX` (default 3, `:71`), `touch` the `ESCALATION` marker and block one
final time instructing the agent to stop self-healing and surface the failure verbatim. A green run
resets the counter and removes `ESCALATION`.

### 3.2 `merge-gate.sh` — PreToolUse, Bash matcher

Purpose (`merge-gate.sh:2-58`): the merge boundary is decided by hooks reading artifacts, never by
an agent's prose. It supersedes `enforce-merge-approval.sh`, which implemented the old
"prompt a human on every merge" policy.

**Vector detection** (`:88-140`). Three merge-to-main vectors, matched whether invoked bare or via
`git -C <dir>` (`GIT_PFX` at `:91` — the worktree form this workflow actually uses):

- `gh pr merge` anywhere in the command;
- `git push` targeting `master`/`main`, **including from a feature branch**, which
  `enforce-branch.sh` cannot catch because it only inspects the current branch;
- `git merge` while the resolved target directory is on `master`/`main`.

Tag pushes are exempt (`:94-99`) — deploy and version tags are not merges. Anything else exits 0
silently. A repo with no `.quetrex/` directory is out of scope entirely (`:153-154`).

**Fail-closed on missing `jq`** (`:70-86`, `:184-187`). The gate first extracts the command
*without* `jq`, via `sed` (`:83-85`), so a missing dependency cannot blind it to the fact that a
merge is happening. If the command is a real merge in a managed repo and `jq` is absent, it
**denies** with an ESCALATE_HUMAN reason rather than allowing an unevaluated merge. This is the
pattern the guard hooks now copy (§6.5).

**The gates.**

**GATE 1 — no `ESCALATION`** (`:193-200`). Present marker → deny, classified ESCALATE_HUMAN, with
the first 800 bytes of the marker inlined. The deny message says explicitly: *do not delete
ESCALATION to force the merge.*

**GATE 2 — verdict is `AUTO_MERGE`, pinned to HEAD** (`:202-246`). Missing verdict → REWORK. Then a
`case` over the verdict string recognizing the three current values plus the legacy `BLOCK`,
`ESCALATE` and `APPROVE`, each with its own deny reason, and a catch-all `""|*` that denies rather
than falling through — an old or partial artifact can never be silently misread as permission. Then
the sha pin: a verdict with no sha is REWORK; a verdict whose sha ≠ HEAD is REWORK with both
twelve-character prefixes in the message.

`git-workflow.md:87-126` now mirrors this contract exactly, including treating the legacy `APPROVE`
as a refusal (`:107`). The two terminal gates previously disagreed about what a passing verdict
looks like — git-workflow gated on `APPROVE`, a string the reviewer never emits — which meant the
happy path was defined differently at each end of it.

**GATE 2b — the reviewer may not self-exempt from independent review** (`:248-275`). This is the
newest gate and the most interesting one, because it mechanizes a rule the reviewer was already
given and had already broken.

`reviewer.md` mandates ESCALATE_HUMAN when the native `/review` or `/security-review` *"errored or
could not run on a non-trivial change."* But the agent that decides the verdict is also the agent
that reports whether independent review ran. That rule is self-graded. In the wild it produced a
verdict artifact recording `AUTO_MERGE` over 18 reviewed files with
`"nativeReview": "not_run_no_pr"` and `"nativeSecurityReview": "not_available_in_env"`.

So the gate reads the field itself (`:268`) and honors an AUTO_MERGE only when the artifact
*affirmatively* records that the native security pass executed:

| `inputs.nativeSecurityReview` | Meaning | Gate |
|---|---|---|
| `clean` | ran, found nothing | allow |
| `issues` | ran, found something the reviewer then adjudicated | allow |
| `not_run_no_pr`, `not_available_in_env`, `errored`, anything else | no independent pass on record | **deny** |
| field or `inputs` object **absent** | no independent pass on record | **deny** |

Absence is treated exactly like an excuse string, on purpose (`:262-265`): GATE 4 already
establishes that omitting a field must never be a cheaper way past a gate than filling it in
honestly. Only `AUTO_MERGE` is checked — `REWORK` and `ESCALATE_HUMAN` already hold the merge above.

**GATE 3 — ledger green *and* commit-pinned** (`:277-322`). For every command in the current verify
chain, its **most recent** ledger entry must have exited 0 **and** carry `sha == HEAD`. Three
distinct conditions block: never ran (absent from the ledger, `exit: null`); latest run non-zero;
latest green proven against a different commit. If `verify.json` cannot be read, the fallback is
conservative — every command *appearing in the ledger* must be green and pinned. An empty result
from a jq failure is itself a deny: the gate never treats "could not evaluate" as "clean."

**GATE 4 — security findings** (`:324-409`). The important part is *when* a security review is
required. Either:

- (a) the plan set `security_review_required: true`, **or**
- (b) **the actual diff touches a sensitive surface**, regardless of what the plan says.

(b) is computed from git, not from the artifact: a ~30-term path regex (`:357`) against
`git diff --name-only "$BASE_BRANCH"...HEAD` (`:354`), and, when the paths are neutral, a second
regex over **added lines only** covering `req.params|query|body`, `findById`, `Object.assign`,
`innerHTML`, `child_process`, `process.env`, `jwt.`, `fetch(`, `axios` and the rest. Deletions are
excluded so removing a risky line does not trigger a review.

The comment states the reason: *"(b) is the floor that makes security non-bypassable: a plan that
simply omits the flag (defaulting it false) cannot ship sensitive code unreviewed, because the gate
inspects the diff itself, not the agent's classification of it."*

This is the design's answer to a whole class of bypass-by-omission. The plan is written by an LLM,
so anything the gate reads *from* the plan is a value that LLM chose. `security_review_required` is
advisory-**up** only at `architect.md:113` — raise it, never lower it — but a prose rule can stop a
mistake, not an omission. Computing the requirement from the diff means the only way to avoid a
security review is to not write sensitive code.

Then: required-but-missing → REWORK; malformed → ESCALATE_HUMAN; `head_sha` ≠ HEAD → REWORK;
any `severity:"critical"` + `status:"open"` → REWORK, with the line *"Human approval CANNOT bypass
an open Critical."*

**GATE 5 — every changed file is covered by the ownership map** (`:411-514`). Until this gate
existed, the artifact the entire parallel-developer architecture rests on was enforced by nobody: it
appeared exactly once downstream, as prose in `reviewer.md` asking an LLM to notice. A developer
editing outside its lane produced course L8's exact failure — clean summary, unexpected file, every
other gate green because none of them look at file paths.

This gate looks. It reuses the `$CHANGED` list GATE 4 already computed and asserts each path is
claimed either by an explicit `ownership` key or by some workstream's `owns` glob (`:486-500`).

Three design decisions inside it are worth knowing:

1. **No plan → skip, not fail** (`:426-433`). Same shape as GATE 4 immediately above: with no plan
   there is no ownership map, so "unowned" is *undefined*, not violated. TRIVIAL and SIMPLE routes
   legitimately run without an architect; failing closed there would deny merges for work that never
   had lanes to stay in — a liveness break, not a safety win.
2. **A plan with no ownership map is malformed and escalates** (`:465-469`). Skipping applies to the
   absence of a plan, never to a plan that forgot its contract.
3. **Which plan governs is resolved more strictly than in GATE 4** (`:439-459`). GATE 4 can afford
   `ls | head -n1` because its worst case is requiring a security review that was not strictly
   needed. GATE 5's worst case is denying a clean merge for violating *another task's* lanes, so it
   refuses to guess: use the plan named by `state.json`, or the single plan on disk, and escalate
   when several exist and nothing says which one this merge is for.

Exemptions (`:471-484`): `.quetrex/**`, because those are control-plane artifacts written by the
pipeline itself rather than by a developer working a lane; and lockfiles (`package-lock.json`,
`pnpm-lock.yaml`, `Cargo.lock`, `go.sum`, `poetry.lock`, and eleven more), because they are
regenerated as a side effect of any dependency change by whichever workstream happened to install,
and owning them would force a false overlap between otherwise-disjoint lanes.

**Allow** (`:516-518`). Emitting nothing on a PreToolUse hook means "no decision," so the normal
permission flow proceeds and the merge runs. Silence is the allow path; every deny is explicit.

### 3.3 Why the two gates are per-project, not global

Stated at `install.js:44-52` and again at `quetrex-install-project-gates.sh:10-16`: the gates are
deliberately excluded from the **global** settings template because `verify-gate` autodetects a
chain from any `package.json` and would otherwise start gating every unrelated repo on the
operator's machine. They belong to a repo that opted in via `/q-init`.

`assertHooksInstalled` asserts this direction too — a per-project gate found wired in
`~/.claude/settings.json` is an install **failure**, not a bonus (`install.js:597-605`).

The corollary is the rule the installer states in its own header — *"a cloud routine only ever sees
what is committed, never the operator's global `~/.claude`"* — which is exactly the rule this repo's
own committed settings used to violate.

---

## 4. How a repo gets the gates

`quetrex-install-project-gates.sh` is the per-project deployment channel. Its contract (`:21-30`):
idempotent (re-running never duplicates an entry), non-destructive (never removes or overwrites
anything it does not own), scoped (reads only from `$SRC_HOME/.claude`, writes only under the given
root — enforced by an explicit containment loop at `:66-73`).

It copies seven hooks (`:78`) — `verify-gate`, `merge-gate`, `edit-gate`, `secret-scan`,
`deny-guard`, `enforce-branch`, `session-state`; the guards and `session-state` are included so that
*every* wired path resolves in a fresh clone — and the seven agents (`:98`). It wires settings
structurally with a temp node script (`:125-238`), never with heredoc JSON, matching existing
entries by basename so a re-run is a no-op and a user's own hooks are untouched, and re-parses the
file it wrote to confirm valid JSON. It seeds `.quetrex/verify.json` from the template once and
never overwrites (`:245-253`).

`:14-18` records the maintenance invariant that keeps the two channels honest:

> The wiring here is the mirror of the committed `.claude/settings.json` in quetrex-base itself. Any
> hook added or removed there must be added or removed here too, or the gates stop travelling.

And `:203-205` records why the timeout column is not cosmetic:

> Timeouts are SECONDS. verify-gate derives its whole fail-closed budget from the external timeout,
> so 900 (Stop) / 600 (SubagentStop) are load-bearing.

That is not hypothetical. The live global settings on the development machine carried 5000, 10000
and 3000 in the same field — off by ~150×, because someone read it as milliseconds. A hung
`deny-guard.sh` would have stalled the session for 83 minutes and `auto-format.sh` for nearly three
hours. `install.js` now fails the install on any quetrex-owned wired timeout above 900 and warns on
a user's own (`install.js:609-625`).

---

## 5. Commit-pinning — the strongest idea in the system

### 5.1 The threat model: stale green

Every gate of this shape answers the question *"is the code green?"* The question is malformed. The
answerable question is **"is *this commit* green?"**

The gap between them is where stale-green lives:

```
t0  QA runs the chain. All green. The ledger says green.
t1  A developer pushes one more commit — a "small fix", a lint autofix, a rebase.
t2  The reviewer reads the diff it was handed and writes AUTO_MERGE.
t3  Some later stage commits. HEAD moves again.
t4  merge-gate reads: verdict AUTO_MERGE, ledger green, findings clean.
    Every artifact is truthful. Every artifact describes a commit that is not the one merging.
```

Nothing lied. Every gate passed. The code that ships was never proven. This is not exotic — it is
the *default* behavior of any gate that records a boolean instead of a binding, and it is most
likely to occur on the **happy path**, because the happy path is exactly where extra commits land
between stages.

Anthropic's course has no concept of it. Its Stop-hook sketch (`COURSE-REF.md:311-316`) records that
tests ran; it does not record what they ran against.

### 5.2 The three independent pins

Each artifact names the commit it describes, and each is checked separately at the merge boundary.

**Pin 1 — the ledger `sha`.** Written on every line by every writer: `verify-gate.sh:104` computes
`HEAD_SHA` once and `:354-359` writes it into each line; `qa.md`'s `run()` helper does the same,
with a comment recording that omitting it is what once caused a fully clean pipeline to be denied;
`git-workflow.md:190-200` re-runs the entire chain and appends fresh pinned lines. Checked at
`merge-gate.sh:287-300`.

**Pin 2 — the verdict `sha`.** `reviewer.md:313` requires it to equal `git rev-parse HEAD` at review
time. Checked at `merge-gate.sh:239-246`.

**Pin 3 — the findings `head_sha`.** `security-reviewer.md:70` records it; checked at
`merge-gate.sh:394-397`.

A fourth pin now rides alongside them: `qa-report.json.sha`, checked by the *reviewer* rather than
the merge gate (`reviewer.md:187`), so a coverage-gap report from an earlier commit cannot stand in
for the current one.

The pins are independent because they are written by different agents at different times and checked
by different code paths. A single agent forgetting, crashing, or lying about its pin fails its own
gate and no other.

### 5.3 The design decision that keeps them aligned: git-workflow adds no commit

The obvious way to keep three pins on one commit is to re-pin them whenever HEAD moves. The system
does the opposite, and the reasoning is worth preserving.

`git-workflow.md:128-158` — **the normal path adds no commit at all.** Every upstream stage commits
its own work: developers commit the code they own, QA commits the tests it authored and re-proves
the chain at that commit. By the time the review-gate ran, the change was fully committed and the
verdict is pinned to that commit. So the expected state at the terminal stage is *nothing to stage*.
Three cases:

- **Case A — clean tree.** Add nothing, commit nothing. HEAD is exactly the sha the verdict and the
  ledger are pinned to.
- **Case B — only ignored runtime artifacts remain.** `.quetrex/` control files are runtime control
  plane, not source. They are git-ignored and must never be committed: committing them both moves
  HEAD *and* puts a machine-written gate artifact into the reviewed history. Treat as Case A.
- **Case C — genuine uncommitted source or test changes.** **Refuse.** The reviewer never saw them,
  and committing them would advance HEAD past the sha the verdict is pinned to, producing exactly
  the stale-verdict denial the merge gate exists to enforce. This is a bounce back through the
  pipeline, and it deliberately does not burn a `review_iter` — that counter only advances on a
  REWORK verdict.

And the rule that closes the tempting shortcut, `git-workflow.md:157`:

> **Never re-point the verdict.** If you are ever tempted to "just update `.sha`" in
> `review-verdict.json` so the merge gate is satisfied, stop: that would assert a review of a commit
> no reviewer read, and it would destroy the single guarantee the sha-pin provides.

The distinction at `:174-178` is the general principle, and it is the one to remember:

> The ledger is the one artifact a later stage may legitimately re-pin, because re-pinning it means
> **re-running the commands and observing exit 0 again** — the evidence is regenerated, not
> relabelled. That is the opposite of editing a verdict's sha, which would relabel a judgment nobody
> re-made.

**Evidence may be regenerated. Judgment may not be relabelled.**

This also replaced a genuine deadlock. The stage previously ran `git add -A`, which swept the
untracked `.quetrex/` directory into the commit, moving HEAD after the verdict was pinned; and
git-ignoring `.quetrex/` without changing the staging would have left nothing staged, so the stage
stopped instead. Both branches were broken, and both were invisible because merge-gate was not
wired. The fix is all three parts together: whitelist gitignore (`.gitignore:24-36`), explicit-path
staging, and no commit on the happy path.

### 5.4 §2a — re-proving the ledger in the right tree

`git-workflow.md:160-207` still re-runs the full chain, for a reason unrelated to its own commit:

> In the mandated worktree flow, the main-agent Stop hook resolves `ROOT` to `CLAUDE_PROJECT_DIR` —
> the MAIN checkout, not this worktree — so its sha-pinned ledger writes land in the MAIN
> directory's `.quetrex/`, never in THIS worktree's `verify-ledger.jsonl`, which is the ledger
> merge-gate.sh actually reads when the merge runs from this worktree.

So the chain is re-run at the current HEAD in *this* `$ROOT`, appending fresh sha-pinned lines.
Because §2 added no commit, that HEAD is the same commit the verdict is pinned to — which is
precisely what GATE 2 and GATE 3 jointly require. Any non-zero exit is a gate failure: write the
reason, refuse, stop.

### 5.5 The property the pins buy

**A green proven against an earlier commit cannot authorize a later one.** As an invariant: for a
merge to proceed there must exist a commit *c* such that the ledger, the verdict and the findings
all name *c*, and *c* is HEAD. Not "the work was verified" — *this* commit, verified.

It fails closed in an annoying direction: a genuinely clean pipeline is denied if any stage forgot
its pin. That is the bug `test/merge-gate.test.sh:5-14` was written for, and it is the correct
direction to be annoying in.

---

## 6. The hook contract

### 6.1 Events used and not used

Committed wiring is `.claude/settings.json:34-141`; the plugin mirror is `hooks/hooks.json`.

| Event | Used | What runs |
|---|---|---|
| `SessionStart` (`startup｜resume｜compact`) | yes | `session-state.sh` — re-inject durable state on a fresh start, a resume, and after a compact |
| `UserPromptSubmit` | yes | `workflow-reminder.sh` |
| `PreToolUse` (Bash) | yes | `deny-guard.sh`, `secret-scan.sh`, `enforce-branch.sh`, `merge-gate.sh` (60s) |
| `PreToolUse` (Write\|Edit) | yes | `secret-scan.sh` |
| `PostToolUse` (Write\|Edit) | yes | `auto-format.sh`, `edit-gate.sh` |
| `Stop` | yes | `verify-gate.sh` (900s) |
| `SubagentStop` | yes | `verify-gate.sh` (600s) |
| `PreCompact` / `PostCompact` | **no** | deliberately — everything worth preserving is on disk, and PostCompact's output never reaches the conversation (`COURSE-REF.md:144`) |
| `InstructionsLoaded` | not yet | worth it as an **audit trail** (log the loaded set with mtimes and hashes), not as a linter |

`SubagentStop` is newly registered and matters more than its one line suggests. In a pipeline whose
defining feature is parallel worktree developers, it is the event that gates a *subagent* on finish.
Until it was wired, `verify-gate`'s entire quick-chain code path had never executed in production.

`SessionStart` with the `compact` source is the correct event and `PostCompact` is not — this is an
explicit course gotcha (`COURSE-REF.md:144`). It also needs no JSON contract at all: on
`SessionStart`, plain stdout is added to context (`COURSE-REF.md:168`). Because state lives on disk,
re-injection is cheap and safe — the hook re-reads ground truth rather than summarizing chat. What
it must carry: `state.json` (`task`, `review_iter` — else the bounded loop silently restarts from
zero), **`ESCALATION`** (most dangerous to lose, because an agent that forgets it resumes
self-healing and a subsequent green *deletes* it), the plan (post-compaction, `architect.md:12`'s
"if it's not in the artifact it doesn't exist" becomes literally true and the ownership ban is
unenforceable), `verify-attempts`, the verdict `.sha`, and the current branch and worktree path.

### 6.2 Exit-code semantics — memorize these

From course L5 (`COURSE-REF.md:166-173`), non-negotiable:

| Exit | Meaning |
|---|---|
| **0** | Success. If stdout is JSON, it is parsed. On `SessionStart`, `UserPromptSubmit` and `UserPromptExpansion`, **plain stdout is added to context** |
| **2** | **Blocking error. stderr is fed back to Claude as context.** The blocking exit code almost everywhere, including Stop |
| **1** | **Does NOT block.** "It feels like an error, but Claude runs the command anyway" |
| anything else | Non-blocking; stderr logged, execution continues |

Two derived rules the code follows:

**PreToolUse blocks by printing JSON and exiting 0** — `merge-gate.sh:170-187`,
`deny-guard.sh:74-…`, `secret-scan.sh`, `enforce-branch.sh`:

```json
{"hookSpecificOutput":{"hookEventName":"PreToolUse",
  "permissionDecision":"deny","permissionDecisionReason":"..."}}
```

**Stop/SubagentStop block by printing `{"decision":"block","reason":...}` and exiting 0** —
`verify-gate.sh:150-160`. The header at `:62-66` states the trap: *"Printing block JSON then exiting
non-zero DISCARDS the JSON."* The script therefore always `exit 0` after emitting, and emits nothing
at all when it allows.

The 127 corollary is why §10.1 exists: a hook whose script does not exist exits 127, which is
"anything else," which is non-blocking, which is silent. **A broken enforcement hook and a passing
one are indistinguishable from inside the session.** That is also why the install-time assertion
must check *reachability from a settings file* and not file presence (§8.1) — a guard pointed at the
wrong invariant is worse than no guard, because its passing is read as proof.

### 6.3 Why a PreToolUse deny fires beneath `bypassPermissions`

`merge-gate.sh:49-53` states it, and `deny-guard.sh:8-11` restates it:

> A deny wins over any allowlist/auto-mode allow (precedence: deny > ask > allow), and a blocking
> PreToolUse hook runs BEFORE the permission engine — so this fires even under
> `--permission-mode auto`, `bypassPermissions`, or `--dangerously-skip-permissions`.

**What it buys.** The pipeline runs `developer` and `qa` under `bypassPermissions` and the whole
session under `defaultMode: dontAsk` with `skipDangerousModePermissionPrompt: true`
(`.claude/settings.json:33`, `:140`). Without this property that combination would be a total
abdication: no prompts, no classifier, no floor.

With it, there is a floor no permission setting can lift:

- no recursive delete of root/home/current/parent or a system directory (`deny-guard.sh`);
- no `git reset --hard`, no `git clean -f`;
- no hardcoded secret written to a file or embedded in a command (`secret-scan.sh`);
- no commit or push on `main`/`master` (`enforce-branch.sh`);
- no merge without every artifact green and pinned (`merge-gate.sh`).

The course covers hooks (L5) and permission modes (L4) in separate lessons and never connects them.
Connecting them is what makes a genuinely unattended run defensible: **the operating envelope is
enforced by code the operating envelope cannot reach.**

### 6.4 `updatedInput` — redaction instead of refusal

The lesser-known PreToolUse move (`COURSE-REF.md:164`, `:175`): instead of denying, **rewrite the
call.** The hook spots a secret pattern and swaps in a placeholder before the command executes. The
command still runs, the work still gets done, the secret never made it through.

**The caveat that bites: `updatedInput` replaces the whole input object.** Echo back every field you
are not changing or you lose them. For the Bash matcher, build it as
`.tool_input | .command = $redacted` — never construct a fresh `{command: ...}`, which silently
drops `description`, `timeout`, `run_in_background` and anything the runtime adds later.

Policy, per finding 29: adopt redaction for `secret-scan.sh`'s **Bash** matcher only. In a command
string the secret is usually incidental (a token pasted into a `curl`), and a redacted command fails
at the remote with a clear auth error — better feedback for an unattended agent than a refusal it
may thrash against. **Keep `deny` for Write|Edit**: a silently-placeholdered key written into source
produces a file the agent believes holds a working credential, which is worse than a refusal.
Substitute globally, not `head -n1`. **Tier B (the entropy heuristic) stays deny** — it is heuristic
by design and must not silently corrupt a value it guessed wrong about.

### 6.5 The other hooks

| Hook | Event | Reads | Blocks | Network |
|---|---|---|---|---|
| `deny-guard.sh` | PreToolUse[Bash] | `.tool_input.command` | catastrophic deletes, `reset --hard`, `clean -f`, unsafe force-push | no |
| `secret-scan.sh` | PreToolUse[Bash, Write\|Edit] | command / content / new_string | provider-prefix tokens; high-entropy value on a secret-named key | no |
| `enforce-branch.sh` | PreToolUse[Bash] | command + cwd | `git commit`/`git push` while on main/master; tag pushes exempt | no |
| `merge-gate.sh` | PreToolUse[Bash] | the `.quetrex/` artifacts | any merge whose artifacts are not green and pinned | no |
| `edit-gate.sh` | PostToolUse[Write\|Edit] | the edited file | feeds a type/lint error straight back via exit 2 | no |
| `auto-format.sh` | PostToolUse[Write\|Edit] | `.tool_input.file_path` | nothing — formats and exits 0 | no (see `SECURITY.md`) |
| `session-state.sh` | SessionStart[startup\|resume\|compact] | the `.quetrex/` artifacts | nothing — prints state into context | no |
| `workflow-reminder.sh` | UserPromptSubmit | — | nothing — prints a standing preference | no |

`SECURITY.md` is the customer-facing version of this table, and `.claude/CLAUDE.md:8` makes keeping
it current a repo rule rather than a documentation courtesy:

> Adding, removing or re-wiring a hook means updating the hook table in `SECURITY.md` in the same
> change — that table is a customer-facing contract, not documentation.

Its headline claim is `SECURITY.md:15-17`: *no Quetrex hook opens a network connection, and no
Quetrex hook transmits your code, your commands, your credentials, or any telemetry anywhere.* That
sentence is only true because `check-quetrex-update.sh` — the only hook that made a network call,
and the least valuable one — is on the superseded list and gets unwired and pruned on install
(`install.js:74-78`). For an enforcement product sold to other companies, that sentence is worth
more than the feature it cost.

**`secret-scan.sh`'s two tiers** are worth understanding as a pattern. **Tier A** is provider-prefix
regexes — `AKIA`, `sk_live_`, `ghp_`, `glpat-`, `xox[baprs]-`, JWTs, credentialed connection URIs —
unambiguous, fires unconditionally. **Tier B** is a Shannon-entropy heuristic scoped to *an
assignment beside a secret keyword*: it requires both a keyword match and entropy > 4.0 over a
≥20-char token. The scoping is the point, and the comment says why: *"so ordinary hashes / lockfile
digests / git SHAs do NOT trip it (false positives erode trust in the gate)."* A gate that cries
wolf gets disabled, and a disabled gate is worth less than no gate, because it is still believed in.

**`deny-guard.sh` matches tokens, not substrings** (`:23-36`). The original matcher looked for
`reset --hard` / `push --force` / `git commit` anywhere in an arbitrary shell string, which denied
real, safe commands:

```
grep -rn "git reset --hard" docs/      # the phrase is the SEARCH PATTERN
git push --force-with-lease origin/x   # the SAFE form, and the standard post-rebase remedy
```

It now splits the command into pipeline segments — quote-aware, so a separator inside a quoted
literal does not split and quoted text is never read as a command — and inspects the **first token**
of each segment, the same shape the `rm` rule always used. Text that merely *mentions* a dangerous
command is not a dangerous command.

The escape hatch is explicitly not weakened (`:34-36`): if a segment pipes into a bare shell
(`... | bash`), the segment's literal text really is about to be executed, so the legacy
whole-string substring scan is applied as a backstop.

**The matching `permissions.deny` entry had to go with it.** `settings.json` also carried
`Bash(git push --for` + `ce:*)`. Permission patterns are **prefix** matches, so that rule denied
`--force-with-lease` at the permission-engine level — re-creating the false positive one layer
above the hook that had just been fixed to avoid it. It is removed. Nothing is weakened by the
removal: `deny-guard.sh` denies the unconditional form and allows the leased form, and a
`PreToolUse` deny fires **beneath** the permission engine (§6.3), so it holds under
`bypassPermissions` where a `permissions.deny` entry is the weaker of the two anyway. The coarse
rule bought no coverage the hook did not already have, and cost a legitimate operation the
worktree workflow depends on.

**All four guard hooks now fail closed on a missing `jq`** (`deny-guard.sh:13-21` and the same shape
in the others). The old form was `cmd=$(jq -r … 2>/dev/null); [ -z "$cmd" ] && exit 0` — a missing or
erroring `jq` silently disabled the gate with no trace. Now `jq` is preferred, merge-gate's jq-free
`sed` extraction is the fallback, and input that carries a command but cannot be parsed exits 2 with
a message on stderr. It is never treated as "nothing to inspect."

**Superseded hooks** (`install.js:74-78`) — `security-check.sh` (a strictly weaker duplicate of
`secret-scan.sh`), `enforce-merge-approval.sh` (superseded by merge-gate; it returned
`permissionDecision:"ask"` on every `gh pr merge`, and course L4 names that exact failure —
`dontAsk` exists so *"the pipeline keeps moving instead of hanging on an approval no one is there to
give"*, `COURSE-REF.md:127`), and `check-quetrex-update.sh`. All three were supposedly dropped in an
earlier commit, but the installer reconciles hooks *additively by basename*: it could add a gate and
never remove one, so the removal half never landed on any machine that already had quetrex
installed. The `SUPERSEDED_HOOK_SCRIPTS` list exists to make removal reach existing installs, and
`assertHooksInstalled` fails the install if any of them is still wired (`:606-611`).

---

## 7. The permission model

### 7.1 The six modes

| Mode | Behavior (`COURSE-REF.md:106-113`) |
|---|---|
| Manual | Reads only without prompting; everything else asks |
| Accept edits | Reads, file edits, and common filesystem bash commands without asking |
| Plan | Reads only; proposes without editing |
| Auto | Accepts everything, **with a separate classifier model reviewing each action before it runs** |
| Don't ask | **Only pre-approved tools allowed. Everything else auto-denied, no prompt** |
| Bypass permissions | Skips all checks; `--dangerously-skip-permissions`. Intended for an isolated container or VM |

### 7.2 What the pipeline uses where

| Where | Mode | Why |
|---|---|---|
| session default | `dontAsk` (`.claude/settings.json:33`) | the mode for unattended runs — no prompt can hang a routine at 3am |
| `developer`, `qa` | `bypassPermissions` | high-volume edit/run loops in a disposable worktree; the hook floor still applies |
| `database-architect` | **inherit — explicitly no bypass** (`database-architect.md:13`) | irreversible operations keep the permission engine in the loop |
| `git-workflow` | `acceptEdits` | it edits nothing; it needs filesystem bash |
| `architect`, `reviewer`, `security-reviewer` | inherit | tool restriction already does the work |

The `permissions.allow` list (`.claude/settings.json:7-20`) is what makes `dontAsk` workable —
`Bash(git push:*)`, `Bash(gh pr:*)`, `Bash(git merge:*)`, `Bash(npm run:*)` and so on. The `deny`
list (`:21-32`) is a coarser floor beneath the hooks.

`git-workflow` under `acceptEdits` is the fragile square. Its job is `git push` and `gh pr create`,
neither of which is a "common filesystem bash command" under L4's definition. They run silently
**only** because `Bash(git push:*)` and `Bash(gh pr:*)` are allowlisted. This matters enormously for
plugin distribution — §8.3.

### 7.3 The honest limitation: `dontAsk` has no classifier

Course L4 is specific: auto mode's classifier **guards intent**, watching for actions that escalate
beyond what was asked, designed to block production deploys and migrations, force pushing, piping
downloaded code into a shell, **sending sensitive data to external endpoints**, and destroying
session-critical files (`COURSE-REF.md:117`). `dontAsk` has none of that — it is a static allowlist.
Course L8 additionally recommends keeping unattended runs in *auto*, not bypass, precisely to keep
the classifier (`COURSE-REF.md:303`).

Quetrex chooses `dontAsk` anyway, and the choice is correct for this product: the classifier's
terminal action is to **ask**, and there is nobody there to answer. A routine that stops for an
intent question at 3am is a broken product. But state the tradeoff honestly:

> **The hooks are carrying the classifier's load, and they cover less than it does.**

The one item on the classifier's block list that no quetrex hook covered was **secret egress**.
`secret-scan.sh` inspected literal command and file content only; a
`curl -X POST … -d @$HOME/.claude/secrets.env` was verified allowed — exit 0, no output — because
the secret never appears in the command string, so neither tier fired.

`[AS BUILT]` finding 14 — `dontAsk` is kept and the coverage is now a rule inside `secret-scan.sh`'s
Bash matcher: it fires when a command names a secret **path** (`secrets.env`, `.env[.x]`,
`auth.json`, `credentials.json`, `id_rsa`/`id_ed25519`/`id_ecdsa`, `.npmrc`, `.pgpass`, `.netrc`)
in the same command as an egress verb **leading a pipeline segment** (`curl`, `wget`, `nc`, `ncat`,
`netcat`, `telnet`, `ftp`, `sftp`, `http`, `xh`), or `scp`/`rsync` **plus** a remote-looking target.
The extra conditions are what keep `cat .env` and `source .env && npm run build` allowed.

It emits **`ask`**, not `deny` — legitimate deploys do read env files, and in an interactive session
the prompt is the right outcome. Note the interaction with §6.3: an `ask` under `dontAsk` in a
genuinely unattended routine resolves as a stop with no prompt, which is the correct conservative
behavior for the one action class that is unrecoverable when wrong, and it does not hang the run.

---

## 8. Distribution — three channels, and why all three exist

| Channel | Installs to | Carries | Fails when |
|---|---|---|---|
| **Global npm** (`install.js`) | `~/.claude/` | hook scripts, agents, commands, skills, `settings.json` merge, `quetrex-doctrine.md`, `secrets.env` scaffold | a machine that never ran it — CI, a cloud clone, a new laptop |
| **Per-project committed gates** (`quetrex-install-project-gates.sh`, via `/q-init`) | `<repo>/.claude/` + `<repo>/.quetrex/` | the 7 gate/guard hooks, the 7 agents, committed `settings.json` wiring, `verify.json` | never — it is in the repo |
| **Plugin** (`.claude-plugin/plugin.json`, `hooks/hooks.json`) | per-user, via marketplace | skills, agents, hooks, commands, per-agent `permissionMode` in frontmatter | it cannot carry `permissions.allow` |

### 8.1 The global install

`install.js` copies the package's `.claude` tree into `~/.claude`, merging `settings.json`
structurally rather than overwriting, unioning only `allow`/`deny`/`ask` primitive arrays so
package-added permissions reach existing installs without clobbering user scalars. Hook entries are
reconciled by **basename** — append what is missing, never duplicate, never touch a user's own
entry. Pruning is manifest-driven: the installer never deletes a file it cannot prove it wrote on
this machine, always backs up first, rejects `../` paths and enforces containment. `settings.json`
is never pruned, because pruning it would wipe the user's entire global config.

Three properties that were added or corrected, each closing a real defect:

**`PROTECTED` now includes `CLAUDE.md`** (`install.js:15`). It previously protected only
`secrets.env`, so `~/.claude/CLAUDE.md` fell to a full overwrite on every `npm i -g`, deleting the
user's `#LESSONS` — reproducibly, on every update. The generic doctrine moved to
`.claude/quetrex-doctrine.md`, shipped to `~/.claude/quetrex-doctrine.md` and *imported* by a
never-overwritten `CLAUDE.md`. That also fixes the scope violation underneath it: this repo's
project `CLAUDE.md` is now 23 lines about *this repo* (`.claude/CLAUDE.md:1-23`) instead of ~95
lines of global doctrine checked in at project scope, where it stacked with the user file and
contradicted it on the one verbatim mandate. Course L2 is right that every line competes with every
other line for attention (`COURSE-REF.md:35`); the fix is one owner per scope.

**`SUPERSEDED_HOOK_SCRIPTS` gives the installer a removal path** (`:66-70`, applied at `:482-…`).
See §6.5.

**`assertHooksInstalled` checks reachability, not bytes** (`:546-…`). The check now verifies seven
things, of which the fourth is the one that matters (`:76-…`, `EXPECTED_GLOBAL_WIRING`):

1. every global hook script exists and is executable;
2. the per-project gate scripts exist;
3. `settings.json` re-parses;
4. **every expected hook is reachable from its expected event** — *"an unreferenced hook never runs
   and fails silently"*;
5. the per-project gates are **not** wired globally (§3.3);
6. no superseded hook is still wired;
7. every wired timeout is a sane number of **seconds** (≤ 900), a failure for quetrex-owned hooks
   and a warning for the user's own.

The predecessor of this function printed `INSTALL FAILED — the enforcement channel is broken` and
exited 1, while checking only that the files existed and were executable. Its own comment said the
channel "must be real, not just copied bytes" and the check was exactly copied bytes. That is how a
P0 written to fix unreachable hook paths shipped without fixing them: **a loud, well-written guard
pointed at the wrong invariant, whose passing was read as proof.** If you change the wiring, change
`EXPECTED_GLOBAL_WIRING` in the same commit, or the assertion silently stops asserting the thing you
care about.

### 8.2 The per-project committed gates — why this channel cannot be deleted

Stated at `quetrex-install-project-gates.sh:10-16`:

> This is what makes the build gates fire both locally AND in any Anthropic cloud routine that
> clones the repo — **a cloud routine only ever sees what is committed, never the operator's global
> `~/.claude`.**

A routine starts from a fresh clone (`COURSE-REF.md:205`). There is no `$HOME/.claude`, no npm
global — there is the repository. Therefore **anything that must run in a routine must be committed
to the repository, with paths that resolve relative to the repo.** Hence the fixed
`${CLAUDE_PROJECT_DIR:-.}` command form, and hence `.claude/CLAUDE.md:6` stating it as a rule with
its reason attached.

This is also why the per-project installer survives the plugin: **a plugin installs per-user.** It
replaces the *global* channel only. Delete the per-project installer and routines lose all
enforcement — silently, per §6.2.

### 8.3 The plugin — what it can and cannot carry

`.claude-plugin/plugin.json` names the plugin **`q`**, so commands namespace as `/q:task-build`,
`/q:init`, `/q:deploy` — shorter than either `/quetrex-factory:q-task-build` or the pre-rename
state, and `name` is the only required manifest field (`COURSE-REF.md:366`). `hooks/hooks.json`
mirrors the committed wiring with `${CLAUDE_PLUGIN_ROOT}/.claude/hooks/<name>.sh` paths — the real
location of the scripts. It pointed at `${CLAUDE_PLUGIN_ROOT}/hooks/`, where nothing has ever
existed, until integration; `test/install.test.js` now asserts every plugin path resolves to a file
that exists, because a hook that is not there exits 127 and 127 is non-blocking (§6.2).

**Carries fine:** hooks (`hooks/hooks.json` wires them identically); per-agent `permissionMode` in
agent frontmatter; skills, agents and commands, namespaced under the plugin name. So the enforcement
model does **not** depend on writing `settings.json`.

**Cannot carry:** `permissions.allow`. A plugin may ship a `settings.json` but Claude Code honors
**exactly two keys** from it — the agent and subagent status-line keys (`COURSE-REF.md:345`).

That single gap has a concrete consequence: **`git-workflow` hangs unattended.** Per §7.2 it runs
under `acceptEdits`, and `git push` / `gh pr create` are not filesystem bash commands; they run
silently today only because of the allowlist entries at `.claude/settings.json:15,17` — exactly what
a plugin cannot ship. Under a plugin-only install the terminal stage stops and waits for a human who
is not there.

Mitigation: deliver the allow-list via `/q-init` into the customer's project settings, alongside the
gates. Sweep the nine `source ~/.claude/lib/...` call sites in `.claude/commands/*.md` to
`${CLAUDE_PLUGIN_ROOT}` — they fail at *runtime inside a command*, not at install, which is the
worst place to discover them. Port `assertHooksInstalled` to a SessionStart hook, which is strictly
better than the npm version because it re-checks every session.

The rest of `install.js`'s sophistication — manifest pruning, backups, symlink defense, structural
settings merge — is defensive machinery made necessary by writing into a directory it does not own.
A plugin owns its directory. That machinery does not need porting.

### 8.4 Licensing

A private git-sourced marketplace's access control is just the git repo's, no stronger than the
current `npm install -g github:` path, and neither claws back files a customer already has. **The
enforceable boundary already exists: the kanban API token.** Without a token every `q-task-*` command
is inert markdown; revoke it and the product stops everywhere, simultaneously and retroactively. Do
the seat check and expiry server-side at token issuance; use the marketplace for discovery and
versioning only; distribute with as little friction as possible.

---

## 9. Automation — routines versus headless

### 9.1 The spectrum

Routines run on Anthropic's infrastructure: a prompt + a repository + connectors, triggered by cron,
**an HTTP POST to the routine's API endpoint**, or a GitHub event (`COURSE-REF.md:189-195`). Headless
`-p` runs from your own code with full control.

Three routine limits to design against (`COURSE-REF.md:202-205`): research preview; a recurring
schedule runs **at most hourly**; each run starts from a fresh clone of the default branch and can
only push to **`claude/`-prefixed branches** unless loosened per repo.

### 9.2 Why the pipeline must not run under `-p` or `--bare`

This is the single most dangerous thing an operator can do to this system, and it is one flag.

`claude --help`, verbatim:

```
--bare  Minimal mode: skip hooks, LSP, plugin --settings, --agents, --plugin-dir.
```

And `-p` / `--print` **skips auto-discovery of hooks, skills, plugins, MCP servers, and the
CLAUDE.md file** (`COURSE-REF.md:211`). Course L6 recommends `--bare` for CI determinism (`:230`).

So the natural CI move turns the entire enforcement layer off. And per §6.2, **a run with no hooks is
indistinguishable from a run whose hooks all passed** — same exit code, same output, same green.

**Rule: `--bare` is forbidden for any invocation that runs a quetrex pipeline stage.** Not
discouraged — forbidden, with the reason recorded next to the ban, because the flag's own help text
makes it sound like a performance option. The ban is written where someone about to violate it will
be standing: a boxed comment at the top of `.github/workflows/claude-review.yml:12-23`.

Routines do not have this problem: they load committed configuration from the clone, and the
machinery that makes committed configuration work is already built (§8.2).

**What `-p` is legitimately for.** Stateless leaf calls where there is nothing to gate: task
classification, slug derivation, extracting a field from a diff. Pair it with
`--output-format json --json-schema` so the result lands in `structured_output` and can be parsed
rather than interpreted (`COURSE-REF.md:213-220`). If headless must run something heavier, pass
`--settings` with an **absolute path** so configuration is explicit rather than discovered.

### 9.3 CI — the reviewer that cannot grade its own homework

`.github/workflows/verify.yml` runs the project's one verify chain on every PR. Its header states
the reason: the Stop gate and the merge gate both read a ledger written on the developer's machine —
the right place for the fast loop, but it means the agent producing the work is also the process
producing the evidence. CI re-derives the same evidence somewhere an agent cannot reach, and
publishes its ledger as an artifact so CI's ledger can be diffed against the branch's.

`.github/workflows/claude-review.yml` runs the review-gate in a runner. The verdict is still written
to `review-verdict.json` by Claude, but **a separate shell step — which Claude cannot influence —
turns that file into the job's exit status and a check run.** "Review did not run" becomes a red
job, not a field in a JSON file the reviewer wrote about itself. Together with merge-gate's GATE 2b
(§3.2), the self-exemption path is closed at both ends: mechanically at the merge boundary, and
independently in CI.

Note the deliberate exception to §9.2's `--bare` ban: this invocation is a *reviewer*, not a pipeline
stage — and the workflow's own comment block spells out that `--bare` is still forbidden *here*,
because the prompt depends on the agent definitions `--bare` would skip.

Both workflows carry an explicit **OWNER ACTION** note: `verify.yml` is only advisory until "verify
chain" is made a required status check on the default branch, and `claude-review.yml` cannot start
until `/install-github-app` has run and `ANTHROPIC_API_KEY` is set. A workflow that exists but is not
required is documentation.

**Managed Code Review composes but cannot gate.** It never approves or blocks, has no autofix, and is
team/enterprise only (`COURSE-REF.md:254-257`). For a per-seat BYO-compute product, partners on
Pro/Max will not have it. Free upgrade where the plan allows; never a required stage.

### 9.4 The routine trigger — where the product model becomes real

`[INTENT]`, finding 19. As built, "routine-fired kanban" does not exist: `quetrex-api.sh` is entirely
outbound (terminal → kanban), nothing fires inbound, `/schedule` is referenced nowhere, and the
approval gate in `/q-task-build` is a conversational turn in a terminal that must stay alive across
the wait.

Course L6's **HTTP POST trigger** is the exact primitive that closes this — the only documented
mechanism by which the kanban can start a run on Anthropic's infrastructure with no terminal alive.
Design: kanban `scope_approved` → POST to a per-project build routine; create the routine from
`/q-init` via `/schedule`; record the endpoint in `.quetrex/project.json`; split `/q-task-build` at
the approval gate. An hourly cron is a **reconciliation** path for dropped POSTs, never the primary
path — 60-minute latency breaks the product promise.

### 9.5 The branch-prefix constraint

`[AS BUILT — repo side]`, finding 20. Routines can only push to `claude/*`, and every branch
quetrex created was `feature/*`. The repo side is now closed: `.quetrex/project.json` carries a
`branchPrefix` (chosen and backfilled by `/q-init`), and `q-task-build`, `q-task-rework` and
`dev-pipeline.md` construct every branch from it — `feature/` is hardcoded nowhere. Setting it to
`claude/` makes the pipeline work under the restriction unchanged, so loosening the restriction is
now a preference rather than a blocker. The analysis below is what that fix was derived from, and
it still describes what happens on any repo whose prefix is left at the default:

- **Survives:** worktrees; local sub-branch commits (merged locally, never pushed); merge-gate's
  `main...HEAD` diff (the default branch is what was cloned); the reviewer's diff range.
- **Breaks:** `git-workflow`'s `git push -u origin "$BRANCH"` — and with no push there is no PR and
  the pipeline has no terminus. Also breaks `/q-init`'s own `feature/q-init-adopt` push.
- **Untested, do not assume:** whether `gh pr merge` is affected, since that is an API merge under
  the token's permissions, not a push.

Sequencing matters: **wire merge-gate first, then loosen per repo.** The `claude/*` restriction was
the only real guardrail keeping an autonomous run off main while quetrex's replacement was inert.
Now that merge-gate is wired, ship `branchPrefix` in `project.json` as the fallback.

---

## 10. Operations

### 10.1 Proving a gate actually fires

Never assume. A hook that is misconfigured, missing, or `--bare`'d away is observationally identical
to a hook that passed (§6.2). Three levels of proof, cheapest first.

**Level 1 — is it wired?**

```bash
jq -r '.hooks | to_entries[] | .key as $e | .value[]
       | (.matcher // "-") as $m | .hooks[]
       | "\($e) [\($m)] \(.command) t=\(.timeout)"' .claude/settings.json
```

Every command must resolve without `~`, and every timeout must be seconds (≤ 900). `install.js`
asserts both on the global side; `test/install.test.js` asserts the committed side.

**Level 2 — does the script deny when it should?** Both gates are plain scripts reading a JSON hook
payload on stdin, so they can be exercised directly. `test/merge-gate.test.sh` does this against a
throwaway fixture repo, covering allow on a fully green sha-pinned fixture, deny on a stale ledger
sha, and deny on a missing verdict:

```bash
bash test/merge-gate.test.sh          # or: npm test, which now runs both suites
```

Manual single-shot:

```bash
echo '{"tool_input":{"command":"gh pr merge 12 --squash"},"cwd":"'"$PWD"'"}' \
  | bash .claude/hooks/merge-gate.sh; echo "exit=$?"
```

Expect either JSON containing `"permissionDecision":"deny"` with a `MERGE GATE (...)` reason, or
empty output — and `exit=0` in both cases. Any other exit code means the script itself is broken,
which is non-blocking, which means fail-open.

`.claude/CLAUDE.md:7` makes this a standing requirement rather than a good habit:

> **A change to a hook's blocking behavior ships in the same commit as a test under `test/` that
> proves both the new block and the new allow.**

Both halves. A test that only proves the block lets a matcher widen until it denies everything, which
is how `deny-guard` came to block `--force-with-lease`.

**Level 3 — does the runtime honor it, end to end?** The one that actually matters. Force the
fail-closed path with the variable the gate exposes for exactly this purpose: set
`QUETREX_VERIFY_BUDGET=2` with a `sleep 5` in the chain and confirm a block is produced. And in a
live session on a managed repo, ask an agent to run `gh pr merge` on a branch with no verdict
artifact; the turn must come back with the gate's deny reason, not a merge.

### 10.2 Reading the ledger

`.quetrex/verify-ledger.jsonl` is append-only JSONL, one object per command run:
`{ts, cmd, cwd, sha, exit, tail}`.

Latest state per command — exactly what GATE 3 evaluates:

```bash
jq -s 'reduce .[] as $e ({}; .[$e.cmd] = {exit:$e.exit, sha:$e.sha, ts:$e.ts})' \
  .quetrex/verify-ledger.jsonl
```

Is it green *for HEAD*:

```bash
HEAD_SHA=$(git rev-parse HEAD)
jq -s --arg head "$HEAD_SHA" --argjson chain "$(jq -c .verify .quetrex/verify.json)" '
  (reduce .[] as $e ({}; .[$e.cmd] = {exit:$e.exit, sha:($e.sha // "")})) as $last
  | [ $chain[] | ($last[.] // {exit:null, sha:null}) as $l
      | {cmd:., exit:$l.exit, sha:$l.sha}
      | select(.exit != 0 or (.sha != $head)) ]' .quetrex/verify-ledger.jsonl
```

`[]` means GATE 3 would pass. Anything else is the exact deny list the gate would print.

Reading a denial:

| Symptom | Meaning |
|---|---|
| `"exit": null` for a chain command | it never ran — the chain changed, or a rung was skipped |
| `"exit": <n>` non-zero | genuinely red; read that line's `tail` |
| `exit 0` but `sha` ≠ HEAD | **stale green** — commits landed after the proof. Re-run at HEAD; do not "fix" anything |
| `exit: 124` or `137` with a TIMEOUT tail | time-budget kill — split or speed up the chain, do not hunt a bug |

### 10.3 Escalation states and how to clear them safely

| State | Written by | What it means | How to clear |
|---|---|---|---|
| `verify-attempts` = n < max | verify-gate | the chain is red and the agent is inside its self-heal budget | a green run resets it to 0 |
| `ESCALATION` from verify-gate | verify-gate, after `QUETREX_VERIFY_MAX` (default 3) reds | the chain is *still* red after 3 self-heal attempts; the agent was told to stop and surface it verbatim | **fix the actual failure**; a green verify run then removes it automatically |
| `ESCALATION` from reviewer | reviewer, at `review_iter >= 3` | the rework loop is exhausted; a human must decide | a human-driven rework. Do not delete it to force the merge |
| verdict `REWORK` | reviewer | a concrete, developer-fixable defect | fix, re-run; the reviewer overwrites the verdict |
| verdict `ESCALATE_HUMAN` | reviewer | uncertainty, a product/architecture decision, a native pass that could not run, an unpinned `qa-report.json`, or a QA coverage gap on a security surface | a person decides; the verdict must be re-emitted |
| `state.json.git_workflow = "refused"` | git-workflow | an artifact gate was red, or uncommitted work sits outside the reviewed commit | read `git_workflow_reason`, fix upstream, re-run |

**The one dangerous move:** deleting `ESCALATION` by hand. It is the only artifact written by one
gate and hard-blocked on by another, and it is the system's memory that a bounded loop already gave
up. Deleting it fixes nothing; it converts a stopped pipeline into one that will merge unproven work.
Both the hook and the agent say so explicitly.

Note the interaction worth knowing: **a genuinely green verify run deletes `ESCALATION`.** That is
correct — and it is why the truncating chain extractor (§3.1, rung 2) was more dangerous than it
looked: a retry that passed a *truncated* chain would have erased a real escalation. It is also why
`ESCALATION` is the first thing the SessionStart re-injection hook must carry.

---

## 11. Known limits and tradeoffs

Stated plainly. A maintainer who does not know these will over-trust the system, which is the one
failure mode the whole design exists to prevent.

**1. A worktree is not a container.** `developer` and `qa` run under `bypassPermissions`, and course
L4 says bypass should *"only run inside an isolated container or VM"* (`COURSE-REF.md:113`). A git
worktree isolates the *file tree*; it shares the user, the home directory, the network, the shell
environment, and every credential on the machine. The mitigation is the hook floor of §6.3, which is
real but is a denylist, not a sandbox.

**2. The classifier gap.** `dontAsk` has no intent classifier (§7.3). The hooks cover the categories
they were written for and nothing else; secret egress is a known, currently open gap.

**3. The reviewer's control-plane writes are bounded by prose, not by mechanism.** `reviewer.md:20`
and `:353` restrict Bash writes to three specific files. `disallowedTools: Write, Edit` is enforced;
"do not `sed -i` a source file" is not. The tool restriction removes the *convenient* path to
self-fixing, not every path.

**4. Loop counters and turn caps bound different failure modes; neither replaces the other.**
`reviewer.md:340` states it best:

> `review_iter` is *semantic*: it counts REWORK bounces, so the pipeline knows the difference between
> "first attempt" and "third failed repair", and it survives across separate agent invocations
> because it lives on disk. But it is incremented by the very agent it bounds — if this stage
> crashes, is killed, or simply omits the `jq`, the counter stays flat and the loop looks fresh
> forever. The `maxTurns` in this agent's frontmatter is the *runtime* bound: the harness enforces it
> out-of-band, it cannot be omitted or forgotten.

Hence both, everywhere: `maxTurns` is now on all five agents that can loop (developer 80, qa 80,
reviewer 60, database-architect 60, git-workflow 30). `verify-gate`'s counter is the model to copy
where possible — the **hook** increments, out of band from the agent it bounds.

**5. `verifyQuick` is still a customer-editable input, now bounded.** Subset-ness is enforced
(§3.1) and the merge boundary reads `.verify` regardless, so the exposure is bounded to the
per-subagent gate *by design* rather than by accident. It is not zero: a `verify` chain that is
itself weak makes both chains weak, and nothing mechanically judges the quality of a customer's
chain.

**6. Main is not branch-protected.** merge-gate is the software guardrail; there is no server-side
one behind it until `verify.yml` is made a required status check (§9.3). Until then a red CI run is
advisory.

**7. `bypassPermissions` stays** on `developer` and `qa`. The throughput is worth it given the hook
floor. Revisit if the floor ever thins.

**8. Documentation drift is real and load-bearing.** `/q-task-merge` was advertised in six files and
inside merge-gate's own deny messages, and never existed; git-workflow gated on `APPROVE`, a verdict
the reviewer never emits; `dev-pipeline.md` calls itself "the single canonical definition" while
contradicting the agent files on three points. The first two are fixed. None of these break a gate;
all of them cost an agent's attention budget, which course L2 correctly frames as finite.

**9. `/goal` is deliberately not adopted** as the completion gate. Its evaluator reads only the
transcript (`COURSE-REF.md:26`), so it cannot read the ledger or check `sha == HEAD` — it would
accept a prose claim of green, exactly what `qa.md:16` exists to kill. `/loop` **is** adopted for the
epic dispatcher, because the kanban is the state of truth and readiness is recomputed from the API,
so the tick is genuinely stateless.

**10. The control artifacts are not schema-validated.** `reviewer.md`'s verdict is built with
`jq -n --argjson` and hand-quoted JSON-in-shell; a finding containing a quote or newline is a live
corruption risk. `[INTENT]` finding 29: a SubagentStop hook that JSON-Schema-validates
`plan/*.json`, `review-verdict.json`, `qa-report.json` and `security-findings.json`, exiting **2**.

**11. The single-unit path has no scope gate.** The epic path has one (DAG-validated before asking);
the single-unit path has none, and `architect.md:139` explicitly forbids one. The product model is
"plan → tap Approve from the phone → automated build." Those do not yet agree.

**12. The routine trigger does not exist yet** (§9.4), so today every entry point is still a human
typing a slash command. This is the largest remaining gap between the built system and the product
model.

---

## 12. Compared to Anthropic's "Claude Code in Action"

Use this section when a customer's engineer says *"why not just do what the course says."* Source:
`COURSE-REF.md`, captured 2026-07-29.

### 12.1 Where the design goes beyond the course

**1. Commit-pinning against stale-green.** The course has no concept of it. Three independent pins to
HEAD — ledger `sha`, verdict `sha`, findings `head_sha` (plus `qa-report.sha`) — each written by a
different agent and checked by a different code path. A green proven against an earlier commit cannot
authorize a later one. §5.

**2. Fail-closed on timeout.** The course's Stop-hook sketch (`COURSE-REF.md:311-316`) fails *open*
on a hang: the hook is killed, no block is emitted, the turn ends green. quetrex runs an internal
wall-clock budget under the external hook timeout, per-command `timeout`/`gtimeout`, a SIGKILL
watchdog fallback, and treats budget exhaustion as **RED**. §3.1.

**3. Refusal to launder environment errors.** Exit 127 / "command not found" / ENOENT is RED, full
stop. This is the most common way a real Stop gate degrades into a no-op — someone adds an "it's just
the environment" escape hatch and the gate stops gating. Named and closed.

**4. Requirement computed from the diff, not the plan.** A ~30-term sensitive-path regex plus an
added-lines regex, explicitly so *"a plan that simply omits the flag cannot ship sensitive code
unreviewed."* The course does not discuss bypass-by-omission. §3.2, GATE 4.

**5. Mechanized anti-self-exemption.** GATE 2b denies an AUTO_MERGE whose artifact does not
affirmatively record that the native security pass ran, and treats an absent field exactly like an
excuse string. The course's guidance on getting a cold second opinion is advice to a human; this is a
hook that refuses the merge when the second opinion is only claimed. §3.2.

**6. Mechanized ownership enforcement.** GATE 5 checks the diff against the architect's ownership map
— the artifact the entire parallel-developer architecture rests on, and which was previously enforced
by nobody. It closes course L8's exact named failure (clean summary, unexpected file) with code
rather than with a reviewer's attention. §3.2.

**7. PreToolUse as the layer *beneath* `bypassPermissions`.** The course covers hooks (L5) and
permission modes (L4) in separate lessons and never connects them. Connecting them is what makes an
unattended `dontAsk` + bypass profile defensible. §6.3.

**8. Bounded loops whose exhaustion is a durable cross-gate artifact.** `ESCALATION` is written by one
gate and hard-blocked on by another, with an explicit instruction not to delete it to force a merge.
The course has no equivalent to a loop bound that outlives the loop.

**9. Negative-space reporting, promoted to an artifact.** *"State what you did NOT verify"* as a
cardinal rule whose omission is itself a FAIL (`qa.md:20`) — and then routed to `qa-report.json` so it
survives the anti-anchoring rule and becomes an input to the verdict. The course asks for evidence
attached (`COURSE-REF.md:79`); requiring a declaration of *absent* evidence, sha-pinned and
machine-read, is strictly stronger.

**10. Anti-anchoring as a structural invariant.** The course recommends a cold second opinion as an
optional closing step (`COURSE-REF.md:318`). Here it is enforced at every stage with the reason
stated — and, notably, with one carefully-drawn exception where discarding the narrative would have
discarded evidence (§2.2).

**11. Two-tier secret detection with false-positive discipline.** Entropy scoped to an assignment
beside a keyword, explicitly so lockfile digests stay quiet, because *"false positives erode trust in
the gate."* The course's redaction example is a single `sk_live_` pattern.

**12. A post-install enforcement assertion that checks reachability.** `install.js` fails the install
when a hook is installed but not wired, when a per-project gate leaks into global settings, when a
superseded hook is still wired, or when a timeout is in the wrong unit. The plugin system has no
equivalent.

### 12.2 Where the design deliberately diverges

**`dontAsk`, not `auto`, for unattended runs.** Course L8 recommends keeping unattended runs in auto
mode to retain the classifier (`COURSE-REF.md:303`). quetrex ships `dontAsk`. Reason: the classifier's
terminal action is to **ask**, and course L4 itself says `dontAsk` is *"the mode for unattended runs"*
so *"the pipeline keeps moving instead of hanging on an approval no one is there to give"*
(`COURSE-REF.md:127`). The two lessons point in opposite directions; a product whose defining promise
is that nobody is watching must take L4's side. The cost is stated in §7.3 and paid down with hooks,
not hidden.

**`--bare` forbidden, against L6's CI recommendation.** L6 recommends `--bare` for deterministic CI
runs (`COURSE-REF.md:230`). For any quetrex pipeline stage it is forbidden, because `--bare` skips
hooks and `-p` skips hook auto-discovery — and a run with no hooks is indistinguishable from a run
whose hooks all passed. Determinism that removes the verification layer is not determinism worth
having. §9.2.

**`/goal` not adopted.** L1 presents it as an autonomy lever with the stated constraint that its
evaluator only reads the transcript. That constraint is disqualifying here: it cannot read the ledger,
cannot check `sha == HEAD`, and would accept a prose claim of green. §11.9.

**Skills are not the verification surface.** L3 says the verification skill is the one to build first
(`COURSE-REF.md:70`), and its four steps are excellent — run the tests, read the diff, check that no
test was weakened, report with evidence. quetrex implements those steps in a **hook** and an **agent**
instead, because L3's own table concedes the boundary: *"a rule Claude must not be able to skip"*
belongs in a hook, *"code that actually runs, not instructions Claude follows"* (`COURSE-REF.md:96`).
A skill fires when a description matches; a Stop hook fires on every turn end, unconditionally. For a
product whose guarantee is that nothing merges unproven, "usually fires" is not a guarantee. The
`qa-verify` skill keeps its L3 shape — a lean `SKILL.md` over an executable script, per
`COURSE-REF.md:83-88` — but it is a convenience for a human, not the gate.

**Managed Code Review composes but never gates.** L7 presents it as the default managed path. It never
approves or blocks, has no autofix, and is team/enterprise only. For a per-seat BYO-compute product
sold to companies on Pro/Max it cannot be a required stage. Free upgrade where the plan allows; never
load-bearing.

### 12.3 Where the course is simply right and the design followed

- **`.worktreeinclude`** (`COURSE-REF.md:29`) — now shipped at `.worktreeinclude`, listing the
  git-ignored env and local-config files a worktree would otherwise never carry. Without it an agent
  lands with no environment and cannot tell *"the env is missing"* from *"the code is broken"*, so it
  burns its entire self-heal budget fixing code that was never broken and then escalates — as a
  `bypassPermissions` agent flailing at a green build, which is precisely the state that produces a
  weakened test or a hardcoded credential. Dependencies are deliberately **not** listed: they are
  installed in the worktree, not copied.
- **SessionStart + `compact`, not PostCompact** (`COURSE-REF.md:144`) — wired at
  `.claude/settings.json:36-47`. §6.1.
- **A PostToolUse lint/typecheck gate** (`COURSE-REF.md:314`) — the missing half of L8's two-gate
  pair, now `edit-gate.sh`. A type error from the first edit used to surface only at turn end, after
  paying the full 840s chain and burning one of three self-heal attempts; three such edits reached
  `ESCALATION` for a typo.
- **`--max-turns` as a hard cap on the agent loop** (`COURSE-REF.md:291`) — §11.4.
- **The four instruction scopes, one owner each** (`COURSE-REF.md:39-44`) — project `CLAUDE.md` cut to
  what is true of this repo, generic doctrine shipped separately and imported, machine- and
  company-specific rules moved to a git-ignored `CLAUDE.local.md`.
- **"Read before you install"** (`COURSE-REF.md:338`) — a plugin's hooks fire on every matching tool
  call whether or not the installer read them. Since quetrex ships hooks to other companies, the
  obligation runs the other way, and `SECURITY.md` is the discharge of it.
