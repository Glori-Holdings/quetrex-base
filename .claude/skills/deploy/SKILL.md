---
name: deploy
description: Deploy dealerQ to Fly.io staging (dealerq-staging) or production (goautosocial). Creates a git rollback tag before every deploy. Run /deploy rollback to instantly revert to the previous release.
argument-hint: <staging|production> | rollback <staging|production>
disable-model-invocation: true
allowed-tools: Bash
---

# Deploy to Fly.io

Deploy dealerQ to staging or production, with automatic rollback support.

## Apps

| Environment | Fly.io App | URL |
|---|---|---|
| staging | `dealerq-staging` | https://dealerq-staging.fly.dev |
| production | `goautosocial` | https://goautosocial.fly.dev |

---

## Usage

```
/deploy staging              # Deploy main → staging
/deploy production           # Deploy main → production
/deploy rollback staging     # Roll back staging to previous release
/deploy rollback production  # Roll back production to previous release
```

---

## Step 1: Parse Arguments

Read the command arguments:
- First arg: `staging` | `production` | `rollback`
- Second arg (if rollback): `staging` | `production`

Set variables:
```
ENVIRONMENT = staging | production
APP = dealerq-staging (staging) | goautosocial (production)
URL = https://dealerq-staging.fly.dev | https://goautosocial.fly.dev
```

If arguments are missing or invalid, print usage and stop.

---

## Step 2: Pre-Flight Checks

Run these checks before doing anything:

```bash
# Verify fly CLI is authenticated
fly auth whoami

# Verify app exists and is reachable
fly status --app $APP

# Confirm we're on main and it's clean (production only)
git branch --show-current
git status --porcelain
```

For **production deploys only**: if the working tree is dirty or not on main, stop and warn the user. Staging is more permissive — deploy whatever is on main.

**For ALL deploys (staging and production)**: Check for open PRs:

```bash
OPEN_PRS=$(gh pr list --repo Barnhardt-Enterprises-Inc/dealerq-2026 --state open --json number,title --jq '.[] | "#\(.number): \(.title)"')
if [ -n "$OPEN_PRS" ]; then
  echo "DEPLOY BLOCKED: You have unmerged PRs:"
  echo "$OPEN_PRS"
  echo ""
  echo "Merge or close all PRs before deploying."
  # STOP — do not proceed with deploy
fi
```

If there are open PRs, **STOP the deploy** and show the user the list. Do not proceed until all PRs are merged or closed.

---

## Step 3: Create Rollback Tag (deploy only, not rollback)

Before every deploy, tag the current state of main so we can always get back:

```bash
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
TAG="deploy/$ENVIRONMENT/$TIMESTAMP"

git tag $TAG
git push origin $TAG

echo "Rollback tag created: $TAG"
echo "To roll back: /deploy rollback $ENVIRONMENT"
```

Also capture the current Fly.io release image for rollback:

```bash
CURRENT_IMAGE=$(fly releases --app $APP --json | python3 -c "
import json, sys
releases = json.load(sys.stdin)
if len(releases) > 0:
    print(releases[0].get('imageRef', ''))
" 2>/dev/null)
echo "Current image: $CURRENT_IMAGE"
```

---

## Step 4A: Deploy

```bash
echo "Deploying to $ENVIRONMENT ($APP)..."
fly deploy --app $APP --strategy rolling
```

Fly.io's rolling strategy:
- Starts new instances alongside old ones
- Only cuts over when health checks pass
- Automatically aborts if health checks fail

Wait for deploy to complete. If `fly deploy` exits non-zero, stop and report failure.

---

## Step 4B: Rollback

Get the previous release image and redeploy it:

```bash
echo "Rolling back $ENVIRONMENT ($APP)..."

# Get the two most recent releases
RELEASES=$(fly releases --app $APP --json 2>/dev/null)

PREVIOUS_IMAGE=$(python3 -c "
import json, sys
releases = json.loads('$RELEASES')
# Index 0 = current (failed), index 1 = previous (good)
if len(releases) > 1:
    print(releases[1].get('imageRef', ''))
else:
    print('')
" 2>/dev/null)

if [ -z "$PREVIOUS_IMAGE" ]; then
  echo "ERROR: No previous release found to roll back to."
  exit 1
fi

echo "Rolling back to image: $PREVIOUS_IMAGE"
fly deploy --app $APP --image $PREVIOUS_IMAGE
```

---

## Step 4C: Database Schema Migration (deploy only, not rollback)

**CRITICAL: Fly.io deploys do NOT run database migrations. Schema changes in merged PRs must be applied manually. This step automates that.**

After a successful `fly deploy`, check whether any commits since the last deploy touched `lib/db/schema.ts`. If so, apply the missing schema changes to the target database.

### How it works

1. **Detect schema changes** — Compare `lib/db/schema.ts` between the previous deploy tag and HEAD:

```bash
PREV_TAG=$(git tag -l "deploy/$ENVIRONMENT/*" --sort=-version:refname | sed -n '2p')
SCHEMA_CHANGED=$(git diff "$PREV_TAG"..HEAD --name-only | grep -c 'lib/db/schema.ts' || true)
```

If `SCHEMA_CHANGED` is 0, print "No schema changes detected — skipping migration." and move to Step 5.

2. **Determine the target database URL** — Based on the environment:
   - **staging**: Use `DATABASE_URL` from `.env.local`
   - **production**: Use `PRODUCTION_DATABASE_URL` from `.env.local`

3. **Identify what's missing** — Read the current `lib/db/schema.ts` to find all tables and columns defined in Drizzle. Then query `information_schema.columns` and `information_schema.tables` on the target database to find what exists. The difference is what needs to be migrated.

   Focus on these change types (in order):
   - **New tables** (`pgTable` definitions not present in DB) → `CREATE TABLE IF NOT EXISTS`
   - **New columns** on existing tables → `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`
   - **New indexes** → `CREATE INDEX IF NOT EXISTS`

4. **Generate and run migration SQL** — For each missing item, generate the appropriate DDL:
   - Use `IF NOT EXISTS` / `IF NOT EXISTS` on everything to make migrations idempotent
   - Match column types from the Drizzle schema:
     - `uuid()` → `uuid`
     - `varchar('name', { length: N })` → `varchar(N)`
     - `text('name')` → `text`
     - `boolean('name')` → `boolean`
     - `integer('name')` → `integer`
     - `timestamp('name')` → `timestamp` (add `with time zone` if `{ withTimezone: true }`)
     - `jsonb('name')` → `jsonb`
   - Preserve `.default()` values, `.notNull()` constraints, and `.references()` foreign keys
   - Run each statement via `npx tsx --env-file=.env.local` using `@neondatabase/serverless`

5. **Verify** — After migration, re-query `information_schema` to confirm all expected tables and columns now exist. Print a summary table showing what was added.

### Important rules

- **ALWAYS use `IF NOT EXISTS`** — migrations must be safe to re-run
- **NEVER drop tables, columns, or indexes** — only additive changes. If schema.ts removed something, ignore it (manual cleanup)
- **Check `information_schema.columns` BEFORE running ALTER TABLE** — never guess column names
- **Run staging first, verify, then production** — even within a single deploy, if both need changes
- **Wrap in async IIFE** — `npx tsx` requires `(async () => { ... })();` pattern for top-level await
- **Use neon() serverless driver** — `const { neon } = require('@neondatabase/serverless');`
- Print each DDL statement as it runs so the user can see progress
- If any statement fails, report the error but continue with remaining statements (don't abort the whole migration)

### Report format

After migration, print:

```
=== Schema Migration: $ENVIRONMENT ===
+ table_name.column_name (type)
+ new_table_name (CREATE TABLE)
+ index_name (CREATE INDEX)
= N changes applied, M already existed
```

If nothing needed migration: "No schema changes needed — database is in sync."

---

## Step 5: Smoke Test

After a successful deploy OR rollback, run a smoke test to verify the app is responding correctly:

```bash
echo "Running smoke tests against $URL..."

# Test 1: Root responds with redirect or 200
ROOT_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "$URL")
if [[ "$ROOT_STATUS" != "200" && "$ROOT_STATUS" != "302" && "$ROOT_STATUS" != "307" ]]; then
  echo "FAIL: Root returned $ROOT_STATUS (expected 200/302/307)"
  SMOKE_FAILED=1
fi

# Test 2: Login page is reachable
LOGIN_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "$URL/login")
if [[ "$LOGIN_STATUS" != "200" ]]; then
  echo "FAIL: /login returned $LOGIN_STATUS (expected 200)"
  SMOKE_FAILED=1
fi

# Test 3: API health check
API_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "$URL/api/auth/providers")
if [[ "$API_STATUS" != "200" ]]; then
  echo "FAIL: /api/auth/providers returned $API_STATUS (expected 200)"
  SMOKE_FAILED=1
fi

if [ -z "$SMOKE_FAILED" ]; then
  echo "All smoke tests passed."
else
  echo "WARNING: Some smoke tests failed. App may be partially degraded."
  echo "Check logs: fly logs --app $APP"
fi
```

---

## Step 5B: Label Linear Issues (staging deploys only, not rollback)

After smoke tests pass on a **staging deploy**, find all Linear issues referenced in commits since the last deploy and add the "staged" label.

**Skip this step entirely if:**
- This is a rollback
- This is a production deploy
- Smoke tests failed

```bash
# Find the previous deploy tag for staging
PREV_TAG=$(git tag -l "deploy/staging/*" --sort=-version:refname | sed -n '2p')

if [ -z "$PREV_TAG" ]; then
  echo "No previous staging deploy tag found — skipping Linear labeling (first deploy)."
else
  # Extract unique SMA issue numbers from commits between tags
  ISSUES=$(git log --oneline "$PREV_TAG"..HEAD | grep -oiE 'sma-[0-9]+' | tr '[:upper:]' '[:lower:]' | sort -u)

  if [ -z "$ISSUES" ]; then
    echo "No SMA issues found in commits since $PREV_TAG — skipping Linear labeling."
  else
    echo "Found issues to label as staged: $ISSUES"
    LABELED_ISSUES=""

    for ISSUE in $ISSUES; do
      # Extract the number from sma-N
      ISSUE_NUM=$(echo "$ISSUE" | sed 's/sma-//')

      # Query Linear for the issue UUID (team-scoped)
      ISSUE_ID=$(curl -s -X POST https://api.linear.app/graphql \
        -H "Content-Type: application/json" \
        -H "Authorization: lin_api_cAIeO7edgbe03NRQsaxmRQMXVWdmUF7JMeddW7C0" \
        -d "{\"query\": \"{ team(id: \\\"55e6dc25-090c-4731-82c2-44549801a709\\\") { issues(filter: { number: { eq: $ISSUE_NUM } }) { nodes { id identifier } } } }\"}" \
        | python3 -c "import json,sys; nodes=json.load(sys.stdin)['data']['team']['issues']['nodes']; print(nodes[0]['id'] if nodes else '')" 2>/dev/null)

      if [ -n "$ISSUE_ID" ]; then
        # Add "staged" label to the issue
        curl -s -X POST https://api.linear.app/graphql \
          -H "Content-Type: application/json" \
          -H "Authorization: lin_api_cAIeO7edgbe03NRQsaxmRQMXVWdmUF7JMeddW7C0" \
          -d "{\"query\": \"mutation { issueAddLabel(id: \\\"$ISSUE_ID\\\", labelId: \\\"04d4184e-8f95-4a03-aadc-759bb216d9ed\\\") { success } }\"}" \
          > /dev/null 2>&1
        LABELED_ISSUES="$LABELED_ISSUES $(echo $ISSUE | tr '[:lower:]' '[:upper:]')"
        echo "  Labeled $ISSUE as staged"
      else
        echo "  Could not find Linear issue for $ISSUE — skipping"
      fi
    done

    if [ -n "$LABELED_ISSUES" ]; then
      echo "Labeled issues:$LABELED_ISSUES"
    fi
  fi
fi
```

Store the `LABELED_ISSUES` value for the deploy report in Step 7.

---

## Step 7: Report

Print a clear summary:

```
=====================================================
 Deploy Complete
=====================================================
 Environment : staging | production
 App         : dealerq-staging | goautosocial
 Action      : deployed | rolled back
 Rollback tag: deploy/staging/20260226-143022  (deploy only)
 Schema sync : N changes applied | No changes needed | Skipped (rollback)
 Smoke tests : passed | WARNING: N checks failed
 Staged issues: SMA-40 SMA-48 ...  (staging only, if any)
 Logs        : fly logs --app $APP
 Dashboard   : https://fly.io/apps/$APP
=====================================================
```

If this was a **production deploy** and smoke tests failed, remind the user:
```
To roll back immediately: /deploy rollback production
```

---

## Notes

- **Staging** is for validating features before production. Always deploy to staging first.
- **Production** is `goautosocial` — the live app. Treat it carefully.
- Rollback tags are permanent git tags — they let you restore the exact code state if Fly.io image rollback isn't enough.
- `fly deploy` handles zero-downtime automatically via rolling strategy.
- To inspect recent releases: `fly releases --app goautosocial`
- To tail live logs: `fly logs --app goautosocial`
- The NODE_VERSION in fly.toml is `20` — note this differs from the `>=24` requirement in package.json. Flag this for a future update.
- **Fly.io does NOT run database migrations.** Step 4C handles this by diffing schema.ts against the live database and applying missing DDL. Only additive changes (new tables, columns, indexes) are applied — never drops.
- Database URLs: staging = `DATABASE_URL`, production = `PRODUCTION_DATABASE_URL` (both in `.env.local`)
- Use `npx tsx --env-file=.env.local` for all database scripts — never bare `npx tsx`.
