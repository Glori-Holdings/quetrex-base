---
name: nextjs-16
description: Next.js 16 App Router patterns and best practices
context: fork
---

# Next.js 16 Patterns

Reference for Next.js 16 with App Router, Turbopack, React Compiler, and React 19.2.

## What's New in 16

| Feature | Status | Notes |
|---------|--------|-------|
| Turbopack | Default | Used for `next dev` and `next build` |
| React Compiler | Stable | Auto-memoizes components |
| cacheLife/cacheTag | Stable | No `unstable_` prefix |
| "use cache" directive | Stable | Server-side caching |
| View Transitions | Experimental | React 19.2 feature |
| React 19.2 | Included | useEffectEvent, Activity |

## React Compiler

Automatically memoizes components - no manual `useMemo`/`useCallback` needed.

```typescript
// next.config.ts
import type { NextConfig } from 'next'

const nextConfig: NextConfig = {
  reactCompiler: true,  // Stable in 16
}

export default nextConfig
```

**Note:** Requires `npm install -D babel-plugin-react-compiler`. Build times slightly higher.

## Turbopack

Default for both dev and build in Next.js 16. File system caching stable in 16.1.

No configuration needed - just works.

## Cache APIs (Stable)

### "use cache" Directive

```typescript
"use cache"

import { cacheLife, cacheTag } from 'next/cache'

export async function getProducts() {
  "use cache"
  cacheLife('hours')
  cacheTag('products')

  return await db.query('SELECT * FROM products')
}
```

### Cache Profiles

| Profile | Stale | Revalidate | Expire |
|---------|-------|------------|--------|
| seconds | 30s | 1s | 1m |
| minutes | 5m | 1m | 1h |
| hours | 5m | 1h | 1d |
| days | 5m | 1d | 1w |
| weeks | 5m | 1w | 30d |
| max | 5m | 30d | never |

### Custom Cache Configuration

```typescript
export async function getUserData(userId: string) {
  "use cache"
  cacheLife({
    stale: 60,       // 1 minute
    revalidate: 300, // 5 minutes
    expire: 3600     // 1 hour
  })
  cacheTag('user', `user-${userId}`)

  return await fetch(`/api/users/${userId}`)
}
```

## File Conventions

| File | Purpose |
|------|---------|
| `page.tsx` | Route page component |
| `layout.tsx` | Shared layout wrapper |
| `loading.tsx` | Loading UI (Suspense) |
| `error.tsx` | Error boundary |
| `not-found.tsx` | 404 page |
| `route.ts` | API route handler |

## Server vs Client Components

**Default:** Server Components (no directive needed)

**Client Component:** Add `"use client"` at top

```typescript
// Server Component (default)
export default async function Page() {
  const data = await fetch('https://api.example.com/data')
  return <div>{data}</div>
}

// Client Component
"use client"
export default function Button() {
  const [count, setCount] = useState(0)
  return <button onClick={() => setCount(c => c + 1)}>{count}</button>
}
```

## CRITICAL: Route Params (Since Next.js 15)

**MUST await params in route handlers:**

```typescript
// CORRECT - Await params
export async function GET(
  request: Request,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params
  // ...
}
```

## API Route Patterns

```typescript
// app/api/users/route.ts
import { NextRequest, NextResponse } from 'next/server'

export async function GET(request: NextRequest) {
  const searchParams = request.nextUrl.searchParams
  const query = searchParams.get('q')

  return NextResponse.json({ data: [] })
}

export async function POST(request: NextRequest) {
  const body = await request.json()

  return NextResponse.json({ success: true }, { status: 201 })
}
```

## View Transitions (Experimental)

```typescript
// next.config.js
const nextConfig = {
  experimental: {
    viewTransition: true,
  },
}

// Component
import { ViewTransition } from 'react'

function Page() {
  return (
    <ViewTransition>
      <AnimatedContent />
    </ViewTransition>
  )
}
```

## React 19.2 Features

- **View Transitions**: Animate elements during navigation/transitions
- **useEffectEvent**: Extract non-reactive logic from Effects
- **Activity**: Hide UI with `display: none` while maintaining state

## Metadata

```typescript
// Static
export const metadata = {
  title: 'Page Title',
  description: 'Page description',
}

// Dynamic
export async function generateMetadata({ params }) {
  const { id } = await params
  return { title: `User ${id}` }
}
```

## Error Handling

```typescript
// app/error.tsx
"use client"

export default function Error({
  error,
  reset,
}: {
  error: Error
  reset: () => void
}) {
  return (
    <div>
      <h2>Something went wrong!</h2>
      <button onClick={() => reset()}>Try again</button>
    </div>
  )
}
```

## Middleware

```typescript
// middleware.ts (root level)
import { NextResponse } from 'next/server'
import type { NextRequest } from 'next/server'

export function middleware(request: NextRequest) {
  return NextResponse.next()
}

export const config = {
  matcher: '/dashboard/:path*',
}
```

## Integration with TanStack Query

### Server-Side Prefetch

```tsx
// app/users/page.tsx
import { dehydrate, HydrationBoundary, QueryClient } from '@tanstack/react-query'
import { UserList } from '@/components/UserList'

export default async function UsersPage() {
  const queryClient = new QueryClient()

  // Prefetch data on server
  await queryClient.prefetchQuery({
    queryKey: ['users'],
    queryFn: getUsers, // Can use "use cache" internally
  })

  return (
    <HydrationBoundary state={dehydrate(queryClient)}>
      <UserList />
    </HydrationBoundary>
  )
}
```

### Combining "use cache" with TanStack Query

```tsx
// lib/queries/users.ts
export async function getUsers() {
  "use cache"
  cacheLife('minutes')
  cacheTag('users')

  return db.query.users.findMany()
}

// Client component - instant hydration
"use client"
export function UserList() {
  const { data: users } = useQuery({
    queryKey: ['users'],
    queryFn: () => fetch('/api/users').then(r => r.json()),
    staleTime: 0, // Defer to server cache
  })

  return <ul>{users?.map(u => <li key={u.id}>{u.name}</li>)}</ul>
}
```

### Cache Invalidation

```tsx
// When mutating data, invalidate all layers
import { revalidateTag } from 'next/cache'

// In API route
export async function POST(request: Request) {
  const data = await request.json()
  await db.insert(users).values(data)

  // Invalidate Next.js cache
  revalidateTag('users')

  return Response.json({ success: true })
}

// Client-side invalidation happens via TanStack Query
const mutation = useMutation({
  mutationFn: createUser,
  onSuccess: () => {
    queryClient.invalidateQueries({ queryKey: ['users'] })
  },
})
```

## Integration with Upstash Redis

### Multi-Layer Caching

```tsx
// lib/queries/analytics.ts
import { redis } from '@/lib/redis'

export async function getAnalytics(orgId: string) {
  "use cache"
  cacheLife('hours')
  cacheTag('analytics', `analytics-${orgId}`)

  // Check Redis for expensive computed value
  const cached = await redis.get<Analytics>(`analytics:${orgId}`)
  if (cached) return cached

  // Compute and store in Redis
  const analytics = await computeExpensiveAnalytics(orgId)
  await redis.set(`analytics:${orgId}`, analytics, { ex: 3600 })

  return analytics
}
```

### Rate Limiting in Middleware

```tsx
// middleware.ts
import { NextRequest, NextResponse } from 'next/server'
import { ratelimit } from '@/lib/rate-limit'

export async function middleware(request: NextRequest) {
  if (request.nextUrl.pathname.startsWith('/api/')) {
    const ip = request.headers.get('x-forwarded-for') ?? 'anonymous'
    const { success } = await ratelimit.limit(ip)

    if (!success) {
      return NextResponse.json({ error: 'Rate limit exceeded' }, { status: 429 })
    }
  }

  return NextResponse.next()
}
```
