# Knowledge Consolidation Prompt

You are consolidating learned knowledge across issues and projects. This runs periodically (e.g., after every 10 completed issues).

## Session Startup

1. Read `.claude/rules/learned-patterns.md` for all project rules
2. Read all files in `.claude/skills/learned/` for extracted skills
3. Read `docs/architecture/` for current system understanding
4. Read recent `.issue/` directories (if available) for context

## Consolidation Tasks

### 1. Deduplication

Scan all rules and skills for:
- **Duplicate rules** — same rule phrased differently → merge into one
- **Contradictory rules** — rules that conflict → resolve, keep the correct one
- **Overlapping skills** — skills that cover the same ground → merge
- **Stale rules** — rules that reference removed code or outdated patterns → delete

### 2. Quality Check

For each rule, verify:
- Is it specific and actionable? (not vague)
- Does it reference current stack versions?
- Does it match current `docs/architecture/`?
- Is the context still valid?

Low-quality rules should be either improved or removed.

### 3. Promotion Candidates

Identify rules/skills that should be promoted to global scope (`~/.claude/rules/`):
- Rules that apply to the stack in general (not project-specific)
- Skills that would help ANY project using this stack
- Patterns discovered in 2+ projects

**Do NOT auto-promote.** List candidates in the consolidation report for human review.

### 4. Gap Analysis

Check if there are areas with no learned rules:
- Common failure categories with no prevention rules
- Stack integration points with no documented patterns
- Frequently modified areas with no architectural documentation

## Output

### Updated Files

1. **`.claude/rules/learned-patterns.md`** — Deduplicated, quality-checked
2. **`.claude/skills/learned/`** — Merged, stale skills removed
3. **Consolidation report** — Written to `.claude/consolidation-report.md`

### Consolidation Report Format

```markdown
# Knowledge Consolidation Report

**Date:** [timestamp]
**Issues analyzed:** [count since last consolidation]

## Actions Taken
- Merged [N] duplicate rules
- Removed [N] stale rules
- Updated [N] rules for accuracy
- Merged [N] overlapping skills
- Removed [N] stale skills

## Promotion Candidates (Requires Human Approval)
- **Rule:** "[rule description]" — appears in [project1, project2]
- **Skill:** "[skill name]" — generalizable to all [stack] projects

## Gap Analysis
- No rules for: [area]
- No skills for: [area]
- Architecture docs missing for: [area]

## Quality Metrics
- Total rules: [N] (was [N])
- Total skills: [N] (was [N])
- Rules with proper context: [N]%
- Skills with failed attempts section: [N]%
```

## Critical Rules

1. **Never delete without reason** — Log every deletion with rationale
2. **Merge, don't just delete duplicates** — Keep the best parts of each
3. **Cross-reference architecture docs** — Rules should match reality
4. **Human approval for promotions** — Never auto-promote to global
5. **Preserve failed attempts** — These are the highest-value content
