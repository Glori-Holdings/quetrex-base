# PRD — /claude-md-audit + delta-only CLAUDE.md

**Status:** Draft
**Date:** 2026-04-17
**Owner:** Glen Barnhardt
**Purpose:** Define the skills, file conventions, and audit process that keep CLAUDE.md files from rotting — the durable, human-readable rule layer of Claude Code memory.

---

## 1. Problem Statement

CLAUDE.md is the rule layer Claude Code reads at the start of every session. In practice it rots:

- **Growth-only.** The convention "update CLAUDE.md after every correction" has no counterweight. The file only ever gets longer.
- **Duplication between global and project.** `~/.claude/CLAUDE.md` and a project's `.claude/CLAUDE.md` can drift one-way — a rule updated in one doesn't propagate to the other.
- **No rule metadata.** There is no record of when a rule was added, what incident created it, or when it was last validated. Dead rules are invisible.
- **Implicit precedence.** When global declares a stack and a project uses a different stack, nothing in the files says who wins. The agent silently uses the wrong defaults.
- **Silent contradictions.** Two rules can conflict and the file reads as if both are active.
- **No firing evidence.** There is no way to tell whether the agent is actually applying a given rule.

Karpathy, in his January 2026 notes on Claude coding, explicitly flagged CLAUDE.md maintenance as an open problem. This PRD defines the fix.

## 2. Goals

1. Make CLAUDE.md auditable — every rule has enough metadata to judge whether it still earns its keep.
2. Enforce the **delta-only project CLAUDE.md** philosophy: a project file contains only overrides and project-specific additions. Never duplicates global.
3. Provide a skill that audits the file on demand and proposes prunes — never auto-applying.
4. Provide a skill for new-rule intake that enforces metadata + canonical examples at write time.
5. Compose cleanly with the future richer memory layer; do not block on it.

## 3. Non-Goals

- Not replacing CLAUDE.md with a database. It stays a markdown file, readable by humans and agents.
- Not auto-modifying CLAUDE.md without user approval.
- Not measuring CLAUDE.md's effect on agent output quality (that's a benchmarking concern, separate).
- Not managing multi-user / multi-owner CLAUDE.md files. Single-operator scope for v1.

## 4. User Stories

- **As Glen**, I want a single command (`/claude-md-audit`) that scans my global and project CLAUDE.md files and tells me which rules are stale, duplicated, contradictory, or leaking across scope.
- **As Glen**, I want the audit to propose a diff I can accept or reject per-rule, not force automatic edits.
- **As Glen**, when I add a new rule via `/claude-md-add`, I want the skill to require the triggering incident and a canonical bad-before / good-after example — so every rule has provenance and a test case.
- **As a teammate agent** reading CLAUDE.md, I want every rule annotated with enough context (`added`, `source`, `last-validated`) to understand whether it applies today.

## 5. Design

### 5.1 File conventions

**Global `~/.claude/CLAUDE.md`** — the base layer. Contains stack defaults, workflow defaults, verification steps, teammate guidance. Explicit precedence note in the Stack section:

> If a project's `.claude/CLAUDE.md` declares its own Stack, use that and ignore this section entirely.

**Project `.claude/CLAUDE.md`** — delta-only. Contains:

- Project-specific overrides (different stack, different verification steps, different workflow rules)
- Project-specific additions (domain rules, architecture invariants, team conventions not in global)

Never contains a rule that appears verbatim or semantically in global. The audit skill enforces this.

### 5.2 Rule metadata convention

New rules going forward use a lightweight frontmatter block per rule or per section:

```markdown
### Rule: integration tests hit real DB
<!-- added: 2026-04-17 | source: incident 2026-03-12 mock/prod divergence | last-validated: 2026-04-17 | fires-on: integration-test-files -->

Integration tests must hit a real database, never mocks.
```

- `added` — date the rule was introduced
- `source` — incident, PR, or session that prompted it (so future-you can judge whether the trigger still applies)
- `last-validated` — updated by the audit skill when a human confirms the rule is still load-bearing
- `fires-on` (optional) — grep pattern or scenario marker describing when the rule should apply; enables future firing tests

Retrofit is lazy — existing rules get metadata only when touched. The audit skill surfaces rules missing metadata so they can be annotated on first review.

### 5.3 /claude-md-audit skill

Runs on demand or on a schedule. Inputs:
- `~/.claude/CLAUDE.md` (global)
- `<project>/.claude/CLAUDE.md` (project)
- Audit threshold (default: rules older than 6 months with no `last-validated` update)

Output: a report with proposed actions, grouped by severity:

**Blockers (delta-only violations):**
- Project rules that duplicate global (byte-identical or semantically equivalent via LLM judge)
- Action: prune from project

**Warnings:**
- Rules older than threshold with no `last-validated` update
- Rules missing metadata
- Suspected contradictions between rules (LLM judge, with confidence score)
- Global rules that look stack-specific (potential leakage — suggest moving to project)

**Informational:**
- Rules count per file
- Total bytes, growth since last audit
- Oldest rule, newest rule

Each proposed action is presented as a diff. User approves per-item — no auto-apply.

### 5.4 /claude-md-add skill

Enforces intake discipline for new rules. Prompts for:
- Rule text
- Triggering incident / PR / session (required)
- Bad-before example (required)
- Good-after example (required)
- Target scope: global or project (with guidance — global if it applies to all stacks; project if stack-specific or project-specific)
- Optional `fires-on` marker

Writes the rule with full metadata to the appropriate file. Runs a scope check — if the rule looks like it belongs in global but the user chose project, flags the mismatch.

### 5.5 Delta-only enforcement algorithm

The audit skill's delta-only check is the hard requirement. Two-pass:

1. **Exact match pass.** For each rule in project CLAUDE.md, check for a byte-identical match in global (ignoring whitespace and comment frontmatter). Any exact match is a blocker.

2. **Semantic match pass.** For each remaining rule in project, use an LLM judge to determine whether a semantically equivalent rule exists in global. Output: `(project-rule, candidate-global-rule, confidence)`. Confidence ≥ 0.85 is flagged as a duplicate; 0.6–0.85 is flagged as a possible duplicate for human review.

The algorithm produces a proposed project CLAUDE.md with all flagged duplicates removed. User reviews and approves.

## 6. Acceptance Criteria

- `/claude-md-audit` runs against a global + project pair and produces a report within 30s.
- The delta-only check correctly flags byte-identical and semantically equivalent duplicates in a test fixture of 20 rule pairs (≥95% precision, ≥90% recall against human labels).
- `/claude-md-add` refuses to write a rule without source, bad-before, and good-after fields populated.
- After one full audit + accepted prunes, project CLAUDE.md contains zero rules that duplicate global (by the two-pass check).
- The precedence line is present in global Stack section.

## 7. Phased Rollout

All estimates are AI-build time.

**Phase 1 — one-shot cleanup (~30 AI-min):**
- Add precedence line to global Stack section
- Manual pass: rewrite project CLAUDE.md as delta-only
- Document frontmatter convention in this PRD and in a short CLAUDE.md header comment

**Phase 2 — /claude-md-audit (~3 AI-hours):**
- Parser for markdown rules with metadata
- Exact-match duplicate detector
- LLM-judge semantic-match detector
- Age/metadata/contradiction checks
- Report generator with per-item diffs
- Approval UI (interactive prompt)

**Phase 3 — /claude-md-add (~1.5 AI-hours):**
- Interactive intake prompt
- Scope-check LLM judge
- Writer that emits rules with full metadata

**Phase 4 — bridge to richer memory layer (documented, not built):**
- Placeholder section describing how the audit skill will later write high-salience CLAUDE.md rules into a procedural memory store with salience and decay. Blocked on that system being available and omnipresent.

**Total v1 build time: ~5 AI-hours.**

## 8. Open Questions

1. **Audit cadence.** Run manually, on a schedule via trigger, or as a pre-commit hook on CLAUDE.md changes? Lean: manual + optional monthly schedule.
2. **Multi-project global.** Global CLAUDE.md applies to every project. If two projects need conflicting global changes, we need a mechanism for per-project override that doesn't bloat global. The delta-only + precedence pattern handles most cases; edge cases deferred.
3. **Semantic match confidence threshold.** Start at 0.85 for auto-flag, 0.6 for review. Tune after first real audits.
4. **Retrofitting existing rules.** Lazy retrofit on touch, or one-shot backfill? Lean: lazy, with the audit skill surfacing unannotated rules so they're annotated during review.

## 9. Risks

- **LLM-judge false positives on semantic match.** A strict rule in global + a looser variant in project could be flagged as a duplicate when they aren't. Mitigation: require human approval on every prune, never auto-apply.
- **Audit fatigue.** If the report is too long or the diffs too verbose, Glen won't run it. Mitigation: group by severity, default to showing blockers first, keep each diff under 10 lines.
- **Rule text drift from metadata.** Someone edits a rule but doesn't bump `last-validated`. The skill can't detect this directly — partial mitigation via age-based flagging.

---

**Next action:** Approve this PRD. On approval, Phase 1 cleanup (add precedence line, delta-only rewrite, frontmatter convention) can start immediately.
