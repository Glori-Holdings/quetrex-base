---
description: Set up deployment for this project — interviews about platform and environments, then generates a project-level /deploy skill tailored to this project.
---

# Deploy Setup

Generates a project-specific `.claude/skills/deploy/SKILL.md` by interviewing you about your deployment setup. Run once per project. After this, /deploy works for this specific project.

## Interview

Ask these questions one at a time, wait for each answer:

**Q1 — Platform:**
"What platform are you deploying to? (Fly.io, Vercel, Railway, Render, AWS, DigitalOcean, VPS, other?)"

**Q2 — Environments:**
"What environments do you have? For example: staging at app-staging.fly.dev and production at app.fly.dev. What are the exact names/URLs?"

**Q3 — Rollback:**
"How do you roll back a bad deploy? (e.g., Fly.io machine rollback, Vercel instant rollback, git tag + redeploy, manual)"

**Q4 — Pre-deploy checks:**
"Are there any steps that must run before deploying? (database migrations, smoke tests, build verification, etc.)"

**Q5 — Deploy command:**
"What's the exact command to deploy? If you're not sure, I'll generate a best-guess based on your platform."

## Platform Auth Reference

Use this to generate the correct auth prerequisite for the deploy skill.

Each platform falls into one of two categories:

**CLI-authenticated** — developer logs in once, token stored by the CLI tool:

| Platform | Auth check | Auth command if missing |
|---|---|---|
| Fly.io | `fly auth whoami` | `fly auth login` |
| Vercel | `vercel whoami` | `vercel login` |
| Railway | `railway whoami` | `railway login` |
| DigitalOcean | `doctl auth list` | `doctl auth init` |
| AWS | `aws sts get-caller-identity` | `aws configure` |

**API token required** — no CLI auth flow, token goes in secrets.env:

| Platform | Token var | Where to get it |
|---|---|---|
| Render | `RENDER_API_TOKEN` | Render dashboard → Account → API Keys |
| Netlify | `NETLIFY_AUTH_TOKEN` | Netlify → User settings → Personal access tokens |

For API token platforms: check that the token is set (`echo ${TOKEN_VAR:+set}`) and direct the user to `/secrets add TOKEN_VAR` if missing.

## Generate Deploy Skill

Based on all answers, create `.claude/skills/deploy/SKILL.md`.

The file must include:

1. **Auth prerequisite** — using the platform reference above, the correct check at the very top
2. **Environments** — staging and production URLs/app names
3. **Pre-deploy checklist** — from Q4
4. **Deploy commands** — per environment
5. **Production confirmation gate** — explicit "Are you sure?" before touching production
6. **Rollback procedure** — from Q3
7. **Post-deploy verification** — check URL, confirm key flows work

### Template

```markdown
---
name: deploy
description: Deploy {project-name} to staging or production. Usage: /deploy staging or /deploy production
argument-hint: staging | production
---

# Deploy: {project-name}

## Auth Prerequisite

[For CLI-authenticated platforms:]
```bash
{auth-check-command} 2>/dev/null || {
  echo "Not authenticated with {Platform}. Run: {auth-command}"
  exit 1
}
```

[For API token platforms:]
```bash
[ -n "${TOKEN_VAR}" ] || {
  echo "{TOKEN_VAR} is not set. Run: /secrets add {TOKEN_VAR}"
  exit 1
}
```

## Environments
- Staging:    {staging URL or app name}
- Production: {production URL or app name}

## Pre-Deploy Checklist
[Each item from Q4 as a bash check or manual confirmation]

## Deploy

### Staging
```bash
[exact staging deploy command(s)]
```

Verify: [what to check after staging deploy]

### Production

> "Deploying to PRODUCTION. This affects live users. Confirm?"

Wait for explicit confirmation before running:

```bash
[exact production deploy command(s)]
```

## Rollback
```bash
[exact rollback command(s) from Q3]
```

## Post-Deploy Verification
- [ ] {staging/production URL} loads without errors
- [ ] [key user flow works]
- [ ] Check logs: [log command for this platform]
```

## Also: add .envrc if direnv is available

After writing the deploy skill, check if direnv is installed:

```bash
which direnv 2>/dev/null && echo "installed" || echo "missing"
```

If installed and `.envrc` doesn't exist in the project:

```bash
[ -f .envrc ] || echo 'dotenv' > .envrc && direnv allow .
```

This makes project `.env` vars (database URLs, API tokens, etc.) automatically available to all commands — including deploy — without manual sourcing.

## Commit

```bash
mkdir -p .claude/skills/deploy
git add .claude/skills/deploy/SKILL.md
[ -f .envrc ] && git add .envrc
git commit -m "chore(deploy): add project-specific deploy skill for {platform}"
```

Report: "Deploy skill created for {platform}. Auth check, environments, rollback, and verification all included. Use /deploy staging or /deploy production from now on."
