# Quetrex Base

Claude Code base configuration for development teams. Agents, skills, and commands for a complete AI-powered development pipeline — from task to merged PR — wired to the Quetrex kanban.

> **Successor / current model.** The pipeline engine now ships as the **`quetrex-factory`** plugin (plus per-stack packs) from the private marketplace **`Glori-Holdings/quetrex-plugins`**, installed via Claude Code's native plugin system. Behavior that supersedes older docs anywhere in this repo:
> - **Merge is auto-gated** by the review agent — a clean review auto-merges; there is no `/q-task-merge`. Only production deploy is manual.
> - **Update via native `/plugin update`** — there is no `/quetrex-update`.
> - The team runs **`auto` permission mode**, not `--dangerously-skip-permissions`.
>
> The onboarding guide lives in the marketplace repo (`docs/onboarding/`). This repo remains the kanban-integration command layer during the transition.

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
/q-login
```

Logs in to the Quetrex kanban via browser device-flow and stores a per-user API token.

## First Time on a New Project

```bash
/q-init     # Link the repo to a Quetrex project (also sets up Verification rules)
```

## Planning Work

```bash
/q-task-new         # Create a Backlog task on the kanban
/q-task-refine      # Refine a task into a clear, buildable spec
```

## The Pipeline

```
architect → developer(s) → QA → reviewer → git-workflow → (open PR)
```

Each stage is a specialized agent. QA proves green with actual exit codes. The reviewer (Opus) reads the full diff. PRs squash-merge to main. The pipeline terminus is an open PR awaiting human merge.

## All Commands

| Command | What it does |
|---|---|
| `/q-login` | One-time machine login to the Quetrex kanban |
| `/q-init` | Link a repo to a Quetrex project; set up Verification rules |
| `/q-task-new` | Create a Backlog task on the kanban |
| `/q-task-refine` | Refine a task into a buildable spec |
| `/q-task-build` | Vet, classify, and build a task end to end |
| `/q-task-rework` | Re-plan and re-run a failed task |
| `/q-task-merge` | Squash-merge a task's PR with cleanup |
| `/q-task-complete` | Mark a deployed task Complete |
| `/q-deploy` | Deploy the project's app from vault secrets |
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
