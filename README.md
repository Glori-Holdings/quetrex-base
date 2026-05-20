# Glori Builder

Claude Code base configuration for development teams. Agents, skills, and commands for a complete AI-powered development pipeline — from Linear issue to merged PR.

## Install

```bash
npm install -g glori-builder
```

Or install directly from GitHub (works with private repos — requires GitHub access):

```bash
npm install -g github:Barnhardt-Enterprises-Inc/quetrex-base
```

## First Time on a New Machine

```bash
/quetrex-setup
```

Configures GitHub CLI auth, git identity, Linear API key, and direnv.

## First Time on a New Project

```bash
/project-setup    # CI, branch protection, direnv
/create-rules     # Stack configuration (Next.js, Python, Rust, Rails, iOS, Go, Node.js)
```

## Working Issues

```bash
/issue-prd QUE-123    # Start a Linear issue through the full pipeline
/merge-issue QUE-123  # Merge the PR and update Linear
```

## Auto-Pilot (Walk Away Mode)

```bash
/plan-project         # Plan a new project → creates all Linear issues
/auto-pilot PROJECT-ID  # Works every issue autonomously until the backlog is empty
```

## The Pipeline

```
/issue-prd → architect → developer(s) → QA → reviewer → git-workflow → /merge-issue
```

Each stage is a specialized agent. QA proves green with actual exit codes. The reviewer (Opus) reads the full diff. PRs squash-merge to main.

## All Commands

| Command | What it does |
|---|---|
| `/quetrex-docs` | Full reference — pipeline, commands, agents, setup |
| `/quetrex-setup` | One-time machine setup |
| `/project-setup` | One-time project setup |
| `/create-rules` | Generate project stack configuration |
| `/update-rules` | Audit and fix existing project rules |
| `/plan-project` | Plan a new project from scratch |
| `/plan-feature` | Plan a feature for an existing codebase |
| `/issue-prd QUE-123` | Start a Linear issue through the pipeline |
| `/issue-rework QUE-123` | Rework after tester feedback |
| `/auto-pilot PROJECT-ID` | Autonomous project execution |
| `/merge-issue QUE-123` | Merge PR, update Linear |
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
- Linear API key (configured via `/quetrex-setup`)
