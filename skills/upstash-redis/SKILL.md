---
name: upstash-redis
description: Upstash Redis patterns for caching, rate limiting, and session storage
context: fork
---

# Upstash Redis Patterns

Reference for Upstash Redis in Next.js applications.

## Setup

```bash
npm install @upstash/redis
```

```tsx
// lib/redis.ts
import { Redis } from '@upstash/redis'

export const redis = new Redis({
  url: process.env.UPSTASH_REDIS_REST_URL!,
  token: process.env.UPSTASH_REDIS_REST_TOKEN!,
})
```

## Basic Operations

```tsx
import { redis } from '@/lib/redis'

// Set value
await redis.set('key', 'value')

// Set with expiration (seconds)
await redis.set('key', 'value', { ex: 3600 }) // 1 hour

// Get value
const value = await redis.get<string>('key')

// Delete
await redis.del('key')

// Check existence
const exists = await redis.exists('key')

// Increment
await redis.incr('counter')
await redis.incrby('counter', 5)

// Set expiration on existing key
await redis.expire('key', 3600)

// Get TTL
const ttl = await redis.ttl('key')
```

## JSON Operations

```tsx
interface User {
  id: string
  name: string
  email: string
}

// Store JSON (automatically serialized)
await redis.set('user:123', { id: '123', name: 'John', email: 'john@example.com' })

// Get JSON (automatically deserialized)
const user = await redis.get<User>('user:123')
```

## Rate Limiting

```tsx
// lib/rate-limit.ts
import { redis } from '@/lib/redis'
import { Ratelimit } from '@upstash/ratelimit'

// Create a rate limiter
export const ratelimit = new Ratelimit({
  redis,
  limiter: Ratelimit.slidingWindow(10, '10 s'), // 10 requests per 10 seconds
  analytics: true,
})

// Alternative limiters
// Ratelimit.fixedWindow(10, '1 m')    // 10 per minute, resets at minute boundary
// Ratelimit.tokenBucket(10, '1 m', 5) // 10 tokens per minute, 5 max burst
```

### Rate Limit in API Route

```tsx
// app/api/protected/route.ts
import { NextRequest, NextResponse } from 'next/server'
import { ratelimit } from '@/lib/rate-limit'

export async function POST(request: NextRequest) {
  // Get identifier (IP or user ID)
  const ip = request.headers.get('x-forwarded-for') ?? 'anonymous'

  // Check rate limit
  const { success, limit, reset, remaining } = await ratelimit.limit(ip)

  if (!success) {
    return NextResponse.json(
      { error: 'Too many requests' },
      {
        status: 429,
        headers: {
          'X-RateLimit-Limit': limit.toString(),
          'X-RateLimit-Remaining': remaining.toString(),
          'X-RateLimit-Reset': reset.toString(),
        },
      }
    )
  }

  // Process request
  return NextResponse.json({ success: true })
}
```

### Rate Limit with User ID

```tsx
import { getServerSession } from 'next-auth'
import { ratelimit } from '@/lib/rate-limit'

export async function POST(request: NextRequest) {
  const session = await getServerSession()

  // Use user ID for authenticated users, IP for anonymous
  const identifier = session?.user?.id ?? request.headers.get('x-forwarded-for') ?? 'anonymous'

  const { success, remaining } = await ratelimit.limit(identifier)

  if (!success) {
    return NextResponse.json({ error: 'Rate limit exceeded' }, { status: 429 })
  }

  // Continue...
}
```

## Caching Patterns

### Simple Cache

```tsx
// lib/cache.ts
import { redis } from '@/lib/redis'

export async function getOrSet<T>(
  key: string,
  fetchFn: () => Promise<T>,
  ttl: number = 3600
): Promise<T> {
  // Try cache first
  const cached = await redis.get<T>(key)
  if (cached !== null) {
    return cached
  }

  // Fetch and cache
  const data = await fetchFn()
  await redis.set(key, data, { ex: ttl })

  return data
}

// Usage
const users = await getOrSet(
  'users:all',
  () => db.query.users.findMany(),
  300 // 5 minutes
)
```

### Cache with Stale-While-Revalidate

```tsx
interface CacheEntry<T> {
  data: T
  timestamp: number
}

export async function getWithSWR<T>(
  key: string,
  fetchFn: () => Promise<T>,
  maxAge: number = 60, // Fresh for 60 seconds
  staleWhileRevalidate: number = 300 // Serve stale for 5 minutes while revalidating
): Promise<T> {
  const cached = await redis.get<CacheEntry<T>>(key)
  const now = Date.now()

  if (cached) {
    const age = (now - cached.timestamp) / 1000

    // Fresh - return immediately
    if (age < maxAge) {
      return cached.data
    }

    // Stale but within SWR window - return stale and revalidate in background
    if (age < staleWhileRevalidate) {
      // Fire and forget revalidation
      fetchFn().then((data) => {
        redis.set(key, { data, timestamp: Date.now() }, { ex: staleWhileRevalidate })
      })
      return cached.data
    }
  }

  // Miss or too stale - fetch fresh
  const data = await fetchFn()
  await redis.set(key, { data, timestamp: now }, { ex: staleWhileRevalidate })
  return data
}
```

### Cache Invalidation

```tsx
// Invalidate single key
await redis.del('users:123')

// Invalidate by pattern (use SCAN for large datasets)
async function invalidatePattern(pattern: string) {
  let cursor = 0
  do {
    const [newCursor, keys] = await redis.scan(cursor, { match: pattern, count: 100 })
    cursor = newCursor
    if (keys.length > 0) {
      await redis.del(...keys)
    }
  } while (cursor !== 0)
}

// Usage
await invalidatePattern('users:*')
```

## Session Storage

```tsx
// lib/session.ts
import { redis } from '@/lib/redis'
import { nanoid } from 'nanoid'

interface Session {
  userId: string
  createdAt: number
  data: Record<string, unknown>
}

const SESSION_TTL = 60 * 60 * 24 * 7 // 7 days

export async function createSession(userId: string): Promise<string> {
  const sessionId = nanoid()
  const session: Session = {
    userId,
    createdAt: Date.now(),
    data: {},
  }

  await redis.set(`session:${sessionId}`, session, { ex: SESSION_TTL })
  return sessionId
}

export async function getSession(sessionId: string): Promise<Session | null> {
  return redis.get<Session>(`session:${sessionId}`)
}

export async function updateSession(
  sessionId: string,
  data: Partial<Session['data']>
): Promise<void> {
  const session = await getSession(sessionId)
  if (!session) return

  session.data = { ...session.data, ...data }
  await redis.set(`session:${sessionId}`, session, { ex: SESSION_TTL })
}

export async function deleteSession(sessionId: string): Promise<void> {
  await redis.del(`session:${sessionId}`)
}
```

## Lists and Sets

```tsx
// Lists (ordered, duplicates allowed)
await redis.lpush('queue', 'item1')          // Add to left
await redis.rpush('queue', 'item2')          // Add to right
const item = await redis.lpop('queue')       // Remove from left
const items = await redis.lrange('queue', 0, -1)  // Get all

// Sets (unordered, unique)
await redis.sadd('tags', 'tag1', 'tag2')
await redis.srem('tags', 'tag1')
const tags = await redis.smembers('tags')
const isMember = await redis.sismember('tags', 'tag1')

// Sorted Sets (ordered by score)
await redis.zadd('leaderboard', { score: 100, member: 'user1' })
await redis.zadd('leaderboard', { score: 150, member: 'user2' })
const topPlayers = await redis.zrange('leaderboard', 0, 9, { rev: true })
```

## Hash Operations

```tsx
// Hash - object-like structure
await redis.hset('user:123', {
  name: 'John',
  email: 'john@example.com',
  role: 'admin',
})

const name = await redis.hget('user:123', 'name')
const user = await redis.hgetall('user:123')
await redis.hincrby('user:123', 'loginCount', 1)
```

## Pipeline Operations

```tsx
// Execute multiple commands in single round trip
const pipeline = redis.pipeline()
pipeline.incr('pageviews')
pipeline.set('last-visit', Date.now())
pipeline.get('user-count')

const results = await pipeline.exec()
// results = [1, 'OK', 42]
```

## Edge Runtime Compatibility

Upstash Redis works in Edge Runtime (Vercel Edge Functions, Cloudflare Workers):

```tsx
// app/api/edge/route.ts
import { NextRequest, NextResponse } from 'next/server'
import { redis } from '@/lib/redis'

export const runtime = 'edge'

export async function GET(request: NextRequest) {
  const count = await redis.incr('edge-visits')
  return NextResponse.json({ visits: count })
}
```

## Integration with Next.js 16 Cache

### Complementary Caching Strategy

```
Next.js "use cache"    → Request-level, single instance
Upstash Redis          → Shared across instances, persistent
```

### When to Use Which

| Use Case | Technology | Reason |
|----------|------------|--------|
| Page-level caching | Next.js "use cache" | Built-in, automatic |
| Request deduplication | Next.js "use cache" | Same request = 1 execution |
| Rate limiting | Upstash Redis | Needs shared state |
| Session storage | Upstash Redis | Persists across deploys |
| Expensive computations | Upstash Redis | Share across instances |
| Real-time counters | Upstash Redis | Needs atomicity |

### Multi-Layer Cache Pattern

```typescript
import { redis } from '@/lib/redis'
import { db } from '@/lib/db'
import { cacheLife, cacheTag } from 'next/cache'
import { revalidateTag } from 'next/cache'

// Layer 1: Next.js cache (request-level)
// Layer 2: Redis (shared across instances)
// Layer 3: Database (source of truth)

export async function getAnalytics(orgId: string) {
  "use cache"
  cacheLife('minutes')
  cacheTag('analytics', `analytics-${orgId}`)

  // Check Redis (shared cache)
  const cached = await redis.get<Analytics>(`analytics:${orgId}`)
  if (cached) return cached

  // Expensive database aggregation
  const analytics = await db.execute(sql`
    SELECT ... complex aggregation ...
  `)

  // Store in Redis for other instances
  await redis.set(`analytics:${orgId}`, analytics, { ex: 300 })

  return analytics
}

// Invalidation must hit all layers
export async function invalidateAnalytics(orgId: string) {
  await redis.del(`analytics:${orgId}`)
  revalidateTag(`analytics-${orgId}`)
}
```

### Rate Limiting + Next.js API Routes

```typescript
// middleware.ts or API route
import { NextRequest, NextResponse } from 'next/server'
import { ratelimit } from '@/lib/rate-limit'

export async function middleware(request: NextRequest) {
  // Skip rate limiting for static assets
  if (request.nextUrl.pathname.startsWith('/_next')) {
    return NextResponse.next()
  }

  const ip = request.headers.get('x-forwarded-for') ?? 'anonymous'
  const { success, limit, remaining, reset } = await ratelimit.limit(ip)

  if (!success) {
    return NextResponse.json(
      { error: 'Rate limit exceeded' },
      {
        status: 429,
        headers: {
          'X-RateLimit-Limit': limit.toString(),
          'X-RateLimit-Remaining': remaining.toString(),
          'X-RateLimit-Reset': reset.toString(),
          'Retry-After': Math.ceil((reset - Date.now()) / 1000).toString(),
        },
      }
    )
  }

  return NextResponse.next()
}

export const config = {
  matcher: '/api/:path*',
}
```

## Best Practices

1. **Use typed responses**: `redis.get<User>('key')` for type safety
2. **Set TTL on all keys**: Prevent unbounded memory growth
3. **Use pipelines**: Batch operations for better performance
4. **Key naming convention**: Use colons for hierarchy (`user:123:settings`)
5. **Cache invalidation strategy**: Plan how and when to invalidate
6. **Rate limit by user when possible**: More accurate than IP-based
7. **Monitor with Upstash console**: Watch for hot keys and memory usage
8. **Don't duplicate Next.js cache**: Use Redis for shared state, not request caching
9. **Invalidate all layers**: When data changes, clear both Redis and Next.js cache
