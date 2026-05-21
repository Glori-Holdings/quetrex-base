# Architectural Decisions

A running log of non-obvious decisions in Glori Builder. Newest first.

---

## 2026-05-21 — Linear state map + manual deploy gates

**Decision:** Pipeline state is driven by a per-project map of canonical keys → real Linear
column names, configured once with `/map-states` and stored in the project
`.claude/CLAUDE.md`. Single source of truth: `.claude/docs/linear-states.md`.

**Canonical keys:** `backlog, queued, in_progress, needs_help, rework, ready, merged, deployed,
complete` (plus terminal cancelled/duplicate, not pipeline-driven).

**Why a map instead of type lookups:** Workspaces name columns anything, and — critically —
several columns commonly share Linear `type: "started"` (e.g. `AI: In Progress`, `AI: PR Ready`,
`Merged`, `Deployed`). Type alone cannot distinguish them. Resolution order is: read the map →
exact-name match against live team states → type fallback only when no map exists.

**State machine:** Automation runs `queued → in_progress → ready` and **stops at `ready`**
(PR Ready). Merge/deploy/complete are deliberate human gates: `/merge-issue` → `merged`,
`/deploy` → `deployed`, `/complete` → `complete`. Any fail point (3× QA, blocker, ambiguity)
moves the issue to `needs_help`. `needs_help` replaces the old "Blocked" state and the fragile
by-name "Human: Review" lookup.

**Exceptions:**
- `/auto-pilot` bypasses the manual gates — auto-merges and sets `complete` directly
  ("vibe coding on steroids").
- `/plan-project` files freshly planned issues into `queued` (planning counts as approval), so the
  `/plan-project → /auto-pilot` walk-away flow works without a manual approval step.

**`/complete` semantics:** `/complete SMA-57` completes one issue; bare `/complete` moves **all**
`deployed` issues in a chosen project to `complete`, per-project only, behind an explicit
"are you sure?" confirmation.

**Files touched:** new `.claude/docs/linear-states.md`, `.claude/commands/map-states.md`,
`.claude/commands/complete.md`; wired `issue-prd`, `git-workflow`, `auto-pilot`, `issue-rework`,
`merge-issue`, `deploy-setup`, `plan-project`, `create-rules`, `quetrex-docs`.
