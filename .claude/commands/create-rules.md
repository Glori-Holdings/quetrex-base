---
description: Generate the project .claude/CLAUDE.md with stack, verification commands, and conventions. Choose from predefined templates (Next.js, Python, Rust, Rails, iOS, Go, Node.js) and customize. QA and developer agents read this file.
---

# Create Project Rules

Generates `.claude/CLAUDE.md` for this project. The QA agent reads the Verification section to know which commands to run. The developer agent reads Conventions for code quality rules.

Run once per project, after `/project-setup`.

---

## Step 1: Choose Your Stack

Present these options:

```
Which stack best describes this project?

1. Next.js      — TypeScript, App Router, Vitest, Biome
2. Python       — FastAPI / Django / Flask, pytest, ruff, mypy
3. Rust         — Axum / Actix / bare, cargo test, clippy
4. Ruby on Rails — Rails 7, RSpec, RuboCop
5. iOS          — Swift, SwiftUI, XCTest, SwiftLint
6. Go           — net/http / Gin / Echo, go test, golangci-lint
7. Node.js      — TypeScript, Express / Fastify, Vitest, Biome
8. Custom       — I'll ask you about your stack
```

Wait for the user's choice.

---

## Step 2: Auto-Detect Details

Scan existing files to fill in specifics before asking anything:

```bash
# Node-based projects
cat package.json 2>/dev/null

# Python projects
cat pyproject.toml 2>/dev/null
cat requirements.txt 2>/dev/null

# Rust
cat Cargo.toml 2>/dev/null

# Ruby
cat Gemfile 2>/dev/null

# Go
cat go.mod 2>/dev/null

# iOS
ls *.xcodeproj *.xcworkspace 2>/dev/null | head -3
```

Report what was detected. Use this to fill in template variables (ORM, framework variant, project name, etc.).

---

## Step 3: Customize

Ask: "Anything to adjust? (ORM, framework variant, test runner, specific conventions, additional tools)"

If no adjustments needed, proceed. Apply any changes to the template.

---

## Step 4: Write `.claude/CLAUDE.md`

Apply the matching template below. Replace all `{variables}` with detected or provided values.

---

### Template: Next.js

```markdown
# Project: {project-name}

## Stack
- Language: TypeScript (strict)
- Framework: Next.js {version} (App Router, React 19, Turbopack)
- UI: {ShadCN + Tailwind CSS / other}
- ORM: {Drizzle / Prisma} + PostgreSQL
- State: TanStack Query v5 + Zustand
- Testing: Vitest + React Testing Library
- Linting: Biome

## Verification
Run in this order — all must pass before any PR:
1. `npx biome check --write .`
2. `npm run type-check`
3. `npm run test`
4. `npm run build`

## Conventions
- No `any` types — use proper TypeScript throughout
- No `@ts-ignore` — fix the root cause
- `snake_case` for database columns, `camelCase` for TypeScript
- Server components by default — `"use client"` only when required
- API routes in `app/api/`, server actions in `app/actions/`
- Components in `components/`, hooks in `hooks/`, utilities in `lib/`

## Key Commands
- Dev server: `npm run dev`
- DB push: `npx drizzle-kit push` / `npx prisma db push`
- DB studio: `npx drizzle-kit studio` / `npx prisma studio`
- Install: `npm install`
```

---

### Template: Python

```markdown
# Project: {project-name}

## Stack
- Language: Python {version}
- Framework: {FastAPI / Django / Flask}
- ORM: {SQLAlchemy / Django ORM / Tortoise / SQLModel}
- Testing: pytest{+ pytest-asyncio if async}
- Linting: ruff + mypy
- Package manager: {uv / pip / poetry}

## Verification
Run in this order — all must pass before any PR:
1. `ruff check --fix .`
2. `mypy .`
3. `pytest`

## Conventions
- Type hints on all functions and return values — no untyped code
- Pydantic models for all request/response schemas
- `snake_case` everywhere
- Tests mirror the module structure in `tests/`
- Raise specific exceptions, not bare `Exception`

## Key Commands
- Dev server: `{uvicorn main:app --reload / python manage.py runserver}`
- Install: `{uv sync / pip install -r requirements.txt}`
- DB migrate: `{alembic upgrade head / python manage.py migrate}`
```

---

### Template: Rust

```markdown
# Project: {project-name}

## Stack
- Language: Rust ({edition} edition)
- Framework: {Axum / Actix-web / bare}
- Testing: cargo test
- Linting: clippy + rustfmt
- DB: {sqlx / Diesel / SeaORM / none}

## Verification
Run in this order — all must pass before any PR:
1. `cargo fmt --check`
2. `cargo clippy -- -D warnings`
3. `cargo test`
4. `cargo build --release`

## Conventions
- No `unwrap()` or `expect()` in production paths — use `?` or handle errors explicitly
- All public items documented with `///`
- `snake_case` for functions/variables, `PascalCase` for types/traits/enums
- Prefer `impl Trait` in function signatures over generics where possible
- Error types implement `std::error::Error`

## Key Commands
- Run: `cargo run`
- Check (fast): `cargo check`
- Watch: `cargo watch -x run`
```

---

### Template: Ruby on Rails

```markdown
# Project: {project-name}

## Stack
- Language: Ruby {version}
- Framework: Rails {version}
- Testing: RSpec + FactoryBot + Capybara
- Linting: RuboCop + StandardRB
- DB: PostgreSQL + Active Record

## Verification
Run in this order — all must pass before any PR:
1. `bundle exec rubocop --autocorrect`
2. `bundle exec rspec`

## Conventions
- Follow Rails conventions — convention over configuration
- Thin controllers, fat models (service objects for complex logic)
- `snake_case` for Ruby, Rails naming for files and classes
- Use concerns for shared behaviour across models/controllers
- Prefer scopes over class methods for queries

## Key Commands
- Dev: `bin/rails server`
- Console: `bin/rails console`
- Migrate: `bin/rails db:migrate`
- Routes: `bin/rails routes`
- Generate: `bin/rails generate ...`
```

---

### Template: iOS

```markdown
# Project: {project-name}

## Stack
- Language: Swift {version}+
- UI: SwiftUI
- Architecture: MVVM
- Testing: XCTest + Swift Testing
- Linting: SwiftLint
- Package manager: Swift Package Manager

## Verification
Run in this order — all must pass before any PR:
1. `swiftlint lint --strict`
2. `xcodebuild test -scheme {scheme-name} -destination 'platform=iOS Simulator,name=iPhone 16'`

## Conventions
- `PascalCase` for types, `camelCase` for variables and functions
- `@State` and `@StateObject` only in Views — all business logic in ViewModels
- `async`/`await` for all async operations — no completion handlers in new code
- No force unwrap (`!`) in production code — use `guard let` or `if let`
- Separate concerns: Views (UI only), ViewModels (logic), Services (data/network)

## Key Commands
- Build: `xcodebuild build -scheme {scheme-name}`
- Open project: `open {project-name}.xcodeproj`
- SPM resolve: `swift package resolve`
```

---

### Template: Go

```markdown
# Project: {project-name}

## Stack
- Language: Go {version}
- Framework: {net/http / Gin / Echo / Chi}
- Testing: go test
- Linting: golangci-lint
- DB: {pgx / GORM / sqlx / none}

## Verification
Run in this order — all must pass before any PR:
1. `golangci-lint run`
2. `go vet ./...`
3. `go test ./...`
4. `go build ./...`

## Conventions
- Always check errors — never ignore with `_`
- Package names: short, lowercase, no underscores
- Interfaces defined at the consumer (not the producer)
- `context.Context` as first argument for all I/O operations
- Table-driven tests for pure functions

## Key Commands
- Run: `go run .`
- Module tidy: `go mod tidy`
- Format: `gofmt -w .`
```

---

### Template: Node.js

```markdown
# Project: {project-name}

## Stack
- Language: TypeScript
- Runtime: Node.js {version}
- Framework: {Express / Fastify / Hono / Koa}
- Testing: Vitest
- Linting: Biome
- DB: {Drizzle / Prisma / none}

## Verification
Run in this order — all must pass before any PR:
1. `npx biome check --write .`
2. `npm run type-check`
3. `npm run test`
4. `npm run build`

## Conventions
- No `any` types — use proper TypeScript
- `async`/`await` — no raw callbacks
- `snake_case` for database columns, `camelCase` for TypeScript
- Centralised error handling middleware
- Route handlers thin — business logic in service layer

## Key Commands
- Dev: `npm run dev`
- Build: `npm run build`
- Install: `npm install`
```

---

### Template: Custom

Ask the user these questions one at a time:

1. "What language and version?"
2. "What framework or runtime (if any)?"
3. "What test runner?"
4. "What linter / formatter?"
5. "What are the exact verification commands to run before every PR?"
6. "Any key naming or structural conventions to enforce?"

Generate a CLAUDE.md in the same structure as the templates above.

---

## Step 5: Confirm

Show the generated content and ask: "Does this look right? Anything to adjust?"

Apply any corrections, then write the file.

```bash
mkdir -p .claude
git add .claude/CLAUDE.md
git commit -m "chore: add project rules for {stack}"
```

Report: "Project rules created. QA and developer agents will now read `.claude/CLAUDE.md` for stack conventions and verification commands."

---

## Notes

- The Verification section drives the QA agent — get these commands right
- The Conventions section drives the developer agent — be specific about type safety rules
- Run `/create-rules` again any time the stack changes significantly
- Partners on the same project get these rules automatically via git clone
- To disable the Glori Builder welcome message for this project, add `quetrex_welcome: false` anywhere in this file
