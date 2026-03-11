# Quetrex Personal Foundation Plan

**Location:** `~/.claude/docs/quetrex-foundation-plan.md`
**Status:** Ready for implementation
**Created:** 2026-01-13

---

## Quick Summary

Build a "Tech Team in a Box" at the personal level (`~/.claude/`) that:
1. Spawns a full development team per issue (architect → test designer → developer → QA → git)
2. Enforces TDD via Stop hooks (tests must pass before exit)
3. Uses cached documentation for fast lookups
4. Works across ALL projects using the same tech stack

**Tech Stack:** Next.js 15, TypeScript, Tailwind, ShadCN, Framer Motion, Postgres, Drizzle, TanStack Query, Zustand, Upstash Redis

---

## Critical Architecture: Personal vs Project Level

### Personal Level (`~/.claude/`) - GENERIC

Everything that applies to your tech stack across ALL projects:

```
~/.claude/
├── agents/           # Team agents (architect, developer, QA, etc.)
├── skills/           # Tech stack knowledge (Next.js, TypeScript, etc.)
├── commands/         # /quetrex-* workflow commands
├── hooks/            # TDD enforcement (tdd-guard.sh)
├── docs/             # Reference documentation
└── docs-cache/       # Cached documentation for fast lookups
```

### Project Level (`.claude/`) - DOMAIN SPECIFIC

Project-specific memory, overrides, and domain knowledge:

```
.claude/
├── memory/           # Project-specific learnings
│   ├── roles-system.md       # "Roles are case-sensitive, always use .toLowerCase()"
│   ├── webhook-patterns.md   # "Never use contact_id for matching"
│   └── permission-quirks.md  # Multi-agency access gotchas
├── agents/           # Project-specific agent OVERRIDES (optional)
├── skills/           # Domain-specific skills (webhooks, business logic)
└── CLAUDE.md         # Project rules and instructions
```

### How They Work Together

1. Personal agents load personal skills (generic tech stack)
2. Personal agents ALSO check for project memory files
3. Project-level agents/skills OVERRIDE personal when both exist
4. Domain knowledge travels WITH the project (git committed)

**Example:** Developer agent implements a feature
- Loads: `~/.claude/skills/nextjs-15-patterns/` (generic)
- Also reads: `.claude/memory/roles-system.md` (project-specific)
- Knows: "Always use .toLowerCase() for role comparisons in THIS project"

---

## The Team (8 Agents)

| Agent | Role | Skills |
|-------|------|--------|
| **architect** | Strategic analysis, impact assessment, creates todo | codebase-analysis, impact-assessment |
| **orchestrator** | Team coordination, workflow state, NEVER writes code | (none - coordination only) |
| **test-designer** | Writes failing tests FIRST (TDD) | testing-patterns, tdd-methodology |
| **developer** | Implements code to pass tests | nextjs-15, typescript, tailwind, drizzle, etc. |
| **qa** | Verifies tests pass, coverage, signs off | qa-verification, performance-testing |
| **git-workflow** | Commits, PRs, merges | (none - git operations) |
| **database-architect** | Schema design, migrations | drizzle-postgres |
| **performance-analyzer** | Bundle size, memory, Core Web Vitals | performance-testing |

---

## TDD Enforcement (Stop Hook)

**File:** `~/.claude/hooks/tdd-guard.sh`

```bash
#!/bin/bash
set -euo pipefail

input=$(cat)
stop_hook_active=$(echo "$input" | jq -r '.stop_hook_active // false')

# Prevent infinite loops
if [ "$stop_hook_active" = "true" ]; then
  echo '{"decision": "undefined"}'
  exit 0
fi

# Run tests
cd "$CLAUDE_PROJECT_DIR"
test_output=$(npm test 2>&1) || true

if echo "$test_output" | grep -qE "(FAIL|failed|Error)"; then
  failures=$(echo "$test_output" | grep -E "(FAIL|✗|×)" | head -5)
  cat <<EOF
{"decision": "block", "reason": "Tests failing. Fix code:\n$failures"}
EOF
  exit 0
fi

echo '{"decision": "undefined"}'
```

**How it works:**
1. Claude tries to exit ("I'm done")
2. Stop hook runs `npm test`
3. Tests fail → Hook blocks exit, shows failures
4. Claude continues working
5. Tests pass → Exit allowed

**Key rule:** Tests are IMMUTABLE. Code adapts to tests, never vice versa.

---

## Issue Workflow

```
/quetrex-issue "Add user preferences API"
    │
    ├── 1. Create worktree + quetrex-term tab
    ├── 2. ARCHITECT analyzes codebase, creates todo
    ├── 3. For each todo:
    │   ├── TEST DESIGNER writes failing tests
    │   ├── DEVELOPER implements (Stop hook enforces TDD)
    │   └── QA verifies and approves
    ├── 4. GIT WORKFLOW creates PR
    └── 5. Human reviews ONLY final product
```

---

## Files to Create

### Phase A: Core Infrastructure (10 files)
1. `~/.claude/docs/agents-skills-reference.md`
2. `~/.claude/docs/tech-team-in-a-box.md`
3. `~/.claude/hooks/tdd-guard.sh`
4. Update `~/.claude/settings.json` (add Stop hook)
5-10. `~/.claude/docs-cache/*.json` (documentation cache)

### Phase B: Team Agents (8 files)
11-18. `~/.claude/agents/{architect,orchestrator,test-designer,developer,qa,git-workflow,database-architect,performance-analyzer}.md`

### Phase C: Skills (14 directories)
19-20. Architect: codebase-analysis, impact-assessment
21-22. Test Designer: testing-patterns, tdd-methodology
23-30. Developer: nextjs-15-patterns, typescript-strict, tailwind-shadcn, framer-motion, drizzle-postgres, tanstack-query, zustand-state, upstash-redis
31-33. QA: qa-verification, performance-testing, security-review

### Phase D: Commands (8 files)
34-36. Quetrex-term: tab-name, tab-color, project
37-38. Workflow: quetrex-issue, quetrex-close
39-41. Quick: quetrex-type-check, quetrex-lint, quetrex-test

### Phase E: GoAutoSocial Cleanup
42-43. Remove duplicates, update commands to use personal agents

---

## Project Memory Pattern

For project-specific knowledge, create `.claude/memory/` files:

**Example: `.claude/memory/roles-system.md`**
```markdown
# Roles System - CRITICAL

## The Problem
Database stores roles with varying case: "Manager", "ADMIN", "super-admin"
Code comparisons are case-sensitive.

## The Rule
ALWAYS use .toLowerCase() for role comparisons:
```typescript
const role = session.user.role?.toLowerCase();
if (role === 'manager') { ... }
```

## Historical Bugs
- Jan 2026: Managers got "Scheduling Conflict" errors
- Dec 2025: Dashboard icons hidden from admins
```

Agents read these memory files to avoid repeating mistakes.

---

## Documentation Cache

Instead of slow Context7 calls, use cached JSON:

```
~/.claude/docs-cache/
├── index.json           # Keyword index
├── nextjs-15/           # Next.js patterns
├── typescript/          # TypeScript patterns
├── drizzle/             # Drizzle ORM patterns
└── testing/             # Vitest/Playwright patterns
```

**Performance:** 50-100ms vs 5-10s Context7 fetches

---

## Verification Checklist

After implementation:
- [ ] `/quetrex-issue "test"` spawns full team
- [ ] Stop hook blocks exit when tests fail
- [ ] Tests pass → exit allowed
- [ ] Skills auto-discover for developer
- [ ] Project memory files are read by agents
- [ ] Works in NEW projects without copying

---

## Next Steps

1. New agent reads this file: `~/.claude/docs/quetrex-foundation-plan.md`
2. Start with Phase A (hooks + docs)
3. Then Phase B (agents)
4. Then Phase C (skills)
5. Then Phase D (commands)
6. Finally Phase E (cleanup GoAutoSocial)

**Full detailed plan:** `~/.claude/plans/vast-noodling-riddle.md`
