# Glen Barnhardt's Claude Code Stack

## Stack
- Next.js 16 (App Router, Turbopack, React 19.2)
- TypeScript strict (NO `any`)
- ShadCN UI + Tailwind CSS + Framer Motion
- TanStack Query v5 + Zustand
- Drizzle ORM (PostgreSQL) + Upstash Redis

## Quality Rules
- Zero TypeScript errors, zero warnings
- Zero lint errors, zero warnings
- Tests define contracts — fix code, not tests
- New code: >80% test coverage
- No @ts-ignore, no @ts-expect-error
- Run `npm run type-check && npm run lint` before committing
- Run `npm run test` before creating PRs

## Agent Teams
When a task touches 3+ files across layers (UI + API + DB),
use agent teams. The minimum team:
- Lead: plans, creates tasks, coordinates. NEVER writes code. Delegate mode.
- Developer: implements code per plan
- Tester: writes tests for implemented code
- Reviewer: reads all code, catches issues, approves or rejects

For the full orchestration protocol (contract-first development,
staggered spawning, file ownership, validation gates), read:
  ~/.claude/team-protocol.md

Launch agent-surveillance dashboard before every TeamCreate (interactive sessions only).

## Workflow
- All work in git worktrees with feature branches (never on main)
- PRs require human review — agents cannot merge
- Use Context7 for latest documentation
- Skills available: /nextjs-16, /drizzle-postgres, /tanstack-query,
  /zustand, /shadcn-ui, /tailwind-css, /framer-motion, /testing,
  /api-patterns, /design, /stack-integration

## For Teammates
If you are a teammate in an agent team, read this first:
- Check your assigned tasks via TaskList
- Before marking any task complete, run:
  npm run type-check && npm run lint
- If you're a Reviewer, write your verdict as a message to the lead:
  APPROVED (with summary) or REJECTED (with specific issues to fix)
