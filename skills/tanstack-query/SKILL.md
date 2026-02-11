---
name: tanstack-query
description: TanStack Query (React Query) patterns for server state management
context: fork
---

# TanStack Query Patterns

Reference for server state management with TanStack Query v5.

## Setup

```tsx
// app/providers.tsx
"use client"

import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { ReactQueryDevtools } from '@tanstack/react-query-devtools'
import { useState } from 'react'

export function Providers({ children }: { children: React.ReactNode }) {
  const [queryClient] = useState(
    () =>
      new QueryClient({
        defaultOptions: {
          queries: {
            staleTime: 60 * 1000, // 1 minute
            gcTime: 5 * 60 * 1000, // 5 minutes (formerly cacheTime)
          },
        },
      })
  )

  return (
    <QueryClientProvider client={queryClient}>
      {children}
      <ReactQueryDevtools initialIsOpen={false} />
    </QueryClientProvider>
  )
}

// app/layout.tsx
import { Providers } from './providers'

export default function RootLayout({ children }) {
  return (
    <html>
      <body>
        <Providers>{children}</Providers>
      </body>
    </html>
  )
}
```

## Basic Query

```tsx
"use client"

import { useQuery } from '@tanstack/react-query'

interface User {
  id: string
  name: string
  email: string
}

async function fetchUsers(): Promise<User[]> {
  const response = await fetch('/api/users')
  if (!response.ok) throw new Error('Failed to fetch users')
  return response.json()
}

export function UserList() {
  const { data: users, isLoading, error } = useQuery({
    queryKey: ['users'],
    queryFn: fetchUsers,
  })

  if (isLoading) return <div>Loading...</div>
  if (error) return <div>Error: {error.message}</div>

  return (
    <ul>
      {users?.map((user) => (
        <li key={user.id}>{user.name}</li>
      ))}
    </ul>
  )
}
```

## Query with Parameters

```tsx
"use client"

import { useQuery } from '@tanstack/react-query'

interface User {
  id: string
  name: string
}

async function fetchUser(userId: string): Promise<User> {
  const response = await fetch(`/api/users/${userId}`)
  if (!response.ok) throw new Error('Failed to fetch user')
  return response.json()
}

export function UserProfile({ userId }: { userId: string }) {
  const { data: user, isLoading } = useQuery({
    queryKey: ['users', userId], // Include parameter in key
    queryFn: () => fetchUser(userId),
    enabled: !!userId, // Only run when userId exists
  })

  if (isLoading) return <div>Loading...</div>

  return <div>{user?.name}</div>
}
```

## Query Keys Best Practices

```tsx
// Hierarchical keys for automatic invalidation
const queryKeys = {
  users: {
    all: ['users'] as const,
    lists: () => [...queryKeys.users.all, 'list'] as const,
    list: (filters: string) => [...queryKeys.users.lists(), { filters }] as const,
    details: () => [...queryKeys.users.all, 'detail'] as const,
    detail: (id: string) => [...queryKeys.users.details(), id] as const,
  },
}

// Usage
useQuery({
  queryKey: queryKeys.users.detail(userId),
  queryFn: () => fetchUser(userId),
})

// Invalidation - invalidates all user queries
queryClient.invalidateQueries({ queryKey: queryKeys.users.all })

// Or just user lists
queryClient.invalidateQueries({ queryKey: queryKeys.users.lists() })
```

## Mutations

```tsx
"use client"

import { useMutation, useQueryClient } from '@tanstack/react-query'

interface CreateUserData {
  name: string
  email: string
}

async function createUser(data: CreateUserData) {
  const response = await fetch('/api/users', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(data),
  })
  if (!response.ok) throw new Error('Failed to create user')
  return response.json()
}

export function CreateUserForm() {
  const queryClient = useQueryClient()

  const mutation = useMutation({
    mutationFn: createUser,
    onSuccess: () => {
      // Invalidate and refetch users list
      queryClient.invalidateQueries({ queryKey: ['users'] })
    },
  })

  const handleSubmit = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault()
    const formData = new FormData(e.currentTarget)
    mutation.mutate({
      name: formData.get('name') as string,
      email: formData.get('email') as string,
    })
  }

  return (
    <form onSubmit={handleSubmit}>
      <input name="name" placeholder="Name" />
      <input name="email" placeholder="Email" />
      <button type="submit" disabled={mutation.isPending}>
        {mutation.isPending ? 'Creating...' : 'Create User'}
      </button>
      {mutation.error && <p className="text-red-500">{mutation.error.message}</p>}
    </form>
  )
}
```

## Optimistic Updates

```tsx
"use client"

import { useMutation, useQueryClient } from '@tanstack/react-query'

interface Todo {
  id: string
  title: string
  completed: boolean
}

export function useTodoToggle() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async (todo: Todo) => {
      const response = await fetch(`/api/todos/${todo.id}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ completed: !todo.completed }),
      })
      return response.json()
    },

    // Optimistic update
    onMutate: async (todo) => {
      // Cancel outgoing refetches
      await queryClient.cancelQueries({ queryKey: ['todos'] })

      // Snapshot previous value
      const previousTodos = queryClient.getQueryData<Todo[]>(['todos'])

      // Optimistically update
      queryClient.setQueryData<Todo[]>(['todos'], (old) =>
        old?.map((t) =>
          t.id === todo.id ? { ...t, completed: !t.completed } : t
        )
      )

      // Return context for rollback
      return { previousTodos }
    },

    // Rollback on error
    onError: (err, todo, context) => {
      queryClient.setQueryData(['todos'], context?.previousTodos)
    },

    // Always refetch after error or success
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: ['todos'] })
    },
  })
}
```

## Infinite Queries

```tsx
"use client"

import { useInfiniteQuery } from '@tanstack/react-query'

interface Page {
  items: Item[]
  nextCursor?: string
}

async function fetchItems({ pageParam }: { pageParam?: string }): Promise<Page> {
  const url = pageParam
    ? `/api/items?cursor=${pageParam}`
    : '/api/items'
  const response = await fetch(url)
  return response.json()
}

export function InfiniteList() {
  const {
    data,
    fetchNextPage,
    hasNextPage,
    isFetchingNextPage,
  } = useInfiniteQuery({
    queryKey: ['items'],
    queryFn: fetchItems,
    initialPageParam: undefined,
    getNextPageParam: (lastPage) => lastPage.nextCursor,
  })

  return (
    <div>
      {data?.pages.map((page, i) => (
        <div key={i}>
          {page.items.map((item) => (
            <div key={item.id}>{item.name}</div>
          ))}
        </div>
      ))}

      <button
        onClick={() => fetchNextPage()}
        disabled={!hasNextPage || isFetchingNextPage}
      >
        {isFetchingNextPage
          ? 'Loading more...'
          : hasNextPage
          ? 'Load More'
          : 'Nothing more to load'}
      </button>
    </div>
  )
}
```

## Prefetching

```tsx
"use client"

import { useQueryClient } from '@tanstack/react-query'

export function UserListItem({ user }: { user: User }) {
  const queryClient = useQueryClient()

  // Prefetch on hover
  const prefetchUser = () => {
    queryClient.prefetchQuery({
      queryKey: ['users', user.id],
      queryFn: () => fetchUser(user.id),
      staleTime: 5 * 60 * 1000, // 5 minutes
    })
  }

  return (
    <Link
      href={`/users/${user.id}`}
      onMouseEnter={prefetchUser}
    >
      {user.name}
    </Link>
  )
}
```

## Dependent Queries

```tsx
// Query that depends on another query
const { data: user } = useQuery({
  queryKey: ['user', userId],
  queryFn: () => fetchUser(userId),
})

const { data: projects } = useQuery({
  queryKey: ['projects', user?.id],
  queryFn: () => fetchProjects(user!.id),
  enabled: !!user?.id, // Only run when user exists
})
```

## Parallel Queries

```tsx
import { useQueries } from '@tanstack/react-query'

export function UserProfiles({ userIds }: { userIds: string[] }) {
  const results = useQueries({
    queries: userIds.map((id) => ({
      queryKey: ['user', id],
      queryFn: () => fetchUser(id),
    })),
  })

  const isLoading = results.some((r) => r.isLoading)
  const users = results.map((r) => r.data).filter(Boolean)

  if (isLoading) return <div>Loading...</div>

  return (
    <ul>
      {users.map((user) => (
        <li key={user.id}>{user.name}</li>
      ))}
    </ul>
  )
}
```

## Query Options Pattern

```tsx
// Define query options separately for reuse
import { queryOptions } from '@tanstack/react-query'

export const userQueryOptions = (userId: string) =>
  queryOptions({
    queryKey: ['users', userId],
    queryFn: () => fetchUser(userId),
    staleTime: 5 * 60 * 1000,
  })

// Usage in component
const { data } = useQuery(userQueryOptions(userId))

// Usage in prefetch
queryClient.prefetchQuery(userQueryOptions(userId))

// Usage in loader (server components)
await queryClient.ensureQueryData(userQueryOptions(userId))
```

## Integration with Next.js 16 Cache

### Server-Side Prefetch with HydrationBoundary

```tsx
// app/users/page.tsx
import { dehydrate, HydrationBoundary, QueryClient } from '@tanstack/react-query'
import { UserList } from '@/components/UserList'
import { getUsers } from '@/lib/queries/users'

export default async function UsersPage() {
  const queryClient = new QueryClient()

  // Prefetch on server (can use "use cache" internally)
  await queryClient.prefetchQuery({
    queryKey: ['users'],
    queryFn: getUsers,
  })

  return (
    <HydrationBoundary state={dehydrate(queryClient)}>
      <UserList />
    </HydrationBoundary>
  )
}
```

### Avoiding Double Caching

```tsx
// Choose ONE cache owner per data type

// Option A: Next.js owns cache (recommended for SSR)
// lib/queries/users.ts
export async function getUsers() {
  "use cache"
  cacheLife('minutes')
  cacheTag('users')
  return db.query.users.findMany()
}

// TanStack Query just consumes, minimal staleTime
const { data } = useQuery({
  queryKey: ['users'],
  queryFn: () => fetch('/api/users').then(r => r.json()),
  staleTime: 0, // Defer to server cache
})

// Option B: TanStack Query owns cache (for highly dynamic data)
// No "use cache" on server
const { data } = useQuery({
  queryKey: ['users'],
  queryFn: () => fetch('/api/users').then(r => r.json()),
  staleTime: 5 * 60 * 1000, // 5 minutes
  gcTime: 30 * 60 * 1000,   // 30 minutes
})
```

### Full Invalidation Chain

```tsx
// When data changes, invalidate all cache layers
import { useMutation, useQueryClient } from '@tanstack/react-query'

export function useCreateUser() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: createUser,
    onSuccess: () => {
      // TanStack Query cache
      queryClient.invalidateQueries({ queryKey: ['users'] })

      // Server action also invalidates:
      // - Redis cache (if used)
      // - Next.js cache via revalidateTag('users')
    },
  })
}

// app/api/users/route.ts
export async function POST(request: Request) {
  const data = await request.json()
  const user = await db.insert(users).values(data).returning()

  // Invalidate server caches
  await redis.del('users:all')
  revalidateTag('users')

  return Response.json(user, { status: 201 })
}
```

## Integration with Zustand

### Clear Separation

```tsx
// Zustand: UI state (filters, selections, modals)
// TanStack Query: Server state (data from API)

// stores/filterStore.ts
export const useFilterStore = create<FilterState>((set) => ({
  search: '',
  category: null,
  setSearch: (search) => set({ search }),
  setCategory: (category) => set({ category }),
}))

// hooks/useFilteredData.ts
export function useFilteredData() {
  // Get filters from Zustand
  const { search, category } = useFilterStore()

  // Use in TanStack Query - auto-refetch when filters change
  return useQuery({
    queryKey: ['data', { search, category }],
    queryFn: () => fetchData({ search, category }),
  })
}
```

## Best Practices

1. **Structure query keys hierarchically**: Enables targeted invalidation
2. **Use `enabled` option**: Prevent queries from running prematurely
3. **Set appropriate `staleTime`**: Balance freshness vs network requests
4. **Optimistic updates for instant UI**: Always handle rollback
5. **Use `queryOptions` helper**: Type-safe, reusable query configurations
6. **Invalidate after mutations**: Ensure data consistency
7. **Use devtools during development**: Debug cache state easily
8. **Don't double-cache**: Choose Next.js OR TanStack Query as cache owner
9. **Prefetch on server**: Use HydrationBoundary for instant hydration
10. **Zustand for UI, Query for data**: Clear separation of concerns
