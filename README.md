# Quetrex Base

Claude Code base configuration for development teams. Agents, skills, and commands for a complete AI-powered development pipeline — from plan to merged PR.

> **Tracker-agnostic.** The base ships no tracker/issue commands. Per-project tracker wiring
> (fetching work items, advancing status columns) is provided by project-level setup
> (`quetrex-init`, forthcoming).

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
/quetrex-setup
```

Configures GitHub CLI auth, git identity, API keys, and direnv.

## First Time on a New Project

```bash
/project-setup    # CI, branch protection, direnv
/create-rules     # Stack configuration (Next.js, Python, Rust, Rails, iOS, Go, Node.js)
```

## Planning Work

```bash
/plan-feature     # Codebase analysis + implementation plan for a feature
/create-prd       # Generate a PRD from the current conversation
```

## The Pipeline

```
architect → developer(s) → QA → reviewer → git-workflow → (open PR)
```

Each stage is a specialized agent. QA proves green with actual exit codes. The reviewer (Opus) reads the full diff. PRs squash-merge to main. The pipeline terminus is an open PR awaiting human merge.

## All Commands

| Command | What it does |
|---|---|
| `/quetrex-docs` | Full reference — pipeline, commands, agents, setup |
| `/quetrex-setup` | One-time machine setup |
| `/project-setup` | One-time project setup |
| `/create-rules` | Generate project stack configuration |
| `/update-rules` | Audit and fix existing project rules |
| `/plan-feature` | Plan a feature for an existing codebase |
| `/create-prd` | Generate a PRD from conversation |
| `/deploy-setup` | Generate project-specific deploy skill |
| `/secrets` | Manage API keys |
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
