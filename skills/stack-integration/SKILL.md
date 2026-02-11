---
name: stack-integration
description: Cross-technology integration patterns for the full stack
context: fork
---

# Stack Integration Patterns

Reference for how the technologies in this stack work together.

## Technology Overview

| Layer | Technology | Purpose |
|-------|------------|---------|
| Framework | Next.js 16 | App Router, RSC, Turbopack |
| State (Server) | TanStack Query v5 | Server state, caching |
| State (Client) | Zustand | Client-only state |
| Cache (Server) | "use cache" / cacheLife | Next.js built-in |
| Cache (External) | Upstash Redis | Shared cache, rate limiting |
| Database | Drizzle ORM | PostgreSQL access |
| UI | ShadCN + Tailwind | Components + styling |
| Animation | Framer Motion | Motion design |

## Cache Layer Strategy

### Decision Tree: Which Cache to Use?

```
Need to cache data?
├── Is it per-user session data?
│   └── Use: Upstash Redis (sessions)
├── Is it shared across all users?
│   ├── Does it need to be invalidated by tag?
│   │   └── Use: Next.js "use cache" + cacheTag
│   └── Is it expensive to compute?
│       └── Use: Upstash Redis (computed values)
├── Is it client-side API data?
│   └── Use: TanStack Query (gcTime, staleTime)
└── Is it static/rarely changes?
    └── Use: Next.js "use cache" with cacheLife('days')
```

### Multi-Layer Cache Example

```typescript
// Layer 1: Next.js "use cache" - Request-level caching
async function getProducts() {
  "use cache"
  cacheLife('hours')
  cacheTag('products')

  // Layer 2: Redis - Shared cache for expensive operations
  const cached = await redis.get('products:all')
  if (cached) return JSON.parse(cached)

  // Layer 3: Database query
  const products = await db.query.products.findMany()

  // Cache in Redis for other instances
  await redis.set('products:all', JSON.stringify(products), { ex: 3600 })

  return products
}

// Client-side: TanStack Query adds another layer
const { data } = useQuery({
  queryKey: ['products'],
  queryFn: () => fetch('/api/products').then(r => r.json()),
  staleTime: 5 * 60 * 1000, // Consider fresh for 5 minutes
})
```

### Cache Invalidation Flow

```
User Action (e.g., create product)
    │
    ▼
API Route Handler
    │
    ├── Update Database (Drizzle)
    │
    ├── Invalidate Redis Cache
    │   await redis.del('products:all')
    │
    ├── Invalidate Next.js Cache
    │   revalidateTag('products')
    │
    └── Return Response
         │
         ▼
Client receives response
    │
    └── TanStack Query invalidates
        queryClient.invalidateQueries({ queryKey: ['products'] })
```

## State Management Decision Tree

### When to Use What

```
Where does this data come from?
├── Server (API/Database)
│   └── Use: TanStack Query
│       - Automatic caching
│       - Background refetching
│       - Loading/error states
│
├── Client-only (no persistence needed)
│   └── Use: Zustand
│       - UI state (modals, sidebars)
│       - Form state (multi-step)
│       - Temporary filters
│
└── Both (server data + client modifications)
    └── Use: TanStack Query + optimistic updates
        - Server is source of truth
        - Client updates optimistically
        - Rollback on error
```

### TanStack Query + Zustand Integration

```typescript
// stores/filterStore.ts - Client state for filters
import { create } from 'zustand'

interface FilterState {
  search: string
  category: string | null
  setSearch: (search: string) => void
  setCategory: (category: string | null) => void
}

export const useFilterStore = create<FilterState>((set) => ({
  search: '',
  category: null,
  setSearch: (search) => set({ search }),
  setCategory: (category) => set({ category }),
}))

// hooks/useProducts.ts - Server state with client filters
import { useQuery } from '@tanstack/react-query'
import { useFilterStore } from '@/stores/filterStore'

export function useProducts() {
  // Get client-side filters from Zustand
  const { search, category } = useFilterStore()

  // Use filters in TanStack Query
  return useQuery({
    queryKey: ['products', { search, category }],
    queryFn: () => fetchProducts({ search, category }),
    // Only fetch when filters change
    enabled: true,
  })
}

// components/ProductList.tsx
"use client"

export function ProductList() {
  const { data, isLoading } = useProducts()
  const { search, setSearch, category, setCategory } = useFilterStore()

  // UI uses both Zustand (filters) and TanStack Query (data)
  return (
    <div>
      <input
        value={search}
        onChange={(e) => setSearch(e.target.value)}
        placeholder="Search..."
      />
      {/* Products from TanStack Query */}
      {data?.map(product => <ProductCard key={product.id} product={product} />)}
    </div>
  )
}
```

## Full-Stack Data Flow

### Create Operation Flow

```
1. User submits form (Client)
   │
2. TanStack Query mutation starts
   │
3. Optimistic update (optional)
   │  - Update cache immediately
   │  - Show success state
   │
4. API Route receives request
   │
5. Zod validates input
   │  - Return 400 if invalid
   │
6. Drizzle inserts to database
   │
7. Invalidate caches
   │  - Redis: redis.del('key')
   │  - Next.js: revalidateTag('tag')
   │
8. Return response
   │
9. TanStack Query updates
   │  - Invalidate queries
   │  - Trigger refetch
   │
10. UI updates with fresh data
```

### Implementation Example

```typescript
// app/api/products/route.ts
import { NextRequest, NextResponse } from 'next/server'
import { db } from '@/lib/db'
import { products } from '@/lib/db/schema'
import { redis } from '@/lib/redis'
import { revalidateTag } from 'next/cache'
import { z } from 'zod'

const createProductSchema = z.object({
  name: z.string().min(1),
  price: z.number().positive(),
})

export async function POST(request: NextRequest) {
  // 1. Parse and validate
  const body = await request.json()
  const result = createProductSchema.safeParse(body)

  if (!result.success) {
    return NextResponse.json(
      { error: 'Invalid input', details: result.error.flatten() },
      { status: 400 }
    )
  }

  // 2. Insert to database
  const [product] = await db
    .insert(products)
    .values(result.data)
    .returning()

  // 3. Invalidate caches
  await redis.del('products:all')
  revalidateTag('products')

  // 4. Return response
  return NextResponse.json(product, { status: 201 })
}

// hooks/useCreateProduct.ts
import { useMutation, useQueryClient } from '@tanstack/react-query'

export function useCreateProduct() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async (data: { name: string; price: number }) => {
      const response = await fetch('/api/products', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(data),
      })
      if (!response.ok) throw new Error('Failed to create')
      return response.json()
    },
    onSuccess: () => {
      // Invalidate TanStack Query cache
      queryClient.invalidateQueries({ queryKey: ['products'] })
    },
  })
}
```

## Next.js 16 Cache + TanStack Query

### Server-Side Prefetch

```typescript
// app/products/page.tsx
import { dehydrate, HydrationBoundary, QueryClient } from '@tanstack/react-query'
import { ProductList } from '@/components/ProductList'

// Server Component
export default async function ProductsPage() {
  const queryClient = new QueryClient()

  // Prefetch on server
  await queryClient.prefetchQuery({
    queryKey: ['products'],
    queryFn: getProducts, // Uses "use cache" internally
  })

  return (
    <HydrationBoundary state={dehydrate(queryClient)}>
      <ProductList />
    </HydrationBoundary>
  )
}

// lib/queries/products.ts
export async function getProducts() {
  "use cache"
  cacheLife('minutes')
  cacheTag('products')

  return db.query.products.findMany()
}
```

### Avoiding Double Caching

```typescript
// WRONG: Double caching
async function getProducts() {
  "use cache"  // Next.js cache
  cacheLife('hours')

  // Don't also use staleTime in TanStack Query
  // This creates confusion about which cache is authoritative
}

// CORRECT: Clear cache ownership
// Option A: Next.js owns the cache
async function getProducts() {
  "use cache"
  cacheLife('hours')
  cacheTag('products')
  return db.query.products.findMany()
}

// TanStack Query just fetches, minimal staleTime
const { data } = useQuery({
  queryKey: ['products'],
  queryFn: () => fetch('/api/products').then(r => r.json()),
  staleTime: 0, // Always defer to server cache
})

// Option B: TanStack Query owns the cache
// No "use cache" on server, use staleTime in TanStack Query
const { data } = useQuery({
  queryKey: ['products'],
  queryFn: () => fetch('/api/products').then(r => r.json()),
  staleTime: 5 * 60 * 1000, // 5 minutes
  gcTime: 30 * 60 * 1000,   // 30 minutes
})
```

## ShadCN + Framer Motion Integration

### Animated Dialog

```tsx
"use client"

import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from '@/components/ui/dialog'
import { motion, AnimatePresence } from 'framer-motion'
import { useState } from 'react'

const overlayVariants = {
  hidden: { opacity: 0 },
  visible: { opacity: 1 },
}

const contentVariants = {
  hidden: { opacity: 0, scale: 0.95, y: 10 },
  visible: { opacity: 1, scale: 1, y: 0 },
}

export function AnimatedDialog({ trigger, title, children }) {
  const [open, setOpen] = useState(false)

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>{trigger}</DialogTrigger>
      <AnimatePresence>
        {open && (
          <DialogContent forceMount asChild>
            <motion.div
              variants={contentVariants}
              initial="hidden"
              animate="visible"
              exit="hidden"
              transition={{ type: 'spring', damping: 25, stiffness: 300 }}
            >
              <DialogHeader>
                <DialogTitle>{title}</DialogTitle>
              </DialogHeader>
              {children}
            </motion.div>
          </DialogContent>
        )}
      </AnimatePresence>
    </Dialog>
  )
}
```

### Animated Card Hover

```tsx
"use client"

import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { motion } from 'framer-motion'

export function AnimatedCard({ title, children }) {
  return (
    <motion.div
      whileHover={{ y: -4 }}
      transition={{ type: 'spring', stiffness: 400, damping: 25 }}
    >
      <Card className="transition-shadow hover:shadow-lg">
        <CardHeader>
          <CardTitle>{title}</CardTitle>
        </CardHeader>
        <CardContent>{children}</CardContent>
      </Card>
    </motion.div>
  )
}
```

### Animated List with ShadCN

```tsx
"use client"

import { motion, AnimatePresence } from 'framer-motion'
import { Card } from '@/components/ui/card'

const listVariants = {
  hidden: { opacity: 0 },
  visible: {
    opacity: 1,
    transition: { staggerChildren: 0.05 },
  },
}

const itemVariants = {
  hidden: { opacity: 0, y: 20 },
  visible: { opacity: 1, y: 0 },
  exit: { opacity: 0, x: -20 },
}

export function AnimatedList({ items }) {
  return (
    <motion.div
      variants={listVariants}
      initial="hidden"
      animate="visible"
      className="space-y-4"
    >
      <AnimatePresence mode="popLayout">
        {items.map((item) => (
          <motion.div
            key={item.id}
            variants={itemVariants}
            exit="exit"
            layout
          >
            <Card className="p-4">
              {item.content}
            </Card>
          </motion.div>
        ))}
      </AnimatePresence>
    </motion.div>
  )
}
```

## Drizzle + Next.js Cache Integration

### Cached Database Queries

```typescript
// lib/queries/users.ts
import { db } from '@/lib/db'
import { users } from '@/lib/db/schema'
import { cacheLife, cacheTag } from 'next/cache'
import { eq } from 'drizzle-orm'

export async function getUser(userId: string) {
  "use cache"
  cacheLife('minutes')
  cacheTag('users', `user-${userId}`)

  return db.query.users.findFirst({
    where: eq(users.id, userId),
  })
}

export async function getAllUsers() {
  "use cache"
  cacheLife('hours')
  cacheTag('users')

  return db.query.users.findMany()
}

// Invalidation helper
export async function invalidateUserCache(userId?: string) {
  if (userId) {
    revalidateTag(`user-${userId}`)
  }
  revalidateTag('users')
}
```

### Type-Safe Query Results

```typescript
// Export the type from Drizzle for use elsewhere
import { db } from '@/lib/db'
import { users } from '@/lib/db/schema'

// Infer the type from Drizzle
export type User = typeof users.$inferSelect
export type NewUser = typeof users.$inferInsert

// Use in components
import type { User } from '@/lib/queries/users'

function UserCard({ user }: { user: User }) {
  return <div>{user.name}</div>
}
```

## Upstash Redis + Next.js Cache

### Complementary Caching

```typescript
// Redis for: Rate limiting, sessions, computed values
// Next.js for: Page-level caching, request deduplication

import { redis } from '@/lib/redis'
import { Ratelimit } from '@upstash/ratelimit'

// Rate limiting (Redis only - needs shared state)
const ratelimit = new Ratelimit({
  redis,
  limiter: Ratelimit.slidingWindow(10, '10 s'),
})

// Expensive computation (Redis for sharing)
async function getExpensiveReport(orgId: string) {
  const cacheKey = `report:${orgId}`

  // Check Redis first
  const cached = await redis.get(cacheKey)
  if (cached) return JSON.parse(cached as string)

  // Compute
  const report = await computeExpensiveReport(orgId)

  // Cache in Redis (shared across instances)
  await redis.set(cacheKey, JSON.stringify(report), { ex: 3600 })

  return report
}

// Page data (Next.js cache for request-level)
async function getPageData() {
  "use cache"
  cacheLife('minutes')

  // This is cached at the request level by Next.js
  // Multiple components calling this in same request = 1 execution
  return db.query.posts.findMany()
}
```

## Best Practices

1. **Single Source of Truth** - Pick one cache layer as authoritative per data type
2. **Clear Invalidation** - When data changes, invalidate all cache layers
3. **Type Safety End-to-End** - Export types from Drizzle, use in API, use in client
4. **Optimistic Where Safe** - Use optimistic updates for non-critical actions
5. **Zustand for UI Only** - Don't duplicate server state in Zustand
6. **Motion with Purpose** - Animate meaningful transitions, not everything
