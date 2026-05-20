---
description: Review and update an existing project .claude/CLAUDE.md for quetrex compatibility. Audits current rules, identifies gaps, validates commands against the actual codebase, and brings it up to quetrex standards.
---

# Update Project Rules

Audits `.claude/CLAUDE.md` and brings it up to quetrex standards. Use on projects that already have rules but may be incomplete, outdated, or not aligned with the quetrex pipeline.

If no `.claude/CLAUDE.md` exists, say: "No project rules found. Run `/create-rules` to generate them from scratch." Then stop.

---

## Step 1: Read and Summarise

Read `.claude/CLAUDE.md` and show a one-paragraph summary of what it currently covers.

---

## Step 2: Audit Against Quetrex Requirements

Check each item — report **Present**, **Missing**, or **Needs Update**:

**Critical — QA agent cannot work without these:**
- `## Verification` section exists
- Verification section contains actual runnable commands
- Verification commands match the detected stack
- Every command in Verification exists as a script or binary (checked in Step 3)

**Important — developer agent quality:**
- `## Stack` section with language, framework, key libraries
- `## Conventions` with type safety / code quality rules for this language
- `## Key Commands` for dev server and common tasks

**Nice to have:**
- Project name in heading
- File structure conventions
- Database commands

---

## Step 3: Validate Commands Against the Codebase

Check that the commands in the Verification section will actually work:

```bash
# Node/TypeScript — verify scripts exist in package.json
cat package.json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print('\n'.join(d.get('scripts',{}).keys()))" 2>/dev/null

# Python — verify tools are configured
grep -E "ruff|mypy|pytest" pyproject.toml 2>/dev/null || grep -E "ruff|mypy|pytest" setup.cfg 2>/dev/null

# Rust — check Cargo.toml exists
cat Cargo.toml 2>/dev/null | head -5

# Ruby — check Gemfile for test/lint gems
grep -E "rspec|rubocop" Gemfile 2>/dev/null

# Go — check go.mod
cat go.mod 2>/dev/null | head -3
```

Flag any Verification command that references a script or binary that doesn't exist or isn't installed. Examples:
- `npm run type-check` listed but no `type-check` in package.json → flag it
- `ruff check .` listed but `ruff` not in pyproject.toml dev deps → flag it

---

## Step 4: Ask Only What's Needed

Ask targeted questions only about what is missing, incorrect, or unclear. Do not ask about things that are already correct.

Examples:
- Verification missing: "What commands should run before every PR?"
- Script mismatch: "The rules say `npm run lint` but package.json uses `biome check`. Which is correct?"
- Stack unclear: "I can see Next.js but can't determine the ORM. Drizzle or Prisma?"
- Framework version wrong: "The rules say Next.js 14 but package.json shows 16. Should I update?"
- Type-check script missing: "No `type-check` script in package.json. Should I add `\"type-check\": \"tsc --noEmit\"` to your scripts?"

---

## Step 5: Show Recommendations

Present a clear audit report before making any changes:

```
## Audit: .claude/CLAUDE.md

### Must Fix
- MISSING: Verification section — QA agent cannot run without this
- BROKEN: `npm run lint` not in package.json (script is named `check`)

### Should Update
- OUTDATED: Stack says Next.js 14 — package.json shows 16.0.2

### Looks Good
- Conventions section is comprehensive and accurate
- Key Commands are correct

Apply these updates?
```

Wait for confirmation.

---

## Step 6: Apply Updates

Make only the targeted changes — add missing sections, fix outdated content, correct broken commands. Do not remove content that is already correct and project-specific.

```bash
git add .claude/CLAUDE.md
git commit -m "chore: update project rules — {one-line summary of what changed}"
```

Report: "Rules updated. [N] issues fixed. `.claude/CLAUDE.md` is quetrex-ready."
