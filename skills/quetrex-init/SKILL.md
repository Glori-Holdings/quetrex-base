---
name: quetrex-init
description: Initialize a project with quetrex quality gates
allowed-tools: Bash, Write, AskUserQuestion
disable-model-invocation: true
---

# Quetrex Init

Configures quality enforcement for the current project.

## Usage

```
/quetrex-init
```

## Instructions

### Step 1: Detect Current Project

Check what exists:

```bash
ls package.json tsconfig.json pyproject.toml Cargo.toml go.mod 2>/dev/null
ls .claude/project.json 2>/dev/null && echo "Already initialized"
```

If `.claude/project.json` already exists, ask if the user wants to reconfigure.

### Step 2: Ask About Stack

Use AskUserQuestion:

**Question 1: "What type of project is this?"**
- Next.js / TypeScript (full quetrex stack)
- TypeScript (Node.js, no framework)
- Python
- Go
- Other / Skip quality gates

### Step 3: Ask About Checks

Based on stack selection, ask which checks to enable:

**For Next.js / TypeScript:**
- Type check (default: yes)
- Lint (default: yes)
- Tests (default: yes)
- Coverage threshold (default: 80)

**For Python:**
- Type check via mypy/pyright (default: no)
- Lint via ruff (default: yes)
- Tests via pytest (default: yes)

**For Go:**
- Vet (default: yes)
- Lint via golangci-lint (default: yes)
- Tests (default: yes)

**For Other/Skip:**
- No checks enabled

### Step 4: Create Project Config

Create `.claude/project.json`:

```bash
mkdir -p .claude
cat > .claude/project.json << 'EOF'
{
  "stack": "nextjs",
  "checks": {
    "typeCheck": true,
    "lint": true,
    "tests": true,
    "coverage": 80
  },
  "createdAt": "ISO_TIMESTAMP",
  "createdBy": "quetrex-init"
}
EOF
```

### Step 5: Override CLAUDE.md (Non-Quetrex Stacks Only)

If the project is NOT the quetrex stack (Python, Go, Other):

Create `.claude/CLAUDE.md` that overrides the global:

```markdown
# [Project Name]

## Stack
- [Language/framework for this project]

## Quality Rules
- [Relevant subset of rules for this stack]
```

If the project IS the quetrex stack: skip this step. The global
CLAUDE.md already applies.

### Step 6: Generate init.sh Bootstrap Script

Create `.issue/init.sh` for the autonomous pipeline's session bootstrap:

**For Next.js / TypeScript:**
```bash
#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

echo "=== Bootstrapping project ==="

# Install dependencies if needed
if [ ! -d "node_modules" ]; then
  echo "Installing dependencies..."
  npm install
fi

# Start dev server if not running
if ! pgrep -f "next dev" > /dev/null 2>&1; then
  echo "Starting dev server..."
  npm run dev &
  timeout 60 bash -c 'until curl -sf http://localhost:3000 > /dev/null 2>&1; do sleep 2; done' || echo "Warning: dev server did not start in 60s"
else
  echo "Dev server already running"
fi

# Smoke test
echo "Running smoke test..."
npm run type-check 2>&1 || echo "Warning: type-check had issues"

echo "=== Bootstrap complete ==="
```

**For Python:**
```bash
#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

echo "=== Bootstrapping project ==="

# Create/activate virtual environment
if [ ! -d ".venv" ]; then
  echo "Creating virtual environment..."
  python3 -m venv .venv
fi
source .venv/bin/activate

# Install dependencies
pip install -e ".[dev]" 2>/dev/null || pip install -r requirements.txt 2>/dev/null || echo "No deps file found"

# Smoke test
echo "Running smoke test..."
python -m pytest --co -q 2>&1 || echo "Warning: test collection had issues"

echo "=== Bootstrap complete ==="
```

**For Go:**
```bash
#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

echo "=== Bootstrapping project ==="

go mod download
echo "Running smoke test..."
go vet ./... 2>&1 || echo "Warning: go vet had issues"

echo "=== Bootstrap complete ==="
```

After writing the file:
```bash
chmod +x .issue/init.sh
```

### Step 7: Report

```
## Project Initialized

**Stack:** [selected stack]
**Config:** .claude/project.json
**Bootstrap:** .issue/init.sh
**Checks enabled:**
- Type check: yes/no
- Lint: yes/no
- Tests: yes/no

The quality gate hook will now enforce these checks when
you exit a Claude session after modifying code.

The bootstrap script (.issue/init.sh) will be used by the
autonomous pipeline to initialize the dev environment at
the start of each session.
```
