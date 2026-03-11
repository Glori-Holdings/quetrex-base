# Preferences
- Use Context7 MCP for latest library documentation — never guess at APIs
- Prefer editing existing files over creating new ones
- Run type-check and lint after making changes
- Use agent teams when work touches 3+ files across layers
- After every correction, update CLAUDE.md so the mistake isn't repeated

# Stack (default — project CLAUDE.md overrides)
- Next.js 16 (App Router, Turbopack, React 19)
- TypeScript strict (no `any`, no `@ts-ignore`)
- ShadCN UI + Tailwind CSS + Framer Motion
- TanStack Query v5 + Zustand
- Drizzle ORM (PostgreSQL) + Upstash Redis
- Biome for linting and formatting

# Verification
After changes, run in this order:
1. `npx biome check --write .` — format and lint
2. `npm run type-check` — fix type errors
3. `npm run test` — fix failing tests
4. `npm run build` — confirm it builds

# Workflow
- All work in git worktrees with feature branches (never on main)
- PRs require human review — agents cannot merge
- Tests are part of every feature, not an afterthought

# For Teammates
If you are a teammate in an agent team:
- Check your assigned tasks via TaskList
- Read the project's CLAUDE.md for codebase context
- Before marking tasks complete, run verification steps above
