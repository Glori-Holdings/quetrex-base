# Quetrex Base

Claude Code configuration system for Glen Barnhardt's development environment.

## What This Is

The complete configuration that governs how Claude Code operates: quality rules, agent definitions, hook scripts, team orchestration protocol, and autonomous pipeline support.

## Structure

```
├── CLAUDE.md                 # Global config (stack, rules summary, workflow)
├── HARD-RULES.md             # Non-negotiable rules (single source of truth)
├── team-protocol.md          # Multi-agent orchestration protocol
├── pipeline-protocol.md      # Shared session continuity for autonomous pipeline
├── settings.json             # Claude Code settings (hooks, permissions, env)
├── statusline-command.sh     # Status bar rendering script
├── agents/                   # Custom agent definitions (10 agents)
│   ├── architect.md          # Strategic analysis and planning
│   ├── database-architect.md # Schema design and migrations
│   ├── designer.md           # Visual design systems
│   ├── developer.md          # Code implementation
│   ├── git-workflow.md       # Git operations and PRs
│   ├── nextjs-migrator.md    # Next.js version upgrades
│   ├── product-manager.md    # Requirements gathering
│   ├── qa.md                 # Quality assurance gate
│   ├── reviewer.md           # Semantic code review
│   └── test-writer.md        # Test implementation
├── hooks/                    # Shell scripts enforcing rules
│   ├── config-guard.sh       # Blocks config file edits
│   ├── enforce-branch.sh     # Blocks commits on main
│   ├── require-approval.sh   # Blocks force-push to main
│   ├── test-guard.sh         # Blocks test file modifications
│   └── track-modifications.sh # Edit tracking and loop detection
├── commands/                 # Slash commands
│   └── create-issue.md       # /create-issue workflow (legacy tmux version)
└── skills/                   # Skill definitions (23 skills)
    ├── agent-surveillance/   # Agent monitoring dashboard
    ├── api-patterns/         # API route patterns
    ├── build-feature/        # Feature implementation workflow
    ├── close-issue/          # Issue closing and PR workflow
    ├── create-issue/         # Issue creation (canonical version)
    ├── define-architecture/  # Architecture planning
    ├── design/               # Visual design systems
    ├── drizzle-postgres/     # Drizzle ORM patterns
    ├── framer-motion/        # Animation patterns
    ├── migrate-nextjs-16/    # Next.js migration guide
    ├── nextjs-16/            # Next.js 16 patterns
    ├── open-projects/        # Project listing
    ├── quetrex-init/         # Pipeline initialization
    ├── reactive-frontend/    # SSE + Zustand + TanStack Query
    ├── shadcn-ui/            # ShadCN UI patterns
    ├── stack-integration/    # Full stack integration
    ├── tab-control/          # Tab management
    ├── tailwind-css/         # Tailwind CSS patterns
    ├── tanstack-query/       # TanStack Query v5 patterns
    ├── testing/              # Test writing patterns
    ├── typescript-strict/    # TypeScript strict patterns
    ├── upstash-redis/        # Upstash Redis patterns
    └── zustand/              # Zustand 5.x patterns
```

## Installation

Copy files to `~/.claude/`:

```bash
cp CLAUDE.md HARD-RULES.md team-protocol.md pipeline-protocol.md settings.json statusline-command.sh ~/.claude/
cp agents/*.md ~/.claude/agents/
cp hooks/*.sh ~/.claude/hooks/
cp commands/*.md ~/.claude/commands/
cp -r skills/ ~/.claude/skills/
```

## Stack

- Next.js 16 (App Router, Turbopack, React 19.2)
- TypeScript strict (NO `any`)
- ShadCN UI + Tailwind CSS + Framer Motion
- TanStack Query v5 + Zustand
- Drizzle ORM (PostgreSQL) + Upstash Redis
