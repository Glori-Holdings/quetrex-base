# Reactive Frontend Patterns

Comprehensive patterns for SSE, Zustand, TanStack Query v5, and real-time reactive UIs in Next.js 16.

## Stack Versions (ALWAYS verify with Context7)

- **Next.js 16** - App Router, React Compiler
- **React 19.2** - useEffectEvent, View Transitions
- **TanStack Query v5** - Server state management
- **Zustand 5.x** - Client state management
- **TypeScript 5.x** - Strict mode (NO any)

## Decision Matrix

| Data Type | Primary Tool | Secondary | When to Use |
|-----------|--------------|-----------|-------------|
| Server data (cached) | TanStack Query | - | API calls, database reads |
| Real-time events | SSE | Zustand | Notifications, chat, live updates |
| Client-only state | Zustand | - | UI state, form state, preferences |
| Form state | React Hook Form | Zustand | Complex forms with validation |
| URL state | nuqs/useSearchParams | - | Filters, pagination, shareable state |

## SSE (Server-Sent Events)

### API Route Pattern (Next.js 16)

```typescript
// app/api/events/[channel]/route.ts
import { NextRequest } from 'next/server'

export const runtime = 'nodejs'
export const dynamic = 'force-dynamic'

interface EventPayload {
  type: string
  data: unknown
  timestamp: number
}

export async function GET(
  request: NextRequest,
  { params }: { params: Promise<{ channel: string }> }
) {
  const { channel } = await params
  const encoder = new TextEncoder()

  const stream = new ReadableStream({
    start(controller) {
      const sendEvent = (payload: EventPayload) => {
        const data = `data: ${JSON.stringify(payload)}\n\n`
        controller.enqueue(encoder.encode(data))
      }

      // Send connection confirmation
      sendEvent({
        type: 'connected',
        data: { channel },
        timestamp: Date.now(),
      })

      // Heartbeat to keep connection alive
      const heartbeat = setInterval(() => {
        sendEvent({
          type: 'heartbeat',
          data: null,
          timestamp: Date.now(),
        })
      }, 30000)

      // Subscribe to your event source here
      // Example: Redis pub/sub, database changes, etc.
      const unsubscribe = subscribeToChannel(channel, (event) => {
        sendEvent(event)
      })

      // Cleanup on disconnect
      request.signal.addEventListener('abort', () => {
        clearInterval(heartbeat)
        unsubscribe()
        controller.close()
      })
    },
  })

  return new Response(stream, {
    headers: {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache, no-transform',
      'Connection': 'keep-alive',
      'X-Accel-Buffering': 'no', // Disable nginx buffering
    },
  })
}

// Placeholder - implement based on your event source
function subscribeToChannel(
  channel: string,
  callback: (event: EventPayload) => void
): () => void {
  // Return unsubscribe function
  return () => {}
}
```

### Client Hook Pattern

```typescript
// hooks/useSSE.ts
"use client"

import { useEffect, useRef, useCallback, useState } from 'react'

interface UseSSEOptions<T> {
  url: string
  onMessage: (data: T) => void
  onError?: (error: Event) => void
  onOpen?: () => void
  enabled?: boolean
  reconnectDelay?: number
  maxRetries?: number
}

interface UseSSEReturn {
  isConnected: boolean
  error: Event | null
  reconnect: () => void
}

export function useSSE<T>({
  url,
  onMessage,
  onError,
  onOpen,
  enabled = true,
  reconnectDelay = 3000,
  maxRetries = 5,
}: UseSSEOptions<T>): UseSSEReturn {
  const [isConnected, setIsConnected] = useState(false)
  const [error, setError] = useState<Event | null>(null)
  const eventSourceRef = useRef<EventSource | null>(null)
  const retriesRef = useRef(0)

  const connect = useCallback(() => {
    if (!enabled || eventSourceRef.current) return

    const eventSource = new EventSource(url)
    eventSourceRef.current = eventSource

    eventSource.onopen = () => {
      setIsConnected(true)
      setError(null)
      retriesRef.current = 0
      onOpen?.()
    }

    eventSource.onmessage = (event: MessageEvent) => {
      try {
        const data = JSON.parse(event.data) as T
        onMessage(data)
      } catch (e) {
        console.error('Failed to parse SSE message:', e)
      }
    }

    eventSource.onerror = (err) => {
      setIsConnected(false)
      setError(err)
      onError?.(err)
      eventSource.close()
      eventSourceRef.current = null

      // Auto-reconnect with exponential backoff
      if (retriesRef.current < maxRetries) {
        retriesRef.current++
        const delay = reconnectDelay * Math.pow(2, retriesRef.current - 1)
        setTimeout(connect, delay)
      }
    }
  }, [url, enabled, onMessage, onError, onOpen, reconnectDelay, maxRetries])

  const reconnect = useCallback(() => {
    eventSourceRef.current?.close()
    eventSourceRef.current = null
    retriesRef.current = 0
    connect()
  }, [connect])

  useEffect(() => {
    connect()

    return () => {
      eventSourceRef.current?.close()
      eventSourceRef.current = null
    }
  }, [connect])

  return { isConnected, error, reconnect }
}
```

## Zustand Patterns

### Store with Selectors (Performance Optimized)

```typescript
// stores/app.ts
import { create } from 'zustand'
import { subscribeWithSelector, devtools, persist } from 'zustand/middleware'
import { immer } from 'zustand/middleware/immer'

interface AppState {
  // State
  theme: 'light' | 'dark' | 'system'
  sidebarOpen: boolean
  notifications: Notification[]

  // Actions
  setTheme: (theme: AppState['theme']) => void
  toggleSidebar: () => void
  addNotification: (notification: Omit<Notification, 'id'>) => void
  removeNotification: (id: string) => void
}

interface Notification {
  id: string
  message: string
  type: 'info' | 'success' | 'error' | 'warning'
}

export const useAppStore = create<AppState>()(
  devtools(
    persist(
      subscribeWithSelector(
        immer((set) => ({
          // Initial state
          theme: 'system',
          sidebarOpen: true,
          notifications: [],

          // Actions
          setTheme: (theme) =>
            set((state) => {
              state.theme = theme
            }),

          toggleSidebar: () =>
            set((state) => {
              state.sidebarOpen = !state.sidebarOpen
            }),

          addNotification: (notification) =>
            set((state) => {
              state.notifications.push({
                ...notification,
                id: crypto.randomUUID(),
              })
            }),

          removeNotification: (id) =>
            set((state) => {
              state.notifications = state.notifications.filter(
                (n) => n.id !== id
              )
            }),
        }))
      ),
      {
        name: 'app-storage',
        partialize: (state) => ({
          theme: state.theme,
          sidebarOpen: state.sidebarOpen,
        }),
      }
    ),
    { name: 'AppStore' }
  )
)

// Derived selectors (memoized)
export const useTheme = () => useAppStore((state) => state.theme)
export const useSidebarOpen = () => useAppStore((state) => state.sidebarOpen)
export const useNotifications = () => useAppStore((state) => state.notifications)
export const useUnreadCount = () =>
  useAppStore((state) => state.notifications.length)
```

### Zustand with TanStack Query Sync

```typescript
// stores/users.ts
import { create } from 'zustand'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect } from 'react'

interface User {
  id: string
  name: string
  email: string
}

interface UserStore {
  selectedUserId: string | null
  setSelectedUserId: (id: string | null) => void
}

// Client-only state in Zustand
export const useUserStore = create<UserStore>()((set) => ({
  selectedUserId: null,
  setSelectedUserId: (id) => set({ selectedUserId: id }),
}))

// Server state in TanStack Query
const userKeys = {
  all: ['users'] as const,
  detail: (id: string) => ['users', id] as const,
}

async function fetchUsers(): Promise<User[]> {
  const res = await fetch('/api/users')
  if (!res.ok) throw new Error('Failed to fetch users')
  return res.json()
}

// Combined hook
export function useUsers() {
  return useQuery({
    queryKey: userKeys.all,
    queryFn: fetchUsers,
    staleTime: 5 * 60 * 1000, // 5 minutes
  })
}

export function useSelectedUser() {
  const selectedUserId = useUserStore((state) => state.selectedUserId)
  const { data: users } = useUsers()

  return users?.find((user) => user.id === selectedUserId) ?? null
}
```

## TanStack Query v5 Patterns

### Query Factory Pattern

```typescript
// lib/queries/users.ts
import { queryOptions, infiniteQueryOptions } from '@tanstack/react-query'

interface User {
  id: string
  name: string
  email: string
  createdAt: string
}

interface UsersResponse {
  users: User[]
  nextCursor: string | null
}

export const userQueries = {
  all: () =>
    queryOptions({
      queryKey: ['users'],
      queryFn: async (): Promise<User[]> => {
        const res = await fetch('/api/users')
        if (!res.ok) throw new Error('Failed to fetch users')
        return res.json()
      },
      staleTime: 5 * 60 * 1000,
    }),

  detail: (id: string) =>
    queryOptions({
      queryKey: ['users', id],
      queryFn: async (): Promise<User> => {
        const res = await fetch(`/api/users/${id}`)
        if (!res.ok) throw new Error('Failed to fetch user')
        return res.json()
      },
      staleTime: 5 * 60 * 1000,
    }),

  infinite: () =>
    infiniteQueryOptions({
      queryKey: ['users', 'infinite'],
      queryFn: async ({ pageParam }): Promise<UsersResponse> => {
        const url = new URL('/api/users', window.location.origin)
        if (pageParam) url.searchParams.set('cursor', pageParam)
        const res = await fetch(url)
        if (!res.ok) throw new Error('Failed to fetch users')
        return res.json()
      },
      initialPageParam: null as string | null,
      getNextPageParam: (lastPage) => lastPage.nextCursor,
    }),
}
```

### Mutation with Optimistic Update

```typescript
// hooks/useUpdateUser.ts
import { useMutation, useQueryClient } from '@tanstack/react-query'

interface User {
  id: string
  name: string
  email: string
}

interface UpdateUserInput {
  id: string
  name?: string
  email?: string
}

async function updateUser(input: UpdateUserInput): Promise<User> {
  const res = await fetch(`/api/users/${input.id}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(input),
  })
  if (!res.ok) throw new Error('Failed to update user')
  return res.json()
}

export function useUpdateUser() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: updateUser,

    onMutate: async (newData) => {
      // Cancel outgoing refetches
      await queryClient.cancelQueries({ queryKey: ['users', newData.id] })
      await queryClient.cancelQueries({ queryKey: ['users'] })

      // Snapshot current values
      const previousUser = queryClient.getQueryData<User>(['users', newData.id])
      const previousUsers = queryClient.getQueryData<User[]>(['users'])

      // Optimistic update for detail
      if (previousUser) {
        queryClient.setQueryData<User>(['users', newData.id], {
          ...previousUser,
          ...newData,
        })
      }

      // Optimistic update for list
      if (previousUsers) {
        queryClient.setQueryData<User[]>(
          ['users'],
          previousUsers.map((user) =>
            user.id === newData.id ? { ...user, ...newData } : user
          )
        )
      }

      return { previousUser, previousUsers }
    },

    onError: (_error, newData, context) => {
      // Rollback on error
      if (context?.previousUser) {
        queryClient.setQueryData(['users', newData.id], context.previousUser)
      }
      if (context?.previousUsers) {
        queryClient.setQueryData(['users'], context.previousUsers)
      }
    },

    onSettled: (_data, _error, variables) => {
      // Refetch to ensure consistency
      queryClient.invalidateQueries({ queryKey: ['users', variables.id] })
      queryClient.invalidateQueries({ queryKey: ['users'] })
    },
  })
}
```

## Integration Patterns

### SSE + TanStack Query + Zustand

```typescript
// hooks/useRealtimeData.ts
"use client"

import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useSSE } from './useSSE'
import { create } from 'zustand'
import { useEffect } from 'react'

interface DataItem {
  id: string
  value: number
  updatedAt: string
}

interface SSEEvent {
  type: 'update' | 'delete' | 'create'
  data: DataItem
}

// Client state for UI
interface UIStore {
  selectedId: string | null
  isRealTimeEnabled: boolean
  setSelectedId: (id: string | null) => void
  toggleRealTime: () => void
}

export const useUIStore = create<UIStore>()((set) => ({
  selectedId: null,
  isRealTimeEnabled: true,
  setSelectedId: (id) => set({ selectedId: id }),
  toggleRealTime: () => set((s) => ({ isRealTimeEnabled: !s.isRealTimeEnabled })),
}))

// Combined hook for real-time data
export function useRealtimeData() {
  const queryClient = useQueryClient()
  const isRealTimeEnabled = useUIStore((state) => state.isRealTimeEnabled)

  // Initial data from server
  const query = useQuery({
    queryKey: ['data'],
    queryFn: async (): Promise<DataItem[]> => {
      const res = await fetch('/api/data')
      if (!res.ok) throw new Error('Failed to fetch data')
      return res.json()
    },
    staleTime: Infinity, // SSE handles updates
  })

  // Real-time updates via SSE
  const { isConnected } = useSSE<SSEEvent>({
    url: '/api/data/stream',
    enabled: isRealTimeEnabled,
    onMessage: (event) => {
      queryClient.setQueryData<DataItem[]>(['data'], (old) => {
        if (!old) return old

        switch (event.type) {
          case 'create':
            return [...old, event.data]
          case 'update':
            return old.map((item) =>
              item.id === event.data.id ? event.data : item
            )
          case 'delete':
            return old.filter((item) => item.id !== event.data.id)
          default:
            return old
        }
      })
    },
  })

  return {
    ...query,
    isRealTimeConnected: isConnected,
    isRealTimeEnabled,
  }
}
```

## Provider Setup

```typescript
// providers/query-provider.tsx
"use client"

import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { ReactQueryDevtools } from '@tanstack/react-query-devtools'
import { useState, type ReactNode } from 'react'

function makeQueryClient() {
  return new QueryClient({
    defaultOptions: {
      queries: {
        staleTime: 60 * 1000, // 1 minute
        gcTime: 5 * 60 * 1000, // 5 minutes (was cacheTime in v4)
        retry: 3,
        retryDelay: (attemptIndex) => Math.min(1000 * 2 ** attemptIndex, 30000),
        refetchOnWindowFocus: true,
        refetchOnReconnect: true,
      },
      mutations: {
        retry: 1,
      },
    },
  })
}

let browserQueryClient: QueryClient | undefined = undefined

function getQueryClient() {
  if (typeof window === 'undefined') {
    // Server: always make a new client
    return makeQueryClient()
  }
  // Browser: reuse client
  if (!browserQueryClient) browserQueryClient = makeQueryClient()
  return browserQueryClient
}

export function QueryProvider({ children }: { children: ReactNode }) {
  const [queryClient] = useState(() => getQueryClient())

  return (
    <QueryClientProvider client={queryClient}>
      {children}
      <ReactQueryDevtools initialIsOpen={false} />
    </QueryClientProvider>
  )
}
```

## Testing Patterns

### Testing SSE Hooks

```typescript
// __tests__/useSSE.test.ts
import { renderHook, act, waitFor } from '@testing-library/react'
import { useSSE } from '@/hooks/useSSE'

// Mock EventSource
class MockEventSource {
  onmessage: ((event: MessageEvent) => void) | null = null
  onerror: ((event: Event) => void) | null = null
  onopen: (() => void) | null = null
  close = vi.fn()

  simulateMessage(data: unknown) {
    this.onmessage?.(new MessageEvent('message', {
      data: JSON.stringify(data),
    }))
  }

  simulateOpen() {
    this.onopen?.()
  }

  simulateError() {
    this.onerror?.(new Event('error'))
  }
}

vi.stubGlobal('EventSource', MockEventSource)

describe('useSSE', () => {
  it('should connect and receive messages', async () => {
    const onMessage = vi.fn()

    const { result } = renderHook(() =>
      useSSE({
        url: '/api/events',
        onMessage,
      })
    )

    // Simulate connection
    const eventSource = (globalThis.EventSource as unknown as typeof MockEventSource)
      .mock.results[0].value as MockEventSource
    eventSource.simulateOpen()

    await waitFor(() => {
      expect(result.current.isConnected).toBe(true)
    })

    // Simulate message
    act(() => {
      eventSource.simulateMessage({ type: 'test', data: 'hello' })
    })

    expect(onMessage).toHaveBeenCalledWith({ type: 'test', data: 'hello' })
  })
})
```

### Testing Zustand Stores

```typescript
// __tests__/stores/app.test.ts
import { useAppStore } from '@/stores/app'
import { act } from '@testing-library/react'

describe('AppStore', () => {
  beforeEach(() => {
    // Reset store between tests
    useAppStore.setState({
      theme: 'system',
      sidebarOpen: true,
      notifications: [],
    })
  })

  it('should toggle sidebar', () => {
    expect(useAppStore.getState().sidebarOpen).toBe(true)

    act(() => {
      useAppStore.getState().toggleSidebar()
    })

    expect(useAppStore.getState().sidebarOpen).toBe(false)
  })

  it('should add and remove notifications', () => {
    act(() => {
      useAppStore.getState().addNotification({
        message: 'Test',
        type: 'info',
      })
    })

    const notifications = useAppStore.getState().notifications
    expect(notifications).toHaveLength(1)
    expect(notifications[0].message).toBe('Test')

    act(() => {
      useAppStore.getState().removeNotification(notifications[0].id)
    })

    expect(useAppStore.getState().notifications).toHaveLength(0)
  })
})
```

## Common Pitfalls

### 1. Stale Closures in SSE Handlers
```typescript
// WRONG: Stale closure
useSSE({
  onMessage: (data) => {
    setState([...state, data]) // state is stale!
  }
})

// CORRECT: Use callback form
useSSE({
  onMessage: (data) => {
    setState((prev) => [...prev, data])
  }
})
```

### 2. Memory Leaks with Zustand Subscriptions
```typescript
// WRONG: No cleanup
useEffect(() => {
  useStore.subscribe((state) => console.log(state))
}, [])

// CORRECT: Cleanup subscription
useEffect(() => {
  const unsubscribe = useStore.subscribe((state) => console.log(state))
  return unsubscribe
}, [])
```

### 3. Duplicate Data in Query + Store
```typescript
// WRONG: Same data in two places
const { data } = useQuery({ queryKey: ['users'] })
const users = useUserStore(s => s.users) // Duplicate!

// CORRECT: Single source of truth
// Use Query for server data, Zustand for client-only state
const { data: users } = useQuery({ queryKey: ['users'] })
const selectedUserId = useUserStore(s => s.selectedUserId)
```
