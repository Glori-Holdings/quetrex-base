# GOLDEN — the definition of done for Quetrex

**Status: in force from the commit that added this file.** Amendments are the operator's;
an agent may propose one and may not make one. Git history is the record of who changed what —
there is no signature ceremony, because a commit already is one.

## 1. Why this file exists

"Review the system" has no stopping condition. A review agent's job is to find things;
pointed at an unbounded surface it returns unbounded findings, forever. Using that as a
release gate means the system can never be declared finished — which is exactly what has
happened, repeatedly, and it is a property of the question, not a measurement of the code.

This file replaces that question with a finite one. GOLDEN is not "no findings." GOLDEN is
**the run below completing green, from cold, twice, on two different repos.**

Everything a review finds that does not break a step below is a backlog item with a
severity. It is not a release blocker. See §3.

## 2. The GOLDEN run

The product exists so that work can be planned from a terminal, handed to Anthropic's
servers, and monitored and steered from a phone without sitting at a computer. Each step
below is a step of that promise. `AUTO` = provable by a script in CI. `DRILL` = provable
only by a live run with the operator present.

| # | step | passes when | how |
|---|---|---|---|
| 1 | `/quetrex:login` on a cold machine | `~/.quetrex/auth.json` exists; `/api/projects` answers 200 with the stored token | AUTO |
| 2 | `/quetrex:init` in a fresh clone | `.quetrex/project.json` + `.quetrex/verify.json` are **committed** (not merely on disk); `enabledPlugins` carries the engine unpinned; `/quetrex:doctor` reports every check green | AUTO |
| 3 | `/quetrex:task-new` → `/quetrex:task-refine` | card exists on the board in `backlog` with the refined description written back | AUTO |
| 4 | `/quetrex:task-build` plan half | architect plan written; substrate announced out loud ("planning locally; the build dispatches to Anthropic's cloud after you approve"); **scope approved from the phone** | DRILL |
| 5 | build half | the pipeline runs **entirely on Anthropic's servers** — no build step executes on the operator's machine; the card moves as it progresses; a run needing a human is visible without being at the terminal | DRILL |
| 6 | gates | a PR exists with a green verify ledger sha-pinned to its head, no open Critical, and an `AUTO_MERGE` verdict; `/quetrex:merge` merges it and sets the card to `merged`; branch and worktree are torn down automatically | AUTO |
| 7 | ship | `/quetrex:deploy` deploys; `/quetrex:task-complete` sets `deployed` → `complete` | DRILL |

**The run is green only if the terminal is unattended from step 4 onward.** A step that
required the operator to open GitHub, run a command by hand, or repair state mid-run is a
FAILED step, even if the end state looks correct.

**Two repos, two stacks.** One Next.js and one Python fixture, so that anything hardcoded to
a single stack fails visibly. **Twice** — a second consecutive cold run, because a run that
only passes once passed on leftover state.

## 3. The blocking rule

A finding may block a release only if it is one of:

- **B1** — it breaks a step of §2, demonstrated by an executed reproduction.
- **B2** — it is a security hole with a demonstrated exploit path, executed, not argued.

Everything else is logged with a severity and scheduled. It does not gate.

Reviewers are not asked "is this good?" They are asked **"which step of §2 did this break,
and show the execution."** A finding with no step and no execution is a backlog item by
construction.

## 4. Invariants

A test may assert a design decision **only if that decision appears below.** Everything else
tests behavior, not shape. This list is amended by the operator, never by an agent, and
never as a side effect of fixing something.

The reason for this rule: `test/plugin.test.js:342` and `:317` were written to lock in a
hurried fix, and thereby converted an accident (the board plugin shipping a second copy of
the engine) into an invariant the suite defends. Every later review then reasoned from it.

| id | invariant |
|---|---|
| **I1** | **Single owner.** Every shipped file and every hook registration has exactly one owner. The publisher refuses to publish if two plugins' file sets intersect. Tests assert **disjointness**, never equality against a directory. |
| **I2** | **The safety floor works with zero plugins installed.** deny-guard, secret-scan, enforce-branch, verify-gate and merge-gate must fire in a fresh clone, a CI runner, and a cloud routine before any plugin install completes. |
| **I3** | **A hook's external timeout must exceed its internal fail-closed budget.** A hook killed by the harness produces no output, which reads as allow. |
| **I4** | **No version pins.** `enabledPlugins` carries booleans only; the running version is surfaced in the status bar. |
| **I5** | **AGENTS run in two places only** — the operator's terminal, and a cloud routine on Anthropic's servers under the same subscription. Never a third machine, never a separate API key. This governs where *an agent* executes, not where *tests* run: CI re-deriving the verify chain on a runner is explicitly permitted and is relied upon — `.github/workflows/verify.yml` is a required check and merge-gate GATE 2b leans on its independence. The defect this records is a CI job that ran **Claude** and so demanded its own `ANTHROPIC_API_KEY`; a runner executing tests holds no key and decides no verdict. |
| **I6** | **The board is the record.** Every status transition is written by the machinery, never left for the operator to fix by hand. |
| **I7** | **A gate's verdict is sha-pinned** to the commit it judged, and a verdict for a different sha or a different task is treated as absent. |

## 5. Provenance, and what is still open

Most of this file is the operator's spec written down. Three parts were authored by an agent
while writing it, and are marked here so nobody mistakes them for the spec:

| item | status |
|---|---|
| Step 5 originally required an **SMS** on `needs_human` | **RESOLVED, dropped 2026-08-17** — Anthropic's own routine notifications already reach the phone; a second notification channel is duplicated machinery. Step 5 now asks only that a run needing a human is visible away from the terminal. |
| "**Twice**, on **two repos** — one Next.js, one Python" (§2) | **OPEN, agent-authored.** Reasoning: one pass can succeed on leftover state, and one stack hides anything hardcoded. Cost: it roughly doubles the work of declaring GOLDEN, and no Python fixture exists yet. The operator has not ruled on it. |
| The **seven invariants** (§4) | **OPEN, agent-authored.** Derived from defects found on 2026-08-16/17, not dictated. Four of the seven were violated when written, so they carry real consequences for what blocks and what does not. I5 was corrected 2026-08-18 after review found it forbade this repo's own required CI check. |
| **§3's blocking rule** (B1/B2) | **OPEN, agent-authored** — recorded because review found it was reading as ratified spec while being the one clause deciding what can ever block a release. Known gap: B2's "executed, not argued" bar would have made a real authorization-widening defect (`requireAdmin()` -> `requireTenantAccess()` across 8 routes, found by inspection) a mere backlog item. A demonstrated missing control on a reachable path should be able to satisfy B2 where building an exploit fixture is disproportionate, and data destruction/corruption likely warrants its own B3. Operator ruling wanted. |

## 6. Amendment log

- **2026-08-17** — created. SMS dropped from step 5 (operator). Sign-off ceremony removed in
  favour of git history.
- **2026-08-18** — I5 corrected: as written it forbade "a third machine (CI runner)" while
  this repo ships a required CI check that GATE 2b depends on. Now scoped to where agents
  run, not where tests run. §3's blocking rule marked agent-authored, with its known gap
  recorded. Both found by the review gate on this file's own PR — the document doing its job
  before it was merged.
