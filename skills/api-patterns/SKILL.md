---
name: api-patterns
description: API design patterns for Next.js 16 route handlers
context: fork
---

# API Patterns

Reference for building robust API routes in Next.js 16 with Zod validation, typed responses, and proper error handling.

## Route Handler Basics

```typescript
// app/api/users/route.ts
import { NextRequest, NextResponse } from 'next/server'

export async function GET(request: NextRequest) {
  return NextResponse.json({ data: [] })
}

export async function POST(request: NextRequest) {
  const body = await request.json()
  return NextResponse.json({ success: true }, { status: 201 })
}
```

## Zod Schema Validation

### Define Schemas

```typescript
// lib/validations/user.ts
import { z } from 'zod'

export const createUserSchema = z.object({
  name: z.string().min(1, 'Name is required').max(100),
  email: z.string().email('Invalid email address'),
  role: z.enum(['user', 'admin', 'moderator']).default('user'),
  metadata: z.record(z.unknown()).optional(),
})

export const updateUserSchema = createUserSchema.partial()

export const userIdSchema = z.object({
  id: z.string().uuid('Invalid user ID'),
})

// Infer TypeScript types from schemas
export type CreateUserInput = z.infer<typeof createUserSchema>
export type UpdateUserInput = z.infer<typeof updateUserSchema>
```

### Validate in Route Handler

```typescript
// app/api/users/route.ts
import { NextRequest, NextResponse } from 'next/server'
import { createUserSchema } from '@/lib/validations/user'
import { db } from '@/lib/db'
import { users } from '@/lib/db/schema'

export async function POST(request: NextRequest) {
  try {
    // Parse and validate
    const body = await request.json()
    const result = createUserSchema.safeParse(body)

    if (!result.success) {
      return NextResponse.json(
        {
          error: 'Validation failed',
          details: result.error.flatten().fieldErrors,
        },
        { status: 400 }
      )
    }

    // Use validated data
    const [user] = await db
      .insert(users)
      .values(result.data)
      .returning()

    return NextResponse.json(user, { status: 201 })
  } catch (error) {
    return NextResponse.json(
      { error: 'Internal server error' },
      { status: 500 }
    )
  }
}
```

## Typed Error Responses

### Error Types

```typescript
// lib/api/errors.ts
export class ApiError extends Error {
  constructor(
    public statusCode: number,
    message: string,
    public code?: string,
    public details?: unknown
  ) {
    super(message)
    this.name = 'ApiError'
  }
}

export class ValidationError extends ApiError {
  constructor(details: Record<string, string[]>) {
    super(400, 'Validation failed', 'VALIDATION_ERROR', details)
  }
}

export class NotFoundError extends ApiError {
  constructor(resource: string) {
    super(404, `${resource} not found`, 'NOT_FOUND')
  }
}

export class UnauthorizedError extends ApiError {
  constructor(message = 'Unauthorized') {
    super(401, message, 'UNAUTHORIZED')
  }
}

export class ForbiddenError extends ApiError {
  constructor(message = 'Forbidden') {
    super(403, message, 'FORBIDDEN')
  }
}

export class ConflictError extends ApiError {
  constructor(message: string) {
    super(409, message, 'CONFLICT')
  }
}

export class RateLimitError extends ApiError {
  constructor(retryAfter?: number) {
    super(429, 'Rate limit exceeded', 'RATE_LIMIT', { retryAfter })
  }
}
```

### Error Handler

```typescript
// lib/api/handler.ts
import { NextRequest, NextResponse } from 'next/server'
import { ApiError } from './errors'
import { ZodError } from 'zod'

type RouteHandler = (request: NextRequest, context?: unknown) => Promise<Response>

export function withErrorHandler(handler: RouteHandler): RouteHandler {
  return async (request, context) => {
    try {
      return await handler(request, context)
    } catch (error) {
      console.error('API Error:', error)

      if (error instanceof ApiError) {
        return NextResponse.json(
          {
            error: error.message,
            code: error.code,
            details: error.details,
          },
          { status: error.statusCode }
        )
      }

      if (error instanceof ZodError) {
        return NextResponse.json(
          {
            error: 'Validation failed',
            code: 'VALIDATION_ERROR',
            details: error.flatten().fieldErrors,
          },
          { status: 400 }
        )
      }

      return NextResponse.json(
        { error: 'Internal server error', code: 'INTERNAL_ERROR' },
        { status: 500 }
      )
    }
  }
}
```

### Usage with Error Handler

```typescript
// app/api/users/[id]/route.ts
import { NextRequest, NextResponse } from 'next/server'
import { withErrorHandler } from '@/lib/api/handler'
import { NotFoundError } from '@/lib/api/errors'
import { db } from '@/lib/db'
import { users } from '@/lib/db/schema'
import { eq } from 'drizzle-orm'

export const GET = withErrorHandler(
  async (request: NextRequest, { params }: { params: Promise<{ id: string }> }) => {
    const { id } = await params

    const user = await db.query.users.findFirst({
      where: eq(users.id, id),
    })

    if (!user) {
      throw new NotFoundError('User')
    }

    return NextResponse.json(user)
  }
)
```

## Rate Limiting Integration

```typescript
// lib/api/rate-limit.ts
import { ratelimit } from '@/lib/rate-limit'
import { RateLimitError } from './errors'
import { NextRequest } from 'next/server'

export async function checkRateLimit(request: NextRequest, identifier?: string) {
  const ip = identifier ?? request.headers.get('x-forwarded-for') ?? 'anonymous'
  const { success, limit, remaining, reset } = await ratelimit.limit(ip)

  if (!success) {
    const retryAfter = Math.ceil((reset - Date.now()) / 1000)
    throw new RateLimitError(retryAfter)
  }

  return { limit, remaining, reset }
}

// Usage in route
export const POST = withErrorHandler(async (request) => {
  await checkRateLimit(request)

  // Process request...
})
```

## Authentication Middleware

```typescript
// lib/api/auth.ts
import { getServerSession } from 'next-auth'
import { authOptions } from '@/lib/auth'
import { UnauthorizedError, ForbiddenError } from './errors'

export async function requireAuth() {
  const session = await getServerSession(authOptions)

  if (!session?.user) {
    throw new UnauthorizedError()
  }

  return session
}

export async function requireRole(allowedRoles: string[]) {
  const session = await requireAuth()

  if (!allowedRoles.includes(session.user.role)) {
    throw new ForbiddenError('Insufficient permissions')
  }

  return session
}

// Usage
export const POST = withErrorHandler(async (request) => {
  const session = await requireRole(['admin'])

  // Admin-only logic...
})
```

## Response Helpers

```typescript
// lib/api/response.ts
import { NextResponse } from 'next/server'

export function success<T>(data: T, status = 200) {
  return NextResponse.json(data, { status })
}

export function created<T>(data: T) {
  return NextResponse.json(data, { status: 201 })
}

export function noContent() {
  return new NextResponse(null, { status: 204 })
}

export function paginated<T>(
  data: T[],
  pagination: { page: number; limit: number; total: number }
) {
  return NextResponse.json({
    data,
    pagination: {
      ...pagination,
      pages: Math.ceil(pagination.total / pagination.limit),
      hasMore: pagination.page * pagination.limit < pagination.total,
    },
  })
}

// Usage
export const GET = withErrorHandler(async (request) => {
  const users = await db.query.users.findMany()
  return success(users)
})

export const DELETE = withErrorHandler(async (request, { params }) => {
  const { id } = await params
  await db.delete(users).where(eq(users.id, id))
  return noContent()
})
```

## Query Parameters

```typescript
// lib/api/params.ts
import { z } from 'zod'
import { NextRequest } from 'next/server'

export const paginationSchema = z.object({
  page: z.coerce.number().min(1).default(1),
  limit: z.coerce.number().min(1).max(100).default(20),
  sort: z.enum(['asc', 'desc']).default('desc'),
  sortBy: z.string().optional(),
})

export function parseSearchParams<T extends z.ZodType>(
  request: NextRequest,
  schema: T
): z.infer<T> {
  const searchParams = Object.fromEntries(request.nextUrl.searchParams)
  return schema.parse(searchParams)
}

// Usage
export const GET = withErrorHandler(async (request) => {
  const { page, limit, sort, sortBy } = parseSearchParams(
    request,
    paginationSchema.extend({
      search: z.string().optional(),
      status: z.enum(['active', 'inactive']).optional(),
    })
  )

  const users = await db.query.users.findMany({
    limit,
    offset: (page - 1) * limit,
    orderBy: sortBy ? (sort === 'asc' ? asc(users[sortBy]) : desc(users[sortBy])) : undefined,
  })

  const total = await db.select({ count: count() }).from(users)

  return paginated(users, { page, limit, total: total[0].count })
})
```

## File Structure

```
app/
└── api/
    └── users/
        ├── route.ts              # GET (list), POST (create)
        └── [id]/
            └── route.ts          # GET (one), PATCH (update), DELETE

lib/
├── api/
│   ├── errors.ts                 # Error classes
│   ├── handler.ts                # Error handler wrapper
│   ├── auth.ts                   # Auth helpers
│   ├── rate-limit.ts            # Rate limiting
│   ├── response.ts              # Response helpers
│   └── params.ts                # Query param parsing
└── validations/
    ├── user.ts                   # User schemas
    ├── post.ts                   # Post schemas
    └── common.ts                 # Shared schemas
```

## Complete Example

```typescript
// app/api/users/route.ts
import { NextRequest } from 'next/server'
import { withErrorHandler } from '@/lib/api/handler'
import { success, created, paginated } from '@/lib/api/response'
import { parseSearchParams, paginationSchema } from '@/lib/api/params'
import { checkRateLimit } from '@/lib/api/rate-limit'
import { requireAuth } from '@/lib/api/auth'
import { createUserSchema } from '@/lib/validations/user'
import { db } from '@/lib/db'
import { users } from '@/lib/db/schema'
import { revalidateTag } from 'next/cache'

const listUsersSchema = paginationSchema.extend({
  search: z.string().optional(),
  role: z.enum(['user', 'admin', 'moderator']).optional(),
})

export const GET = withErrorHandler(async (request: NextRequest) => {
  const { page, limit, search, role } = parseSearchParams(request, listUsersSchema)

  const where = and(
    search ? like(users.name, `%${search}%`) : undefined,
    role ? eq(users.role, role) : undefined
  )

  const [data, countResult] = await Promise.all([
    db.query.users.findMany({
      where,
      limit,
      offset: (page - 1) * limit,
      orderBy: desc(users.createdAt),
    }),
    db.select({ count: count() }).from(users).where(where),
  ])

  return paginated(data, { page, limit, total: countResult[0].count })
})

export const POST = withErrorHandler(async (request: NextRequest) => {
  await requireAuth()
  await checkRateLimit(request)

  const body = await request.json()
  const data = createUserSchema.parse(body)

  const [user] = await db.insert(users).values(data).returning()

  revalidateTag('users')

  return created(user)
})
```

## Best Practices

1. **Validate all input**: Use Zod for body, params, and query strings
2. **Typed errors**: Use custom error classes with codes
3. **Wrap handlers**: Use `withErrorHandler` for consistent error responses
4. **Rate limit sensitive endpoints**: Protect mutations and auth endpoints
5. **Use response helpers**: Consistent response format
6. **Invalidate caches**: Call `revalidateTag` after mutations
7. **Authenticate early**: Check auth before processing request
8. **Log errors**: Add logging in error handler for debugging
9. **Return appropriate status codes**: 201 for create, 204 for delete
10. **Document with TypeScript**: Infer types from Zod schemas
