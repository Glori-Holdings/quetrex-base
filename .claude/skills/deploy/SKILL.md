---
name: deploy
description: Deploy the project to staging or production on Fly.io. Creates a git rollback tag before every deploy. Run /deploy rollback to instantly revert to the previous release.
argument-hint: <staging|production> | rollback <staging|production>
disable-model-invocation: true
allowed-tools: Bash
---

# Deploy to Fly.io

> **Setup**: Copy this skill to `~/.claude/skills/deploy/SKILL.md` and update the app names below for your project.
> Skills in `~/.claude/skills/` are globally available across all projects.

## Apps

| Environment | Fly.io App | URL |
|---|---|---|
| staging | `{staging-app-name}` | https://{staging-app-name}.fly.dev |
| production | `{production-app-name}` | https://{production-app-name}.fly.dev |

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
APP = {staging-app-name} (staging) | {production-app-name} (production)
URL = https://{staging-app-name}.fly.dev | https://{production-app-name}.fly.dev
```

If arguments are missing or invalid, print usage and stop.

---

## Step 2: Pre-Flight Checks

```bash
# Verify fly CLI is authenticated
fly auth whoami

# Verify app exists and is reachable
fly status --app $APP

# Confirm we're on main and it's clean (production only)
git branch --show-current
git status --porcelain
```

For **production deploys only**: if the working tree is dirty or not on main, stop and warn the user.

---

## Step 3: Create Rollback Tag (deploy only, not rollback)

```bash
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
TAG="deploy/$ENVIRONMENT/$TIMESTAMP"
git tag $TAG
git push origin $TAG
echo "Rollback tag created: $TAG"
```

---

## Step 4A: Deploy

```bash
echo "Deploying to $ENVIRONMENT ($APP)..."
fly deploy --app $APP --strategy rolling
```

Fly.io's rolling strategy starts new instances alongside old ones and only cuts over when health checks pass.

---

## Step 4B: Rollback

```bash
echo "Rolling back $ENVIRONMENT ($APP)..."

RELEASES=$(fly releases list --app $APP --json 2>/dev/null)

PREVIOUS_IMAGE=$(python3 -c "
import json, sys
releases = json.loads('$RELEASES')
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

## Step 5: Smoke Test

```bash
echo "Running smoke tests against $URL..."
SMOKE_FAILED=0

ROOT_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "$URL")
[[ "$ROOT_STATUS" != "200" && "$ROOT_STATUS" != "302" && "$ROOT_STATUS" != "307" ]] && echo "FAIL: Root returned $ROOT_STATUS" && SMOKE_FAILED=1

LOGIN_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "$URL/login")
[[ "$LOGIN_STATUS" != "200" ]] && echo "FAIL: /login returned $LOGIN_STATUS" && SMOKE_FAILED=1

API_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "$URL/api/auth/providers")
[[ "$API_STATUS" != "200" ]] && echo "FAIL: /api/auth/providers returned $API_STATUS" && SMOKE_FAILED=1

[ $SMOKE_FAILED -eq 0 ] && echo "All smoke tests passed." || echo "WARNING: Smoke tests failed. Check: fly logs --app $APP"
```

---

## Step 6: Report

```
=====================================================
 Deploy Complete
=====================================================
 Environment : $ENVIRONMENT
 App         : $APP
 Action      : deployed | rolled back
 Rollback tag: $TAG  (deploy only)
 Smoke tests : passed | WARNING
 Logs        : fly logs --app $APP
 Dashboard   : https://fly.io/apps/$APP
=====================================================
```

If production smoke tests failed: remind the user to run `/deploy rollback production`.
