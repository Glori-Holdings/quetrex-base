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
/project-setup       GitHub Actions CI, branch protection, direnv .envrc
/create-rules        Generate .claude/CLAUDE.md with stack and verification commands
/map-task-columns    Map your Linear columns to the pipeline's canonical states
/deploy-setup        Generate a project-specific /deploy skill
```

For existing projects with an existing CLAUDE.md:
```
/update-rules      Audit and fix existing .claude/CLAUDE.md for quetrex compatibility
```

---

## The Development Pipeline

```
/issue-prd → architect → developer(s) → QA → reviewer → git-workflow → (stops at PR Ready)
```

The automatic pipeline runs from `queued` and **stops at `ready` (PR Ready)**. Everything after
is a deliberate human gate:

```
/merge-issue QUE-123   →  Merged     (merges the PR)
/deploy                →  Deployed   (ships it; advances merged issues)
/complete [QUE-123]    →  Complete   (after human testing; blank = all deployed in the project)
```

**Greenfield — manual:**
```
/plan-project → Linear project + issues → /issue-prd QUE-1 → … → PR Ready → /merge-issue → /deploy → /complete
```

**Greenfield — auto-pilot (walk away):**
```
/plan-project → Linear project + issues → /auto-pilot PROJECT-ID
             → works every queued issue through the pipeline → auto-merges → sets Complete → done
```
Auto-pilot is the one exception that bypasses the manual gates.

**Brownfield (existing issue):**
```
/issue-prd QUE-123 → pipeline runs → PR Ready → /merge-issue QUE-123 → /deploy → /complete QUE-123
```

**Rework (tester feedback):**
```
/issue-rework QUE-123 → rework doc + issue set to Rework → /issue-prd QUE-123 reruns the pipeline
```

---

## Linear States

The pipeline drives issues through canonical state keys. Each project maps its real Linear column
names to these keys once with `/map-task-columns` (stored in `.claude/CLAUDE.md`). Full reference:
`.claude/docs/linear-states.md`.

```
backlog ──(human approves)──> queued ──(auto)──> in_progress ──(auto)──> ready   ◀── AUTOMATION STOPS
                                          │
                                          └─(fail: 3× QA / blocker)──> needs_help ◀── waits for human

  ready ──(/merge-issue)──> merged ──(/deploy)──> deployed ──(/complete)──> complete
  rework ──(/issue-rework → /issue-prd)──> back into the pipeline
```

| Key | Meaning | Set by |
|---|---|---|
| `queued` | Approved — pipeline picks it up | human |
| `in_progress` | Pipeline building | `/issue-prd`, `/auto-pilot` |
| `needs_help` | Hit a fail point, needs a human | any stage on failure |
| `ready` | PR open, awaiting merge | `git-workflow` (terminus) |
| `merged` | PR merged | `/merge-issue` |
| `deployed` | Shipped | `/deploy` |
| `complete` | Tested & signed off | `/complete` |

Never hardcode column names — resolve through the map. Several columns often share Linear
`type: "started"`, so only exact-name matching from the map is reliable.

---

## All Commands

### Pipeline

| Command | What it does |
|---|---|
| `/issue-prd QUE-123` | Fetch Linear issue, evaluate, create feature branch, run pipeline to PR Ready |
| `/issue-rework QUE-123` | Create rework document from tester feedback, set issue to Rework |
| `/merge-issue QUE-123` | Merge the PR, move issue to Merged (gate 1) |
| `/deploy` | Ship it, advance merged issues to Deployed (gate 2) — project-specific |
| `/complete [QUE-123]` | Move issue(s) to Complete after testing (gate 3); blank = all deployed in a project |
| `/auto-pilot PROJECT-ID` | Work an entire Linear project autonomously, auto-merging — walk away mode |

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
| `/map-task-columns` | Map Linear columns to the pipeline's canonical states |
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
