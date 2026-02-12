---
name: deploy-production
description: Deploy to production with pre-flight checks and DB migrations
allowed-tools: Bash, Read, Grep, Glob, AskUserQuestion
---

# Deploy to Production

Production deployment with mandatory pre-flight checks, DB migration, and user confirmation.

## Phase 1: Pre-Flight Checks (automatic)

Run ALL checks before prompting. Report results as a checklist.

### Step 1: Verify Branch
```bash
BRANCH=$(git branch --show-current)
if [ "$BRANCH" != "main" ]; then
  echo "ERROR: Must be on main branch (currently on $BRANCH)"
  exit 1
fi
git pull origin main
```

### Step 2: Type Check
```bash
npm run type-check
```
If fails, STOP. Report errors. No deployment.

### Step 3: Lint
```bash
npm run lint
```
If fails, STOP. Report errors. No deployment.

### Step 4: Tests
```bash
npm run test:run
```
If fails, STOP. Report errors. No deployment.

### Step 5: Check Pending Migrations
```bash
PROD_DATABASE_URL=$(security find-generic-password -a "quetrex-runner" -s "PRODUCTION_DATABASE_URL" -w)
DATABASE_URL="$PROD_DATABASE_URL" npx drizzle-kit check
```
Uses the PRODUCTION database URL from Keychain (not `.env.local` which is staging).
Report if there are pending schema changes.

### Step 6: Report Results

Display a summary:
```
## Pre-Flight Results

- [x] Branch: main (up to date)
- [x] Type check: passed
- [x] Lint: passed
- [x] Tests: passed
- [ ] Pending migrations: Yes/No

All checks passed. Ready to deploy.
```

If ANY check failed, STOP here with error details. Do not proceed.

## Phase 2: Confirmation

Use AskUserQuestion to confirm:
- Question: "All pre-flight checks passed. Deploy to production?"
- Options: "Yes, Deploy" / "Cancel"

If "Cancel", stop immediately.

## Phase 3: Deploy

### Step 1: Get Production Database URL
```bash
PROD_DATABASE_URL=$(security find-generic-password -a "quetrex-runner" -s "PRODUCTION_DATABASE_URL" -w)
```
If this fails, STOP. The production DB URL must be in the macOS Keychain.

### Step 2: Run DB Migrations (if pending)
```bash
DATABASE_URL="$PROD_DATABASE_URL" npx drizzle-kit push
```
CRITICAL: Always use the production URL from Keychain. NEVER use `.env.local` (that's staging).
If migration fails, STOP immediately. Do NOT deploy.

### Step 3: Clear Build Cache
```bash
rm -rf .next
```

### Step 4: Deploy to Fly.io
```bash
flyctl deploy -a goautosocial
```

### Step 5: Report

```
## Deployment Complete

- App: goautosocial
- Branch: main
- Migrations: Applied / Not needed
- Status: SUCCESS
```

## Safety Rules

1. NEVER deploy from any branch other than main
2. NEVER skip pre-flight checks
3. NEVER deploy if any check fails
4. Run migrations BEFORE deploy (new code expects new schema)
5. Monitor deployment output for errors
