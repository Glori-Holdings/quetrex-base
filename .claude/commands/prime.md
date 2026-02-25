---
description: Prime agent with codebase understanding
---

# Prime: Load Project Context

## Objective

Build comprehensive understanding of the codebase by analyzing structure, documentation, and key files.

## Process

### 1. Analyze Project Structure

List all tracked files:
!`git ls-files`

Show directory structure:
On Linux, run: `tree -L 3 -I 'node_modules|__pycache__|.git|dist|build'`

### 2. Check Project Health

**Check for CLAUDE.md** at the project root. If it does not exist, tell the user:

> "No CLAUDE.md found at project root. Run `/create-rules` to generate one from the codebase. This file is essential for giving Claude consistent context across sessions."

**Check for `.github/workflows/`**. If the directory does not exist or is empty, tell the user:

> "No CI workflows found in .github/workflows/. Run `/create-rules` to generate a quality gate workflow. This ensures type-check, lint, tests, and builds run on every pull request."

**Check for existing PRDs** in `.claude/prds/`. List any `.md` files found (excluding `.gitkeep`):
!`ls .claude/prds/ 2>/dev/null | grep -v .gitkeep || echo "No PRDs found"`

If PRDs exist, display them as a list so the agent knows what work is in progress or has been planned.

### 3. Read Core Documentation

- Read `CLAUDE.md` if it exists
- Read `README.md` at project root
- Read any architecture documentation in `.agents/` or `docs/`
- Read the drizzle config if present so you understand the database schema

### 4. Identify Key Files

Based on the structure, identify and read:
- Main entry points (main.py, index.ts, app.py, src/app/layout.tsx, etc.)
- Core configuration files (pyproject.toml, package.json, tsconfig.json, biome.json)
- Key model/schema definitions
- Important service or controller files

### 5. Understand Current State

Check recent activity:
!`git log -10 --oneline`

Check current branch and status:
!`git status`

Check current branch name:
!`git branch --show-current`

## Output Report

Provide a concise summary covering:

### Project Overview
- Purpose and type of application
- Primary technologies and frameworks
- Current version/state

### Architecture
- Overall structure and organization
- Key architectural patterns identified
- Important directories and their purposes

### Tech Stack
- Languages and versions
- Frameworks and major libraries
- Build tools and package managers
- Testing frameworks

### Core Principles
- Code style and conventions observed
- Documentation standards
- Testing approach

### Current State
- Active branch
- Recent changes or development focus
- Any immediate observations or concerns

### PRDs in Progress
- List any PRDs found in `.claude/prds/` with their issue IDs
- Note if no PRDs exist yet

### Setup Gaps
- Missing CLAUDE.md (run `/create-rules` to fix)
- Missing CI workflows (run `/create-rules` to fix)

**Make this summary easy to scan - use bullet points and clear headers.**
