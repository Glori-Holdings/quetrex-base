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

Check if `.claude/CLAUDE.md` already exists:

```bash
[ -f .claude/CLAUDE.md ] && echo "exists" || echo "missing"
```

**If missing:** Create a minimal placeholder:
```bash
mkdir -p .claude
cat > .claude/CLAUDE.md << 'EOF'
# Project: {repo-name}

## Stack
Run /create-rules to generate the full stack configuration.

## Workflow
- All work on feature branches — never commit to main
- PRs require CI to pass before merge
- Use /issue-prd {ISSUE-ID} to start work on a Linear issue
EOF
```

**If exists:** Check if it has a `## Verification` section:
```bash
grep -q "## Verification" .claude/CLAUDE.md && echo "has verification" || echo "missing verification"
```

If the Verification section is missing, note it in the summary — the user should run `/update-rules` after setup.

## Step 4: direnv .envrc

Check if direnv is installed:

```bash
which direnv 2>/dev/null && echo "installed" || echo "missing"
```

If installed and `.envrc` does not already exist:

```bash
echo 'dotenv' > .envrc
direnv allow .
```

This tells direnv to load the project's `.env` file automatically when anyone enters the directory — database URLs, project API tokens, and other credentials become available to all commands (including Claude's) without manual sourcing.

If `.envrc` already exists, skip. If direnv is not installed, skip and note it in the summary.

## Step 5: Commit and Push

```bash
git add .github/workflows/quality-gate.yml .claude/CLAUDE.md
[ -f .envrc ] && git add .envrc
git commit -m "chore: project setup — CI, branch protection, CLAUDE.md, direnv"
git push origin main
```

## Confirm

Report:
> "Project setup complete.
> - CI: .github/workflows/quality-gate.yml created
> - Branch protection: main requires Lint & Type Check, Unit & Integration Tests, Production Build
> - CLAUDE.md: {created with placeholder / already existed}
> - direnv: {.envrc created / already existed / direnv not installed — run /quetrex-setup}
>
> Next: run /create-rules to set up your stack configuration and verification commands."
>
> Partners can clone and start working immediately after: npm install -g @quetrex/base"

## Notes
- Run from the project root
- Only the repo owner needs to run this — collaborators who clone get everything automatically
- Branch protection requires a paid GitHub account for private repos
- direnv loads project .env automatically — without it, database and service credentials must be manually exported before each session
- Customize quality-gate.yml for your stack (e.g. add Playwright if you have E2E tests)
