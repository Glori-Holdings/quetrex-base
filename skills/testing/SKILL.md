---
name: testing
description: Testing patterns for Vitest, React Testing Library, and Playwright
context: fork
---

# Testing Skill

Reference for testing patterns in the stack: Vitest, React Testing Library, MSW, and Playwright.

## Project Setup

### Vitest Configuration

```typescript
// vitest.config.ts
import { defineConfig } from 'vitest/config'
import react from '@vitejs/plugin-react'
import path from 'path'

export default defineConfig({
  plugins: [react()],
  test: {
    environment: 'jsdom',
    globals: true,
    setupFiles: ['./tests/setup.ts'],
    include: ['**/*.{test,spec}.{js,mjs,cjs,ts,mts,cts,jsx,tsx}'],
    coverage: {
      provider: 'v8',
      reporter: ['text', 'json', 'html'],
      exclude: [
        'node_modules/',
        'tests/setup.ts',
        '**/*.d.ts',
        '**/*.config.*',
        '**/types/*',
      ],
    },
  },
  resolve: {
    alias: {
      '@': path.resolve(__dirname, './'),
    },
  },
})
```

### Test Setup File

```typescript
// tests/setup.ts
import '@testing-library/jest-dom/vitest'
import { cleanup } from '@testing-library/react'
import { afterEach, beforeAll, afterAll } from 'vitest'
import { server } from './mocks/server'

// Cleanup after each test
afterEach(() => {
  cleanup()
})

// MSW setup
beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => server.resetHandlers())
afterAll(() => server.close())
```

### Package Scripts

```json
{
  "scripts": {
    "test": "vitest",
    "test:run": "vitest run",
    "test:coverage": "vitest run --coverage",
    "test:ui": "vitest --ui",
    "test:e2e": "playwright test"
  }
}
```

## File Naming Conventions

| Type | Pattern | Location |
|------|---------|----------|
| Unit tests | `*.test.ts` | Same directory as source |
| Component tests | `*.test.tsx` | Same directory as component |
| API route tests | `route.test.ts` | Same directory as route |
| E2E tests | `*.spec.ts` | `tests/e2e/` |
| Integration tests | `*.integration.test.ts` | `tests/integration/` |

## Unit Testing

### Testing Utility Functions

```typescript
// lib/utils.test.ts
import { describe, it, expect } from 'vitest'
import { formatDate, slugify, truncate } from './utils'

describe('formatDate', () => {
  it('formats ISO date to readable format', () => {
    const result = formatDate('2024-01-15T10:30:00Z')
    expect(result).toBe('January 15, 2024')
  })

  it('handles invalid date gracefully', () => {
    expect(() => formatDate('invalid')).toThrow('Invalid date')
  })
})

describe('slugify', () => {
  it('converts string to lowercase slug', () => {
    expect(slugify('Hello World')).toBe('hello-world')
  })

  it('removes special characters', () => {
    expect(slugify('Hello! World?')).toBe('hello-world')
  })

  it('handles empty string', () => {
    expect(slugify('')).toBe('')
  })
})

describe('truncate', () => {
  it('truncates long strings with ellipsis', () => {
    const result = truncate('This is a very long string', 10)
    expect(result).toBe('This is a...')
  })

  it('returns original string if shorter than limit', () => {
    expect(truncate('Short', 10)).toBe('Short')
  })
})
```

### Testing with Mocks

```typescript
// lib/api.test.ts
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { fetchUser, createUser } from './api'

// Mock fetch globally
const mockFetch = vi.fn()
global.fetch = mockFetch

describe('fetchUser', () => {
  beforeEach(() => {
    mockFetch.mockReset()
  })

  it('returns user data on success', async () => {
    const mockUser = { id: '1', name: 'John' }
    mockFetch.mockResolvedValueOnce({
      ok: true,
      json: () => Promise.resolve(mockUser),
    })

    const result = await fetchUser('1')

    expect(mockFetch).toHaveBeenCalledWith('/api/users/1')
    expect(result).toEqual(mockUser)
  })

  it('throws error on failure', async () => {
    mockFetch.mockResolvedValueOnce({
      ok: false,
      status: 404,
    })

    await expect(fetchUser('999')).rejects.toThrow('User not found')
  })
})
```

## Component Testing with React Testing Library

### Basic Component Test

```typescript
// components/Button.test.tsx
import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { Button } from './Button'

describe('Button', () => {
  it('renders with text', () => {
    render(<Button>Click me</Button>)
    expect(screen.getByRole('button', { name: /click me/i })).toBeInTheDocument()
  })

  it('calls onClick when clicked', () => {
    const handleClick = vi.fn()
    render(<Button onClick={handleClick}>Click me</Button>)

    fireEvent.click(screen.getByRole('button'))

    expect(handleClick).toHaveBeenCalledTimes(1)
  })

  it('is disabled when disabled prop is true', () => {
    render(<Button disabled>Click me</Button>)
    expect(screen.getByRole('button')).toBeDisabled()
  })

  it('renders with correct variant styling', () => {
    render(<Button variant="destructive">Delete</Button>)
    const button = screen.getByRole('button')
    expect(button).toHaveClass('bg-destructive')
  })
})
```

### Testing Async Components

```typescript
// components/UserProfile.test.tsx
import { describe, it, expect } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import { UserProfile } from './UserProfile'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

function createWrapper() {
  const queryClient = new QueryClient({
    defaultOptions: {
      queries: { retry: false },
    },
  })
  return ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
  )
}

describe('UserProfile', () => {
  it('shows loading state initially', () => {
    render(<UserProfile userId="1" />, { wrapper: createWrapper() })
    expect(screen.getByText(/loading/i)).toBeInTheDocument()
  })

  it('displays user data after loading', async () => {
    render(<UserProfile userId="1" />, { wrapper: createWrapper() })

    await waitFor(() => {
      expect(screen.getByText('John Doe')).toBeInTheDocument()
    })
  })

  it('shows error message on failure', async () => {
    render(<UserProfile userId="999" />, { wrapper: createWrapper() })

    await waitFor(() => {
      expect(screen.getByText(/error/i)).toBeInTheDocument()
    })
  })
})
```

### Testing Forms

```typescript
// components/ContactForm.test.tsx
import { describe, it, expect, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { ContactForm } from './ContactForm'

describe('ContactForm', () => {
  it('submits form with valid data', async () => {
    const user = userEvent.setup()
    const handleSubmit = vi.fn()

    render(<ContactForm onSubmit={handleSubmit} />)

    await user.type(screen.getByLabelText(/name/i), 'John Doe')
    await user.type(screen.getByLabelText(/email/i), 'john@example.com')
    await user.type(screen.getByLabelText(/message/i), 'Hello!')
    await user.click(screen.getByRole('button', { name: /submit/i }))

    await waitFor(() => {
      expect(handleSubmit).toHaveBeenCalledWith({
        name: 'John Doe',
        email: 'john@example.com',
        message: 'Hello!',
      })
    })
  })

  it('shows validation errors for empty fields', async () => {
    const user = userEvent.setup()
    render(<ContactForm onSubmit={vi.fn()} />)

    await user.click(screen.getByRole('button', { name: /submit/i }))

    expect(screen.getByText(/name is required/i)).toBeInTheDocument()
    expect(screen.getByText(/email is required/i)).toBeInTheDocument()
  })

  it('shows error for invalid email', async () => {
    const user = userEvent.setup()
    render(<ContactForm onSubmit={vi.fn()} />)

    await user.type(screen.getByLabelText(/email/i), 'invalid-email')
    await user.click(screen.getByRole('button', { name: /submit/i }))

    expect(screen.getByText(/invalid email/i)).toBeInTheDocument()
  })
})
```

## Testing TanStack Query

### QueryClient Wrapper

```typescript
// tests/utils.tsx
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { render, RenderOptions } from '@testing-library/react'
import { ReactElement, ReactNode } from 'react'

function createTestQueryClient() {
  return new QueryClient({
    defaultOptions: {
      queries: {
        retry: false,
        gcTime: 0,
        staleTime: 0,
      },
      mutations: {
        retry: false,
      },
    },
  })
}

interface WrapperProps {
  children: ReactNode
}

function AllProviders({ children }: WrapperProps) {
  const queryClient = createTestQueryClient()
  return (
    <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
  )
}

function customRender(
  ui: ReactElement,
  options?: Omit<RenderOptions, 'wrapper'>
) {
  return render(ui, { wrapper: AllProviders, ...options })
}

export * from '@testing-library/react'
export { customRender as render }
```

### Testing Queries

```typescript
// hooks/useUsers.test.ts
import { describe, it, expect } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { useUsers } from './useUsers'
import { createWrapper } from '../tests/utils'

describe('useUsers', () => {
  it('fetches users successfully', async () => {
    const { result } = renderHook(() => useUsers(), {
      wrapper: createWrapper(),
    })

    expect(result.current.isLoading).toBe(true)

    await waitFor(() => {
      expect(result.current.isSuccess).toBe(true)
    })

    expect(result.current.data).toHaveLength(3)
    expect(result.current.data[0]).toHaveProperty('name')
  })
})
```

### Testing Mutations

```typescript
// hooks/useCreateUser.test.ts
import { describe, it, expect, vi } from 'vitest'
import { renderHook, waitFor, act } from '@testing-library/react'
import { useCreateUser } from './useCreateUser'
import { createWrapper } from '../tests/utils'

describe('useCreateUser', () => {
  it('creates user successfully', async () => {
    const { result } = renderHook(() => useCreateUser(), {
      wrapper: createWrapper(),
    })

    await act(async () => {
      result.current.mutate({ name: 'New User', email: 'new@example.com' })
    })

    await waitFor(() => {
      expect(result.current.isSuccess).toBe(true)
    })

    expect(result.current.data).toMatchObject({
      name: 'New User',
      email: 'new@example.com',
    })
  })
})
```

## Testing Zustand Stores

### Store Test Setup

```typescript
// stores/userStore.test.ts
import { describe, it, expect, beforeEach } from 'vitest'
import { useUserStore } from './userStore'

describe('userStore', () => {
  beforeEach(() => {
    // Reset store between tests
    useUserStore.setState({
      user: null,
      isAuthenticated: false,
    })
  })

  it('sets user on login', () => {
    const { login } = useUserStore.getState()

    login({ id: '1', name: 'John', email: 'john@example.com' })

    const state = useUserStore.getState()
    expect(state.user).toEqual({ id: '1', name: 'John', email: 'john@example.com' })
    expect(state.isAuthenticated).toBe(true)
  })

  it('clears user on logout', () => {
    // Setup: login first
    useUserStore.getState().login({ id: '1', name: 'John', email: 'john@example.com' })

    // Act
    useUserStore.getState().logout()

    // Assert
    const state = useUserStore.getState()
    expect(state.user).toBeNull()
    expect(state.isAuthenticated).toBe(false)
  })

  it('updates user preferences', () => {
    useUserStore.getState().login({ id: '1', name: 'John', email: 'john@example.com' })

    useUserStore.getState().updatePreferences({ theme: 'dark' })

    expect(useUserStore.getState().user?.preferences?.theme).toBe('dark')
  })
})
```

## Testing API Routes

### API Route Test Pattern

```typescript
// app/api/users/route.test.ts
import { describe, it, expect, beforeEach, vi } from 'vitest'
import { GET, POST } from './route'
import { NextRequest } from 'next/server'
import { db } from '@/lib/db'

// Mock the database
vi.mock('@/lib/db', () => ({
  db: {
    query: {
      users: {
        findMany: vi.fn(),
        findFirst: vi.fn(),
      },
    },
    insert: vi.fn(),
  },
}))

describe('GET /api/users', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('returns list of users', async () => {
    const mockUsers = [
      { id: '1', name: 'John' },
      { id: '2', name: 'Jane' },
    ]
    vi.mocked(db.query.users.findMany).mockResolvedValueOnce(mockUsers)

    const request = new NextRequest('http://localhost:3000/api/users')
    const response = await GET(request)
    const data = await response.json()

    expect(response.status).toBe(200)
    expect(data).toEqual(mockUsers)
  })

  it('handles query parameters', async () => {
    vi.mocked(db.query.users.findMany).mockResolvedValueOnce([])

    const request = new NextRequest('http://localhost:3000/api/users?limit=10')
    await GET(request)

    expect(db.query.users.findMany).toHaveBeenCalledWith(
      expect.objectContaining({ limit: 10 })
    )
  })
})

describe('POST /api/users', () => {
  it('creates a new user', async () => {
    const newUser = { name: 'New User', email: 'new@example.com' }
    vi.mocked(db.insert).mockReturnValueOnce({
      values: vi.fn().mockReturnValueOnce({
        returning: vi.fn().mockResolvedValueOnce([{ id: '3', ...newUser }]),
      }),
    } as any)

    const request = new NextRequest('http://localhost:3000/api/users', {
      method: 'POST',
      body: JSON.stringify(newUser),
    })

    const response = await POST(request)
    const data = await response.json()

    expect(response.status).toBe(201)
    expect(data).toMatchObject(newUser)
  })

  it('returns 400 for invalid data', async () => {
    const request = new NextRequest('http://localhost:3000/api/users', {
      method: 'POST',
      body: JSON.stringify({ name: '' }), // Invalid: missing email
    })

    const response = await POST(request)

    expect(response.status).toBe(400)
  })
})
```

## MSW for HTTP Mocking

### Setup MSW

```typescript
// tests/mocks/handlers.ts
import { http, HttpResponse } from 'msw'

export const handlers = [
  // Users endpoints
  http.get('/api/users', () => {
    return HttpResponse.json([
      { id: '1', name: 'John Doe', email: 'john@example.com' },
      { id: '2', name: 'Jane Doe', email: 'jane@example.com' },
    ])
  }),

  http.get('/api/users/:id', ({ params }) => {
    const { id } = params
    if (id === '999') {
      return new HttpResponse(null, { status: 404 })
    }
    return HttpResponse.json({
      id,
      name: 'John Doe',
      email: 'john@example.com',
    })
  }),

  http.post('/api/users', async ({ request }) => {
    const body = await request.json()
    return HttpResponse.json(
      { id: '3', ...body },
      { status: 201 }
    )
  }),
]

// tests/mocks/server.ts
import { setupServer } from 'msw/node'
import { handlers } from './handlers'

export const server = setupServer(...handlers)
```

### Using MSW in Tests

```typescript
// Override handlers for specific tests
import { server } from '../tests/mocks/server'
import { http, HttpResponse } from 'msw'

it('handles server error', async () => {
  server.use(
    http.get('/api/users', () => {
      return new HttpResponse(null, { status: 500 })
    })
  )

  render(<UserList />)

  await waitFor(() => {
    expect(screen.getByText(/error/i)).toBeInTheDocument()
  })
})
```

## Playwright E2E Testing

### Playwright Configuration

```typescript
// playwright.config.ts
import { defineConfig, devices } from '@playwright/test'

export default defineConfig({
  testDir: './tests/e2e',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 1 : undefined,
  reporter: 'html',
  use: {
    baseURL: 'http://localhost:3000',
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
  webServer: {
    command: 'npm run dev',
    url: 'http://localhost:3000',
    reuseExistingServer: !process.env.CI,
  },
})
```

### E2E Test Example

```typescript
// tests/e2e/auth.spec.ts
import { test, expect } from '@playwright/test'

test.describe('Authentication', () => {
  test('user can log in', async ({ page }) => {
    await page.goto('/login')

    await page.fill('[name="email"]', 'test@example.com')
    await page.fill('[name="password"]', 'password123')
    await page.click('button[type="submit"]')

    await expect(page).toHaveURL('/dashboard')
    await expect(page.getByText('Welcome back')).toBeVisible()
  })

  test('shows error for invalid credentials', async ({ page }) => {
    await page.goto('/login')

    await page.fill('[name="email"]', 'wrong@example.com')
    await page.fill('[name="password"]', 'wrongpassword')
    await page.click('button[type="submit"]')

    await expect(page.getByText('Invalid credentials')).toBeVisible()
    await expect(page).toHaveURL('/login')
  })

  test('user can log out', async ({ page }) => {
    // Login first
    await page.goto('/login')
    await page.fill('[name="email"]', 'test@example.com')
    await page.fill('[name="password"]', 'password123')
    await page.click('button[type="submit"]')
    await expect(page).toHaveURL('/dashboard')

    // Logout
    await page.click('button[aria-label="User menu"]')
    await page.click('text=Log out')

    await expect(page).toHaveURL('/login')
  })
})
```

### E2E Test for Forms

```typescript
// tests/e2e/contact-form.spec.ts
import { test, expect } from '@playwright/test'

test.describe('Contact Form', () => {
  test('submits form successfully', async ({ page }) => {
    await page.goto('/contact')

    await page.fill('[name="name"]', 'John Doe')
    await page.fill('[name="email"]', 'john@example.com')
    await page.fill('[name="message"]', 'Hello, this is a test message.')
    await page.click('button[type="submit"]')

    await expect(page.getByText('Message sent successfully')).toBeVisible()
  })

  test('validates required fields', async ({ page }) => {
    await page.goto('/contact')

    await page.click('button[type="submit"]')

    await expect(page.getByText('Name is required')).toBeVisible()
    await expect(page.getByText('Email is required')).toBeVisible()
  })
})
```

## Best Practices

1. **Arrange-Act-Assert** - Structure tests clearly
2. **One assertion focus** - Test one thing per test
3. **Descriptive names** - `it('shows error for invalid email')` not `it('test 1')`
4. **Avoid implementation details** - Test behavior, not internals
5. **Reset state** - Use `beforeEach` to ensure test isolation
6. **Mock external dependencies** - Database, APIs, etc.
7. **Use screen queries** - Prefer `getByRole` over `getByTestId`
8. **Test user interactions** - Use `userEvent` over `fireEvent`
9. **Coverage targets** - Aim for 80%+ on new code
10. **Fast tests** - Mock slow operations, avoid unnecessary waits
