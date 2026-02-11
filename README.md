# Quetrex Base

Claude Code configuration system for Glen Barnhardt's development environment.

## What This Is

The complete configuration that governs how Claude Code operates: quality rules, agent definitions, hook scripts, team orchestration protocol, skills, and autonomous pipeline support.

This is the **single source of truth** for `~/.claude/`. All changes should be made here and synced.

## Structure

```
├── CLAUDE.md                 # Global config (stack, rules summary, workflow)
├── HARD-RULES.md             # Non-negotiable rules (single source of truth)
├── team-protocol.md          # Multi-agent orchestration protocol
├── pipeline-protocol.md      # Shared session continuity for autonomous pipeline
├── settings.json             # Claude Code settings (hooks, permissions, env)
├── statusline-command.sh     # Status bar rendering script
├── sync-to-dotclaude.sh      # Sync script: quetrex-base → ~/.claude/
├── agents/                   # Custom agent definitions (9 agents)
│   ├── architect.md
│   ├── database-architect.md
│   ├── designer.md
│   ├── developer.md
│   ├── git-workflow.md
│   ├── nextjs-migrator.md
│   ├── product-manager.md
│   ├── qa.md
│   └── test-writer.md
├── hooks/                    # Shell scripts enforcing rules
│   ├── config-guard.sh
│   ├── enforce-branch.sh
│   ├── require-approval.sh
│   ├── test-guard.sh
│   └── track-modifications.sh
├── commands/                 # Slash commands
│   ├── add-project.md
│   └── create-issue.md
├── skills/                   # Claude Code skills (23 skills)
│   ├── agent-surveillance/   # Launch agent team monitoring dashboard
│   ├── api-patterns/         # Next.js 16 route handler patterns
│   ├── build-feature/        # Orchestrate agent team for feature builds
│   ├── close-issue/          # Git workflow: commit, PR, merge, cleanup
│   ├── create-issue/         # Create git worktree for new work
│   ├── define-architecture/  # Generate architecture docs with Mermaid
│   ├── design/               # UI design thinking patterns
│   ├── drizzle-postgres/     # Drizzle ORM patterns
│   ├── framer-motion/        # Animation patterns
│   ├── migrate-nextjs-16/    # Next.js 15 → 16 migration
│   ├── nextjs-16/            # App Router patterns
│   ├── open-projects/        # Reconnect tmux sessions
│   ├── quetrex-init/         # Initialize project with quality gates
│   ├── reactive-frontend/    # SSE, Zustand, TanStack Query patterns
│   ├── shadcn-ui/            # ShadCN component patterns
│   ├── stack-integration/    # Cross-technology integration
│   ├── tab-control/          # WezTerm tab configuration
│   ├── tailwind-css/         # Utility-first CSS patterns
│   ├── tanstack-query/       # Server state management
│   ├── testing/              # Vitest, RTL, Playwright patterns
│   ├── typescript-strict/    # Strict mode patterns
│   ├── upstash-redis/        # Redis caching patterns
│   └── zustand/              # State management patterns
├── docs/                     # Foundation and workflow documentation
│   ├── foundation-status-report.md
│   ├── iterm2-tmux-workflow.md
│   └── quetrex-foundation-plan.md
└── prompts/                  # Reusable prompts
    ├── knowledge-consolidation.md
    ├── learning-extraction.md
    └── qa-failure-analysis.md
```

## Installation

Run the sync script to deploy to `~/.claude/`:

```bash
./sync-to-dotclaude.sh
```

Or manually:

```bash
cp CLAUDE.md HARD-RULES.md team-protocol.md pipeline-protocol.md settings.json statusline-command.sh ~/.claude/
cp agents/*.md ~/.claude/agents/
cp hooks/*.sh ~/.claude/hooks/
cp commands/*.md ~/.claude/commands/
cp -R skills/* ~/.claude/skills/
cp docs/*.md ~/.claude/docs/
cp prompts/*.md ~/.claude/prompts/
```

## Stack

- Next.js 16 (App Router, Turbopack, React 19.2)
- TypeScript strict (NO `any`)
- ShadCN UI + Tailwind CSS + Framer Motion
- TanStack Query v5 + Zustand
- Drizzle ORM (PostgreSQL) + Upstash Redis
