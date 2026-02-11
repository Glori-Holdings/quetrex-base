---
name: migrate-nextjs-16
description: Migrate Next.js 15 project to Next.js 16
allowed-tools: Bash, Read, Write, Edit, Glob, Grep
disable-model-invocation: true
---

# Migrate to Next.js 16

Upgrades the current Next.js 15 project to Next.js 16.

## Usage

```
/migrate-nextjs-16
/migrate-nextjs-16 --with-react-compiler
```

## Instructions

Execute ALL steps in order. Stop on any failure.

### Step 1: Pre-flight

Execute this command to verify project state:

```bash
NEXT_VERSION=$(grep '"next":' package.json | grep -oE '[0-9]+\.[0-9]+')
if [[ ! "$NEXT_VERSION" =~ ^15\. ]]; then
  echo "ERROR: Not a Next.js 15 project (found $NEXT_VERSION)"
  exit 1
fi

if [[ -n $(git status --porcelain) ]]; then
  echo "ERROR: Git has uncommitted changes. Commit or stash first."
  exit 1
fi

echo "Pre-flight passed: Next.js $NEXT_VERSION, git clean"
```

If pre-flight fails, STOP and inform the user.

### Step 2: Run Codemod

Execute the official Next.js upgrade codemod:

```bash
npx @next/codemod upgrade 16
```

This handles:
- Async API migrations (cookies, headers, params, searchParams)
- next.config.js turbopack migration
- ESLint CLI migration
- unstable_ prefix removal

### Step 3: Verify Async APIs

Search for patterns that may need manual fixes:

```bash
echo "Checking for remaining sync API usage..."
grep -rn "const.*= cookies()" --include="*.ts" --include="*.tsx" app/ 2>/dev/null || echo "✓ No sync cookies()"
grep -rn "const.*= headers()" --include="*.ts" --include="*.tsx" app/ 2>/dev/null || echo "✓ No sync headers()"
grep -rn "unstable_cache" --include="*.ts" --include="*.tsx" 2>/dev/null || echo "✓ No unstable_ imports"
```

If issues found, fix them before proceeding:

**Async params pattern:**
```typescript
// WRONG
const id = params.id

// CORRECT
const { id } = await params
```

**Async cookies pattern:**
```typescript
// WRONG
const cookieStore = cookies()

// CORRECT
const cookieStore = await cookies()
```

### Step 4: Install Dependencies

```bash
npm install
```

### Step 5: Verification

Run all checks - ALL must pass:

```bash
npm run type-check && echo "✓ Type check passed" || (echo "✗ Type check failed" && exit 1)
```

```bash
npm run build && echo "✓ Build passed" || (echo "✗ Build failed" && exit 1)
```

If any check fails, fix the issues before proceeding.

### Step 6: React Compiler (Optional)

If `$ARGUMENTS` contains `--with-react-compiler`:

```bash
npm install -D babel-plugin-react-compiler
```

Then add to next.config.ts or next.config.js:
```typescript
const nextConfig: NextConfig = {
  reactCompiler: true,
}
```

### Step 7: Report

Output this summary:

```
## Migration Complete: Next.js 15 → 16

**Changes Made:**
- ✓ Codemod applied
- ✓ Async APIs migrated
- ✓ Dependencies updated
- ✓ Build verified

**Next Steps:**
- Run `npm run dev` to test locally
- Test all routes and API endpoints
- Commit changes when satisfied

**Optional:**
- Add `reactCompiler: true` to next.config for auto-memoization
- Use `"use cache"` directive with `cacheLife()` and `cacheTag()`
```

## Rollback

If anything fails and you need to rollback:

```bash
git checkout -- .
npm install
```

## Common Issues

### TypeScript errors after migration

Check for:
1. `params` not awaited in route handlers
2. `cookies()` or `headers()` not awaited
3. Old `experimental.turbopack` config

### Build fails

1. Clear .next directory: `rm -rf .next`
2. Clear node_modules: `rm -rf node_modules && npm install`
3. Check for incompatible dependencies

### ESLint errors

Next.js 16 removed `next lint`. Use ESLint CLI directly:
```bash
npx eslint . --ext .ts,.tsx
```
