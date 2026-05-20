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

## Generate Deploy Skill

Based on answers, create `.claude/skills/deploy/SKILL.md`:

The file must include:
- The exact deploy commands for each environment (staging and production)
- A pre-deploy checklist (migrations, checks, etc. from Q4)
- The rollback procedure (from Q3)
- A confirmation gate before deploying to production ("Are you sure you want to deploy to PRODUCTION? This affects live users.")
- Post-deploy verification steps (check the URL, confirm key flows work)

Structure it as:

```markdown
---
name: deploy
description: Deploy this project to staging or production. Usage: /deploy staging or /deploy production
argument-hint: staging | production
---

# Deploy: {project-name}

## Environments
- Staging: {staging URL}
- Production: {production URL}

## Pre-Deploy Checklist
[from Q4]

## Deploy

### Staging
[exact commands]

### Production
[confirmation gate + exact commands]

## Rollback
[from Q3]

## Post-Deploy Verification
[check the URL, confirm key flows]
```

## Commit

```bash
mkdir -p .claude/skills/deploy
git add .claude/skills/deploy/SKILL.md
git commit -m "chore(deploy): add project-specific deploy skill for {platform}"
```

Report: "Deploy skill created. Use /deploy staging or /deploy production from now on."
