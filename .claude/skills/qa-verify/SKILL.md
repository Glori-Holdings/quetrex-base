---
name: qa-verify
description: >
  Run the pre-merge QA checklist before any PR is considered complete.
  Use when finishing implementation work to verify typecheck, lint, build,
  tests, and — when a rename or removal was involved — prove with unfiltered
  grep output that zero traces of the old term remain. Never mark a task done
  without passing this checklist.
---

# QA Verify Skill

Invoke as `/qa-verify` at the end of any implementation task before marking it done or opening a PR.

## Why this skill exists

Agents were marking rename/removal tasks complete while references remained in
shell scripts, config files, and directory names that were invisible to
file-type-filtered searches. This checklist closes that gap by requiring
unfiltered, repo-wide grep output as proof of completion.

---

## Pre-Merge Checklist

Run every check in order. A single failure means the task is NOT done.

### 1. Typecheck

```bash
pnpm run typecheck
```

Expected: zero errors. Fix all errors before proceeding.

### 2. Lint

```bash
npx biome check .
```

Expected: zero errors. Run `npx biome check --write .` to auto-fix, then
re-run the read-only check to confirm.

### 3. Build

```bash
pnpm run build
```

Expected: exits 0. Key packages must compile successfully.

### 4. Tests

```bash
pnpm test
```

Expected: all tests pass. Fix or note any pre-existing failures explicitly.

---

## Rename / Removal Verification

Run these additional steps whenever the task involved renaming something,
removing a brand, removing a dependency, or purging any term from the codebase.

Replace `TERM` with the word or phrase being removed (case-insensitive).

### 5. Unfiltered content search

```bash
grep -ri "TERM" . \
  | grep -v node_modules \
  | grep -v pnpm-lock \
  | grep -v dist \
  | grep -v ".git/"
```

**No file-type filters.** This must search `.sh`, `.yml`, `.yaml`, `.json`,
`.toml`, `.env`, `.md`, `.txt`, Dockerfiles, Makefiles — everything.

Expected: zero results (or only intentional/documented exceptions such as
LICENSE copyright headers, CHANGELOG entries, or external reference docs).
Every result must be explained in the PR description.

### 6. Filename search

```bash
find . -iname "*TERM*" \
  | grep -v node_modules \
  | grep -v dist \
  | grep -v ".git/"
```

Expected: zero results. Rename or remove any matching files or directories.

### 7. Branch name search

```bash
git branch -a | grep -i TERM
```

Expected: zero results. Delete or rename any matching local or remote branches.

---

## Security Checks

### 8. No secrets in committed files

```bash
grep -ri "api_key\|secret\|password\|token" . \
  | grep -v node_modules \
  | grep -v pnpm-lock \
  | grep -v ".git/" \
  | grep -v ".example\|.sample\|SKILL.md\|README"
```

Review every result. If a real secret appears outside an `.example` or `.env`
file that is gitignored, remove it before committing.

### 9. No `any` types in TypeScript

```bash
grep -rn ": any\b\|as any\b" --include="*.ts" --include="*.tsx" . \
  | grep -v node_modules \
  | grep -v dist
```

Expected: zero results. The project runs TypeScript strict mode.

---

## PR Quality

### 10. Feature branch

Confirm the current branch is NOT `main` or `master`:

```bash
git branch --show-current
```

### 11. Conventional commits

All commits on the branch must follow Conventional Commits format:
`type(scope): description` — e.g. `feat:`, `fix:`, `chore:`, `refactor:`.

### 12. PR description includes verification output

The PR body must include:

- The actual terminal output from the unfiltered grep (step 5), showing zero
  results or explicitly annotated exceptions.
- The actual output from the filename search (step 6).
- Confirmation that typecheck, lint, build, and tests all passed.

Paste the raw output — do not paraphrase it. Zero-result output is valid proof.

---

## Quick-Run Script

A helper script at `scripts/qa-verify.sh` automates steps 1–7 and prints a
PASS/FAIL summary. Run it as:

```bash
# Standard pre-merge check
bash scripts/qa-verify.sh

# With rename/removal verification
bash scripts/qa-verify.sh --term TERM

# Via pnpm
pnpm qa
pnpm qa -- --term TERM
```

The script exits non-zero if any check fails. Always fix failures before
marking the task done.

---

## Failure Protocol

If any check fails:

1. Fix the issue immediately — do not defer it.
2. Re-run the full checklist from the top.
3. Do not mark the task `done` or open the PR until the checklist passes clean.
4. If a check cannot be fixed (e.g., a pre-existing test failure unrelated to
   your change), document it explicitly in the PR description with evidence that
   it pre-exists your change.
