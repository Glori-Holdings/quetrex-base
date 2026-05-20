---
description: Display the full quetrex-base reference — pipeline, commands, agents, setup requirements, and workflow. Run at the start of any session to orient Claude or share with a new partner.
---

# Quetrex Docs

Display the complete quetrex-base system reference.

---

## The System

Quetrex-base is a Claude Code workflow system for software development teams. It provides:
- A structured pipeline from Linear issue to merged PR
- Specialized agents for each stage of development
- Commands for planning, setup, secrets management, and deployment
- Cross-platform support (macOS, Linux, Windows WSL)

---

## Setup (run once per machine)

```
/quetrex-setup     Configure gh auth, git identity, Linear API key, direnv
```

## Setup (run once per project)

```
/project-setup     GitHub Actions CI, branch protection, direnv .envrc
/create-rules      Generate .claude/CLAUDE.md with stack and verification commands
/deploy-setup      Generate a project-specific /deploy skill
```

For existing projects with an existing CLAUDE.md:
```
/update-rules      Audit and fix existing .claude/CLAUDE.md for quetrex compatibility
```

---

## The Development Pipeline

```
/issue-prd → architect → developer(s) → QA → reviewer → git-workflow → /merge-issue
```

**Greenfield — manual:**
```
/plan-project → Linear project + issues created → /issue-prd QUE-1 (work one at a time)
```

**Greenfield — auto-pilot (walk away):**
```
/plan-project → Linear project + issues created → /auto-pilot PROJECT-ID
             → works every issue through full pipeline → auto-merges → done
```

**Brownfield (existing issue):**
```
/issue-prd QUE-123 → pipeline runs → PR created → /merge-issue QUE-123
```

**Rework (tester feedback):**
```
/issue-rework QUE-123 → rework document → pipeline reruns
```

---

## All Commands

### Pipeline

| Command | What it does |
|---|---|
| `/issue-prd QUE-123` | Fetch Linear issue, evaluate, create feature branch, start pipeline |
| `/issue-rework QUE-123` | Create rework document from tester feedback, restart pipeline |
| `/merge-issue QUE-123` | Merge PR, update Linear status to Human Review |
| `/auto-pilot PROJECT-ID` | Work entire Linear project backlog autonomously — walk away mode |

### Planning

| Command | What it does |
|---|---|
| `/plan-project` | Greenfield: interview → PRD → Linear project + all issues |
| `/plan-feature` | Brownfield: codebase analysis + implementation plan |

### Setup

| Command | What it does |
|---|---|
| `/quetrex-setup` | One-time machine setup (gh auth, git config, Linear key, direnv) |
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
| `/create-rules` | Already listed above |

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
| `product-manager` | Sonnet | Requirements gathering when issue lacks detail |
| `security-reviewer` | Opus | OWASP security audit — read-only, invoked explicitly |
| `test-writer` | Sonnet | Adds test coverage to existing code (utility, not pipeline) |
| `nextjs-migrator` | Sonnet | Next.js major version upgrades |

---

## Branching Strategy

```
main
  └── feature/QUE-123-description        ← one per issue
        ├── feature/QUE-123-api          ← parallel developer A
        ├── feature/QUE-123-db           ← parallel developer B
        └── feature/QUE-123-ui           ← parallel developer C
```

- Sub-branches merge regularly into issue branch
- Issue branch squash-merges into main via PR
- All work on feature branches — never commit directly to main

---

## Multiple Linear Workspaces

```bash
# Global default (primary workspace)
~/.claude/secrets.env → export LINEAR_API_KEY="lin_api_..."

# Project-specific override (different workspace)
project/.env → LINEAR_API_KEY=lin_api_other_workspace
```

---

## Prerequisites

| Requirement | Check | Install |
|---|---|---|
| GitHub CLI | `gh auth status` | `gh auth login` |
| Linear API key | `/secrets list` | `/quetrex-setup` |
| direnv | `which direnv` | `brew install direnv` / `apt install direnv` |
| Node.js 18+ | `node --version` | nodejs.org |

---

## Partner Onboarding

```bash
npm install -g @quetrex/base   # installs agents, skills, commands
/quetrex-setup                 # one-time machine config
git clone <repo-url>           # project already has CI and rules
```
