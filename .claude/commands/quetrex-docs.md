---
description: Display the full quetrex-base reference — pipeline, commands, agents, setup requirements, and workflow. Run at the start of any session to orient Claude or share with a new partner.
---

# Quetrex Docs

Display the complete quetrex-base system reference.

---

## The System

Quetrex Base is a Claude Code workflow system for software development teams. It provides:
- A structured agent pipeline from plan to merged PR
- Specialized agents for each stage of development
- Commands for planning, setup, secrets management, and deployment
- Cross-platform support (macOS, Linux, Windows WSL)

> **Tracker integration is project-level.** The base ships no tracker/issue commands. Per-project
> tracker wiring (fetching work items, advancing status columns) is provided by project-level setup
> (`quetrex-init`, forthcoming) that integrates a tracker such as quetrex-kanban. The base is
> intentionally tracker-agnostic.

---

## Setup (run once per machine)

```
/quetrex-setup     Configure gh auth, git identity, API keys, direnv
```

## Setup (run once per project)

```
/project-setup       GitHub Actions CI, branch protection, direnv .envrc
/create-rules        Generate .claude/CLAUDE.md with stack and verification commands
/deploy-setup        Generate a project-specific /deploy skill
```

For existing projects with an existing CLAUDE.md:
```
/update-rules      Audit and fix existing .claude/CLAUDE.md for quetrex compatibility
```

---

## The Development Pipeline

The generic agent pipeline runs a unit of work from plan to an open PR:

```
architect → developer(s) → QA → reviewer → git-workflow → (open PR, awaiting human merge)
```

- **architect** — implementation plan, file ownership map, acceptance criteria
- **developer(s)** — implementation + tests, in parallel worktrees on separate sub-branches
- **QA** — runs the verification chain and reports actual exit codes
- **reviewer** (Opus) — semantic review of the full diff: logic, security, architecture
- **git-workflow** — commits, pushes, opens a squash PR to main

The pipeline terminus is an open PR. Merge, deploy, and tracker status updates are deliberate
gates handled outside the base — merge by a human, `/deploy` for shipping, and project-level
tracker integration for status.

---

## All Commands

### Planning

| Command | What it does |
|---|---|
| `/plan-feature` | Codebase analysis + implementation plan for a feature |
| `/create-prd` | Generate a PRD from the current conversation |

### Setup

| Command | What it does |
|---|---|
| `/quetrex-setup` | One-time machine setup (gh auth, git config, keys, direnv) |
| `/project-setup` | One-time project setup (CI, branch protection, .envrc) |
| `/create-rules` | Generate project .claude/CLAUDE.md from stack templates |
| `/update-rules` | Audit and update existing project .claude/CLAUDE.md |
| `/deploy-setup` | Generate project-specific deploy skill (Fly.io, Vercel, etc.) |

### Keys and Secrets

| Command | What it does |
|---|---|
| `/secrets add KEY [--project]` | Add API key to ~/.claude/secrets.env or project .env |
| `/secrets list` | Show configured key names (never values) |
| `/secrets remove KEY [--project]` | Remove a key |

### Maintenance

| Command | What it does |
|---|---|
| `/quetrex-update` | Check for and apply updates to quetrex-base |
| `/quetrex-docs` | Display this reference |

### Utilities

| Command | What it does |
|---|---|
| `/commit` | Create a commit for current changes |
| `/prime` | Prime agent with codebase understanding |
| `/execute` | Execute an implementation plan |

---

## All Agents

| Agent | Model | Role |
|---|---|---|
| `architect` | Opus | Implementation plan, file ownership map, acceptance criteria |
| `developer` | Sonnet | Implementation + tests for one assigned workstream |
| `qa` | Sonnet | Runs verification chain, reports actual exit codes |
| `reviewer` | Opus | Semantic review of full diff — logic, security, architecture |
| `git-workflow` | Haiku | Commit, push, squash PR to main |
| `designer` | Sonnet | UI design spec (orchestrator decides when to invoke) |
| `database-architect` | Sonnet | Schema design and migrations |
| `product-manager` | Sonnet | Requirements gathering when a work item lacks detail |
| `security-reviewer` | Opus | OWASP security audit — read-only, invoked explicitly |
| `test-writer` | Sonnet | Adds test coverage to existing code (utility, not pipeline) |
| `nextjs-migrator` | Sonnet | Next.js major version upgrades |

---

## Branching Strategy

```
main
  └── feature/<short-description>          ← one per unit of work
        ├── feature/<desc>-api             ← parallel developer A
        ├── feature/<desc>-db              ← parallel developer B
        └── feature/<desc>-ui              ← parallel developer C
```

- Sub-branches merge regularly into the feature branch
- Feature branch squash-merges into main via PR
- All work on feature branches — never commit directly to main

---

## Prerequisites

| Requirement | Check | Install |
|---|---|---|
| GitHub CLI | `gh auth status` | `gh auth login` |
| direnv | `which direnv` | `brew install direnv` / `apt install direnv` |
| Node.js 18+ | `node --version` | nodejs.org |

---

## Partner Onboarding

```bash
npm install -g quetrex-base     # installs agents, skills, commands
/quetrex-setup                  # one-time machine config
git clone <repo-url>            # project already has CI and rules
```
