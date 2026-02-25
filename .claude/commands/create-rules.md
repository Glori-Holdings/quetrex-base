---
description: Create global rules (CLAUDE.md) from codebase analysis
---

# Create Global Rules

Generate a CLAUDE.md file by analyzing the codebase and extracting patterns. Also sets up CI, mutation testing, and dead-code detection tooling.

---

## Objective

Create project-specific global rules that give Claude context about:
- What this project is
- Technologies used
- How the code is organized
- Patterns and conventions to follow
- How to build, test, and validate

---

## Phase 1: DISCOVER

### Identify Project Type

First, determine what kind of project this is:

| Type | Indicators |
|------|------------|
| Web App (Full-stack) | Separate client/server dirs, API routes |
| Web App (Frontend) | React/Vue/Svelte, no server code |
| API/Backend | Express/Fastify/etc, no frontend |
| Library/Package | `main`/`exports` in package.json, publishable |
| CLI Tool | `bin` in package.json, command-line interface |
| Monorepo | Multiple packages, workspaces config |
| Script/Automation | Standalone scripts, task-focused |

### Analyze Configuration

Look at root configuration files:

```
package.json       → dependencies, scripts, type
tsconfig.json      → TypeScript settings
vite.config.*      → Build tool
*.config.js/ts     → Various tool configs
```

### Map Directory Structure

Explore the codebase to understand organization:
- Where does source code live?
- Where are tests?
- Any shared code?
- Configuration locations?

---

## Phase 2: ANALYZE

### Extract Tech Stack

From package.json and config files, identify:
- Runtime/Language (Node, Bun, Deno, browser)
- Framework(s)
- Database (if any)
- Testing tools
- Build tools
- Linting/formatting

### Identify Patterns

Study existing code for:
- **Naming**: How are files, functions, classes named?
- **Structure**: How is code organized within files?
- **Errors**: How are errors created and handled?
- **Types**: How are types/interfaces defined?
- **Tests**: How are tests structured?

### Find Key Files

Identify files that are important to understand:
- Entry points
- Configuration
- Core business logic
- Shared utilities
- Type definitions

---

## Phase 3: GENERATE

### Create CLAUDE.md

Use the template at `.claude/CLAUDE-template.md` as a starting point.

**Output path**: `CLAUDE.md` (project root)

**Adapt to the project:**
- Remove sections that don't apply
- Add sections specific to this project type
- Keep it concise - focus on what's useful

**Key sections to include:**

1. **Project Overview** - What is this and what does it do?
2. **Tech Stack** - What technologies are used?
3. **Commands** - How to dev, build, test, lint?
4. **Structure** - How is the code organized?
5. **Patterns** - What conventions should be followed?
6. **Key Files** - What files are important to know?

**Optional sections (add if relevant):**
- Architecture (for complex apps)
- API endpoints (for backends)
- Component patterns (for frontends)
- Database patterns (if using a DB)
- On-demand context references

---

## Phase 4: SETUP TOOLING

### GitHub Actions Quality Gate

Check if `.github/workflows/quality-gate.yml` exists. If it does NOT exist, create it:

**Output path**: `.github/workflows/quality-gate.yml`

```yaml
name: Quality Gate
on:
  pull_request:
    branches: [main]

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  quality:
    name: Lint & Type Check
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: 'npm'
      - run: npm ci
      - run: npm run type-check
      - run: npm run lint
      - run: npx knip

  test:
    name: Unit & Integration Tests
    runs-on: ubuntu-latest
    needs: quality
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: 'npm'
      - run: npm ci
      - run: npm run test -- --coverage

  mutation:
    name: Mutation Testing
    runs-on: ubuntu-latest
    needs: quality
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: 'npm'
      - run: npm ci
      - run: npx stryker run --reporters=clear-text
    continue-on-error: true

  e2e:
    name: E2E Tests
    runs-on: ubuntu-latest
    needs: quality
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: 'npm'
      - run: npm ci
      - run: npx playwright install --with-deps chromium
      - run: npm run build
      - run: npx playwright test
      - uses: actions/upload-artifact@v4
        if: failure()
        with:
          name: playwright-report
          path: playwright-report/
          retention-days: 7

  security:
    name: Security Scan
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: returntocorp/semgrep-action@v1
        with:
          config: p/typescript

  build:
    name: Production Build
    runs-on: ubuntu-latest
    needs: [test, e2e, security]
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: 'npm'
      - run: npm ci
      - run: npm run build
```

If `.github/workflows/quality-gate.yml` already exists, skip this step and note it in the output.

### Stryker Mutation Testing Config

Check if `stryker.config.mjs` exists at the project root. If it does NOT exist, create it:

**Output path**: `stryker.config.mjs`

```javascript
/** @type {import('@stryker-mutator/api/core').PartialStrykerOptions} */
export default {
  mutate: ['src/**/*.ts', '!src/**/*.test.ts', '!src/**/*.spec.ts'],
  testRunner: 'vitest',
  reporters: ['clear-text', 'html'],
  checkers: ['typescript'],
  tsconfigFile: 'tsconfig.json',
  vitest: {
    configFile: 'vitest.config.ts',
  },
  thresholds: {
    high: 80,
    low: 60,
    break: 50,
  },
};
```

If `stryker.config.mjs` already exists, skip and note it.

### Knip Dead-Code Detection Config

Check if `knip.json` exists at the project root. If it does NOT exist, create it:

**Output path**: `knip.json`

```json
{
  "$schema": "https://unpkg.com/knip@latest/schema.json",
  "entry": ["src/app/**/*.{ts,tsx}", "src/app/**/route.ts"],
  "project": ["src/**/*.{ts,tsx}"],
  "ignore": ["**/*.test.ts", "**/*.spec.ts"],
  "ignoreDependencies": ["@types/*"]
}
```

Adapt the `entry` and `project` globs to match the actual source structure if it differs from the Next.js App Router layout. If `knip.json` already exists, skip and note it.

---

## Phase 5: OUTPUT

```markdown
## Global Rules Created

**File**: `CLAUDE.md`

### Project Type

{Detected project type}

### Tech Stack Summary

{Key technologies detected}

### Structure

{Brief structure overview}

### Tooling Created

- CLAUDE.md: {created / already existed}
- .github/workflows/quality-gate.yml: {created / already existed}
- stryker.config.mjs: {created / already existed}
- knip.json: {created / already existed}

### Next Steps

1. Review the generated `CLAUDE.md`
2. Add any project-specific notes
3. Remove any sections that don't apply
4. Run `npx knip` to check for unused exports and dependencies
5. Run `npx stryker run` to measure mutation test coverage
6. Push a PR to verify the GitHub Actions quality gate runs
7. Optionally create reference docs in `.agents/reference/`
```

---

## Tips

- Keep CLAUDE.md focused and scannable
- Don't duplicate information that's in other docs (link instead)
- Focus on patterns and conventions, not exhaustive documentation
- Update it as the project evolves
- The GitHub Actions workflow assumes `npm run type-check` and `npm run lint` exist — add these scripts to package.json if they are missing
