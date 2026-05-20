---
description: One-time repository setup — creates GitHub Actions CI, sets branch protection, creates project CLAUDE.md. Run once per new project.
---

# Project Setup

Sets up a repository to work with the quetrex-base pipeline. Run once per project, not once per developer.

## Pre-flight

1. Verify git repo: `git status` — must be in a git repo
2. Verify gh auth: `gh auth status` — must be authenticated
3. Get repo info: `gh repo view --json name,owner,defaultBranchRef`
4. Confirm with user: "Setting up {owner}/{name}. Default branch: {branch}. Proceed?"

## Step 1: GitHub Actions CI

Create `.github/workflows/quality-gate.yml`:

```bash
mkdir -p .github/workflows
```

Write the file with this exact content:

```yaml
name: Quality Gate
on:
  pull_request:
    branches: [main]

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  quality:
    name: Lint & Type Check
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: 'npm'
      - run: npm ci
      - run: npm run type-check
      - run: npm run lint

  test:
    name: Unit & Integration Tests
    runs-on: ubuntu-latest
    needs: quality
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: 'npm'
      - run: npm ci
      - run: npm run test -- --coverage

  build:
    name: Production Build
    runs-on: ubuntu-latest
    needs: [test]
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: 'npm'
      - run: npm ci
      - run: npm run build
```

## Step 2: Branch Protection

Set branch protection on main requiring CI to pass before merge:

```bash
gh api repos/{owner}/{repo}/branches/main/protection \
  --method PUT \
  --field required_status_checks='{"strict":true,"contexts":["Lint & Type Check","Unit & Integration Tests","Production Build"]}' \
  --field enforce_admins=false \
  --field required_pull_request_reviews='{"required_approving_review_count":0}' \
  --field restrictions=null
```

If this fails (e.g. free GitHub account), warn the user and continue — it's not fatal.

## Step 3: Project CLAUDE.md

If `.claude/CLAUDE.md` does not exist, create it:

```markdown
# Project: {repo-name}

## Stack
[Ask user: "What's the tech stack for this project? I'll add it to the project rules." Then write what they tell you.]

## Key Conventions
- All work on feature branches — never commit to main
- PRs require CI to pass before merge
- Use /issue-prd {ISSUE-ID} to start work on a Linear issue
```

If it already exists, skip this step.

## Step 4: Commit and Push

```bash
git add .github/workflows/quality-gate.yml .claude/CLAUDE.md
git commit -m "chore: project setup — CI, branch protection, CLAUDE.md"
git push origin main
```

## Confirm

Report:
> "Project setup complete.
> - CI: .github/workflows/quality-gate.yml created
> - Branch protection: main requires Lint & Type Check, Unit & Integration Tests, Production Build
> - CLAUDE.md: {created/already existed}
>
> Partners can clone and start working immediately after running: npm install -g @quetrex/base"

## Notes
- Run from the project root
- Only the repo owner needs to run this — collaborators who clone get everything automatically
- Branch protection requires a paid GitHub account for private repos
- Customize quality-gate.yml for your stack (e.g. add Playwright if you have E2E tests)
