---
name: zustand
description: Zustand state management patterns and best practices
context: fork
---

# Zustand Patterns

Reference for client state management with Zustand.

## Basic Store

```tsx
// stores/counter-store.ts
import { create } from 'zustand'

interface CounterState {
  count: number
  increment: () => void
  decrement: () => void
  reset: () => void
}

export const useCounterStore = create<CounterState>((set) => ({
  count: 0,
  increment: () => set((state) => ({ count: state.count + 1 })),
  decrement: () => set((state) => ({ count: state.count - 1 })),
  reset: () => set({ count: 0 }),
}))
```

## Usage in Components

```tsx
"use client"

import { useCounterStore } from '@/stores/counter-store'

export function Counter() {
  // Select specific values to prevent unnecessary re-renders
  const count = useCounterStore((state) => state.count)
  const increment = useCounterStore((state) => state.increment)
  const decrement = useCounterStore((state) => state.decrement)

  return (
    <div>
      <span>{count}</span>
      <button onClick={increment}>+</button>
      <button onClick={decrement}>-</button>
    </div>
  )
}
```

## Selectors for Performance

```tsx
// BAD - Subscribes to entire store, re-renders on any change
const state = useCounterStore()
const count = state.count

// GOOD - Only re-renders when count changes
const count = useCounterStore((state) => state.count)

// GOOD - Multiple values with shallow comparison
import { useShallow } from 'zustand/react/shallow'

const { count, increment } = useCounterStore(
  useShallow((state) => ({
    count: state.count,
    increment: state.increment,
  }))
)
```

## Async Actions

```tsx
// stores/user-store.ts
import { create } from 'zustand'

interface User {
  id: string
  name: string
  email: string
}

interface UserState {
  user: User | null
  isLoading: boolean
  error: string | null
  fetchUser: (id: string) => Promise<void>
  updateUser: (data: Partial<User>) => Promise<void>
  logout: () => void
}

export const useUserStore = create<UserState>((set, get) => ({
  user: null,
  isLoading: false,
  error: null,

  fetchUser: async (id: string) => {
    set({ isLoading: true, error: null })
    try {
      const response = await fetch(`/api/users/${id}`)
      if (!response.ok) throw new Error('Failed to fetch user')
      const user = await response.json()
      set({ user, isLoading: false })
    } catch (error) {
      set({ error: (error as Error).message, isLoading: false })
    }
  },

  updateUser: async (data: Partial<User>) => {
    const currentUser = get().user
    if (!currentUser) return

    set({ isLoading: true })
    try {
      const response = await fetch(`/api/users/${currentUser.id}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(data),
      })
      const updatedUser = await response.json()
      set({ user: updatedUser, isLoading: false })
    } catch (error) {
      set({ error: (error as Error).message, isLoading: false })
    }
  },

  logout: () => set({ user: null, error: null }),
}))
```

## Persist Middleware

```tsx
// stores/settings-store.ts
import { create } from 'zustand'
import { persist, createJSONStorage } from 'zustand/middleware'

interface SettingsState {
  theme: 'light' | 'dark' | 'system'
  language: string
  setTheme: (theme: 'light' | 'dark' | 'system') => void
  setLanguage: (language: string) => void
}

export const useSettingsStore = create<SettingsState>()(
  persist(
    (set) => ({
      theme: 'system',
      language: 'en',
      setTheme: (theme) => set({ theme }),
      setLanguage: (language) => set({ language }),
    }),
    {
      name: 'settings-storage', // localStorage key
      storage: createJSONStorage(() => localStorage),
      partialize: (state) => ({
        theme: state.theme,
        language: state.language,
      }), // Only persist specific fields
    }
  )
)
```

## Devtools Middleware

```tsx
import { create } from 'zustand'
import { devtools } from 'zustand/middleware'

export const useStore = create<State>()(
  devtools(
    (set) => ({
      // ... state and actions
    }),
    {
      name: 'MyStore', // Name shown in devtools
      enabled: process.env.NODE_ENV === 'development',
    }
  )
)
```

## Combining Middleware

```tsx
import { create } from 'zustand'
import { persist, devtools, subscribeWithSelector } from 'zustand/middleware'

export const useStore = create<State>()(
  devtools(
    persist(
      subscribeWithSelector(
        (set, get) => ({
          // ... state and actions
        })
      ),
      { name: 'storage-key' }
    ),
    { name: 'DevtoolsName' }
  )
)
```

## Store Slices Pattern

```tsx
// stores/slices/auth-slice.ts
import { StateCreator } from 'zustand'

export interface AuthSlice {
  user: User | null
  isAuthenticated: boolean
  login: (user: User) => void
  logout: () => void
}

export const createAuthSlice: StateCreator<AuthSlice> = (set) => ({
  user: null,
  isAuthenticated: false,
  login: (user) => set({ user, isAuthenticated: true }),
  logout: () => set({ user: null, isAuthenticated: false }),
})

// stores/slices/cart-slice.ts
export interface CartSlice {
  items: CartItem[]
  addItem: (item: CartItem) => void
  removeItem: (id: string) => void
  clearCart: () => void
}

export const createCartSlice: StateCreator<CartSlice> = (set) => ({
  items: [],
  addItem: (item) => set((state) => ({ items: [...state.items, item] })),
  removeItem: (id) => set((state) => ({
    items: state.items.filter((item) => item.id !== id),
  })),
  clearCart: () => set({ items: [] }),
})

// stores/index.ts - Combine slices
import { create } from 'zustand'
import { createAuthSlice, AuthSlice } from './slices/auth-slice'
import { createCartSlice, CartSlice } from './slices/cart-slice'

type StoreState = AuthSlice & CartSlice

export const useStore = create<StoreState>()((...args) => ({
  ...createAuthSlice(...args),
  ...createCartSlice(...args),
}))
```

## Computed Values (Derived State)

```tsx
// Use selectors for computed values
const useCartTotal = () =>
  useStore((state) =>
    state.items.reduce((total, item) => total + item.price * item.quantity, 0)
  )

// Usage
function CartSummary() {
  const total = useCartTotal()
  return <div>Total: ${total}</div>
}
```

## Subscribe to Changes

```tsx
import { useStore } from '@/stores'

// Subscribe outside React
const unsubscribe = useStore.subscribe(
  (state) => state.user,
  (user, previousUser) => {
    console.log('User changed:', previousUser, '->', user)
  }
)

// Using subscribeWithSelector middleware for granular subscriptions
useStore.subscribe(
  (state) => state.isAuthenticated,
  (isAuthenticated) => {
    if (!isAuthenticated) {
      // Redirect to login
      window.location.href = '/login'
    }
  }
)
```

## Reset Store

```tsx
const initialState = {
  count: 0,
  items: [],
}

interface StoreState {
  count: number
  items: Item[]
  increment: () => void
  reset: () => void
}

export const useStore = create<StoreState>((set) => ({
  ...initialState,
  increment: () => set((state) => ({ count: state.count + 1 })),
  reset: () => set(initialState),
}))
```

## TypeScript Patterns

```tsx
// Strict typing for actions
interface StoreActions {
  setUser: (user: User) => void
  updateUser: (updates: Partial<User>) => void
}

interface StoreState {
  user: User | null
}

type Store = StoreState & StoreActions

// Get state outside components
const user = useStore.getState().user

// Set state outside components
useStore.setState({ user: newUser })
```

## Zustand + TanStack Query

```tsx
// Use Zustand for UI state, TanStack Query for server state
// stores/ui-store.ts
export const useUIStore = create<UIState>((set) => ({
  sidebarOpen: true,
  selectedUserId: null,
  toggleSidebar: () => set((s) => ({ sidebarOpen: !s.sidebarOpen })),
  selectUser: (id) => set({ selectedUserId: id }),
}))

// Component combines both
function UserList() {
  // Server state from TanStack Query
  const { data: users } = useQuery({
    queryKey: ['users'],
    queryFn: fetchUsers,
  })

  // UI state from Zustand
  const selectedUserId = useUIStore((s) => s.selectedUserId)
  const selectUser = useUIStore((s) => s.selectUser)

  return (
    <ul>
      {users?.map((user) => (
        <li
          key={user.id}
          onClick={() => selectUser(user.id)}
          className={user.id === selectedUserId ? 'selected' : ''}
        >
          {user.name}
        </li>
      ))}
    </ul>
  )
}
```

## Integration with TanStack Query (Expanded)

### Clear Separation of Concerns

```typescript
// Zustand: UI/Client State ONLY
// - Modal open/close states
// - Sidebar expanded/collapsed
// - Active tab selection
// - Form step tracking
// - Local filters (before API call)

// TanStack Query: Server State ONLY
// - User data from API
// - List data from database
// - Mutations to server
// - Caching API responses
```

### Combining Filters (Zustand) with Data (TanStack Query)

```typescript
// stores/productFilterStore.ts
import { create } from 'zustand'

interface ProductFilterState {
  search: string
  category: string | null
  priceRange: [number, number]
  sortBy: 'price' | 'name' | 'date'
  setSearch: (search: string) => void
  setCategory: (category: string | null) => void
  setPriceRange: (range: [number, number]) => void
  setSortBy: (sort: 'price' | 'name' | 'date') => void
  resetFilters: () => void
}

const initialFilters = {
  search: '',
  category: null,
  priceRange: [0, 1000] as [number, number],
  sortBy: 'date' as const,
}

export const useProductFilterStore = create<ProductFilterState>((set) => ({
  ...initialFilters,
  setSearch: (search) => set({ search }),
  setCategory: (category) => set({ category }),
  setPriceRange: (priceRange) => set({ priceRange }),
  setSortBy: (sortBy) => set({ sortBy }),
  resetFilters: () => set(initialFilters),
}))

// hooks/useFilteredProducts.ts
import { useQuery } from '@tanstack/react-query'
import { useProductFilterStore } from '@/stores/productFilterStore'
import { useShallow } from 'zustand/react/shallow'

export function useFilteredProducts() {
  // Get filters from Zustand
  const filters = useProductFilterStore(
    useShallow((state) => ({
      search: state.search,
      category: state.category,
      priceRange: state.priceRange,
      sortBy: state.sortBy,
    }))
  )

  // Use filters as queryKey - auto-refetch when they change
  return useQuery({
    queryKey: ['products', filters],
    queryFn: () => fetchProducts(filters),
  })
}
```

### Optimistic Updates with Zustand Rollback

```typescript
// For UI state that affects display during mutation
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useUIStore } from '@/stores/uiStore'

export function useDeleteItem() {
  const queryClient = useQueryClient()
  const setDeleting = useUIStore((s) => s.setDeletingId)

  return useMutation({
    mutationFn: deleteItem,
    onMutate: (itemId) => {
      // Track in Zustand which item is being deleted (for UI)
      setDeleting(itemId)
    },
    onSettled: () => {
      // Clear deleting state regardless of success/failure
      setDeleting(null)
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['items'] })
    },
  })
}
```

## Best Practices

1. **Use selectors**: Always select specific state to prevent re-renders
2. **Keep stores focused**: One store per domain (auth, cart, UI)
3. **Use slices for large stores**: Split into manageable pieces
4. **Persist selectively**: Only persist what's needed
5. **Actions over direct set**: Encapsulate logic in actions
6. **Combine with TanStack Query**: Zustand for UI, Query for server state
7. **TypeScript**: Always define interfaces for state and actions
8. **Never duplicate server state**: If data comes from API, use TanStack Query
9. **Filters in Zustand, data in Query**: Clean separation of concerns
