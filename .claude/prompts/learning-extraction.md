# Learning Extraction Prompt

You are analyzing a completed issue to extract reusable knowledge.

## Session Startup

1. Read `.issue/progress.md` for the full history of this issue
2. Read `.issue/todo.json` for the feature list and completion status
3. Read `.issue/architecture-decision.md` for the original plan
4. Read `.issue/stage-state.json` for pipeline metadata (retry counts, session counts)

## Analysis Tasks

### 1. Non-Obvious Discoveries

Review all progress entries and identify:
- Patterns that were NOT obvious from documentation
- Workarounds that were necessary
- API behaviors that differ from docs
- Integration gotchas between stack components

### 2. QA Failure Patterns

If the issue had QA retries (check stage-state.json):
- What caused each failure?
- What was the fix?
- Could the failure have been prevented?
- Is this a recurring pattern?

### 3. Architecture Doc Changes

Check if `docs/architecture/` was modified:
- What changed and why?
- Does this indicate a broader architectural shift?

## Output

### Rules (write to `.claude/rules/learned-patterns.md`)

**Format:** UPDATE the file — merge new rules, don't duplicate existing ones.

Each rule must be:
- Specific and actionable (BAD: "handle errors properly", GOOD: "Drizzle upsert with onConflictDoUpdate requires explicit target array")
- Scoped to the project's stack
- Include the context in which it applies

```markdown
## [Category]

### [Rule Title]
**Context:** [When this applies]
**Rule:** [What to do]
**Why:** [What goes wrong otherwise]
```

### Skills (write to `.claude/skills/learned/[name].md`)

Only create a skill if the discovery is significant enough to warrant it.

**Format:**
```markdown
---
name: [descriptive-name]
description: [Retrieval-optimized description — what would someone search for?]
---

# [Skill Name]

## Problem
[What problem does this solve?]

## Context / Trigger
[When should an agent use this?]

## Solution
[Step-by-step solution]

## Verification
[How to confirm the solution works]

## Failed Attempts
[What was tried and did NOT work — this is the highest-value section]
```

### Discoveries Log (update `.issue/discoveries.md`)

Append a summary of what was learned from this issue.

## Critical Rules

1. **Specificity over generality** — Vague rules are useless
2. **Failed attempts are gold** — Always document what DIDN'T work
3. **Dedup before writing** — Read existing rules/skills first, update rather than duplicate
4. **Stack-scoped** — Rules should reference our specific stack versions
5. **Actionable** — Every rule should tell an agent exactly what to do
