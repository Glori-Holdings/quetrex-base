# Quetrex Base

Claude Code base configuration for development teams. Agents, skills, and commands for a complete AI-powered development pipeline — from task to merged PR — wired to the Quetrex kanban.

## Install

```bash
npm install -g quetrex-base
```

Or install directly from GitHub (works with private repos — requires GitHub access):

```bash
npm install -g github:Barnhardt-Enterprises-Inc/quetrex-base
```

## First Time on a New Machine

```bash
/quetrex-login
```

Logs in to the Quetrex kanban via browser device-flow and stores a per-user API token.

## First Time on a New Project

```bash
/quetrex-init     # Link the repo to a Quetrex project (also sets up Verification rules)
```

## Planning Work

```bash
/quetrex-task-new         # Create a Backlog task on the kanban
/quetrex-task-refine      # Refine a task into a clear, buildable spec
```

## The Pipeline

```
architect → developer(s) → QA → reviewer → git-workflow → (open PR)
```

Each stage is a specialized agent. QA proves green with actual exit codes. The reviewer (Opus) reads the full diff. PRs squash-merge to main. The pipeline terminus is an open PR awaiting human merge.

## All Commands

| Command | What it does |
|---|---|
| `/quetrex-login` | One-time machine login to the Quetrex kanban |
| `/quetrex-init` | Link a repo to a Quetrex project; set up Verification rules |
| `/quetrex-task-new` | Create a Backlog task on the kanban |
| `/quetrex-task-refine` | Refine a task into a buildable spec |
| `/quetrex-task-build` | Vet, classify, and build a task end to end |
| `/quetrex-task-rework` | Re-plan and re-run a failed task |
| `/quetrex-task-merge` | Squash-merge a task's PR with cleanup |
| `/quetrex-task-complete` | Mark a deployed task Complete |
| `/quetrex-deploy` | Deploy the project's app from vault secrets |
| `/quetrex-update` | Check for and apply updates |

## Updates

```bash
/quetrex-update
```

Checks the installed version against npm latest and updates if behind.

## Requirements

- Node.js 18+
- Claude Code
- GitHub CLI (`gh auth login`)
