---
name: drizzle-postgres
description: Drizzle ORM patterns for PostgreSQL databases
context: fork
---

# Drizzle ORM Patterns

Reference for Drizzle ORM with PostgreSQL.

## Schema Definition

```typescript
import { pgTable, uuid, text, timestamp, boolean, integer } from 'drizzle-orm/pg-core'

export const users = pgTable('users', {
  id: uuid('id').defaultRandom().primaryKey(),
  email: text('email').notNull().unique(),
  name: text('name').notNull(),
  role: text('role').notNull().default('user'),
  isActive: boolean('is_active').notNull().default(true),
  createdAt: timestamp('created_at').defaultNow().notNull(),
  updatedAt: timestamp('updated_at').defaultNow().notNull(),
})

// Export types for TypeScript
export type User = typeof users.$inferSelect
export type NewUser = typeof users.$inferInsert
```

## Naming Convention

**Database (snake_case):**
- Table: `user_preferences`
- Column: `created_at`, `user_id`

**TypeScript (camelCase):**
- Variable: `userId`, `createdAt`

**Mapping:**
```typescript
// camelCase property maps to snake_case column
userId: uuid('user_id')
createdAt: timestamp('created_at')
isActive: boolean('is_active')
```

## Column Types

```typescript
import {
  uuid,
  text,
  varchar,
  integer,
  bigint,
  boolean,
  timestamp,
  date,
  json,
  jsonb,
  decimal,
  real,
  doublePrecision,
} from 'drizzle-orm/pg-core'

// Common columns
id: uuid('id').defaultRandom().primaryKey()
name: text('name').notNull()
email: varchar('email', { length: 255 }).notNull()
age: integer('age')
balance: decimal('balance', { precision: 10, scale: 2 })
isVerified: boolean('is_verified').default(false)
metadata: jsonb('metadata').$type<Record<string, unknown>>()
createdAt: timestamp('created_at').defaultNow()
birthDate: date('birth_date')
```

## Relationships

### One-to-Many
```typescript
// Parent
export const agencies = pgTable('agencies', {
  id: uuid('id').defaultRandom().primaryKey(),
  name: text('name').notNull(),
})

// Child with foreign key
export const users = pgTable('users', {
  id: uuid('id').defaultRandom().primaryKey(),
  agencyId: uuid('agency_id')
    .references(() => agencies.id)
    .notNull(),
})
```

### Many-to-Many
```typescript
// Junction table
export const userRoles = pgTable('user_roles', {
  userId: uuid('user_id')
    .references(() => users.id)
    .notNull(),
  roleId: uuid('role_id')
    .references(() => roles.id)
    .notNull(),
}, (table) => ({
  pk: primaryKey({ columns: [table.userId, table.roleId] }),
}))
```

## Queries

### Select
```typescript
import { db } from '@/lib/db'
import { users } from '@/lib/db/schema'
import { eq, and, or, like, desc, asc } from 'drizzle-orm'

// Simple select
const allUsers = await db.select().from(users)

// With where clause
const activeUsers = await db
  .select()
  .from(users)
  .where(eq(users.isActive, true))

// Multiple conditions
const results = await db
  .select()
  .from(users)
  .where(
    and(
      eq(users.role, 'admin'),
      eq(users.isActive, true)
    )
  )

// Ordering and limiting
const recentUsers = await db
  .select()
  .from(users)
  .orderBy(desc(users.createdAt))
  .limit(10)

// Select specific columns
const userNames = await db
  .select({ id: users.id, name: users.name })
  .from(users)
```

### Insert
```typescript
// Single insert
const newUser = await db
  .insert(users)
  .values({
    email: 'user@example.com',
    name: 'John Doe',
  })
  .returning()

// Multiple inserts
await db.insert(users).values([
  { email: 'a@example.com', name: 'User A' },
  { email: 'b@example.com', name: 'User B' },
])
```

### Update
```typescript
await db
  .update(users)
  .set({
    name: 'Updated Name',
    updatedAt: new Date(),
  })
  .where(eq(users.id, userId))
```

### Delete
```typescript
await db
  .delete(users)
  .where(eq(users.id, userId))
```

## Joins

```typescript
import { users, agencies } from '@/lib/db/schema'

const usersWithAgency = await db
  .select({
    userId: users.id,
    userName: users.name,
    agencyName: agencies.name,
  })
  .from(users)
  .leftJoin(agencies, eq(users.agencyId, agencies.id))
```

## Transactions

```typescript
await db.transaction(async (tx) => {
  const [user] = await tx
    .insert(users)
    .values({ email, name })
    .returning()

  await tx
    .insert(userRoles)
    .values({ userId: user.id, roleId: defaultRole })
})
```

## Migrations

### Generate Migration
```bash
npx drizzle-kit generate
```

### Push to Database (Development)
```bash
npx drizzle-kit push
```

### Run Migrations (Production)
```bash
npx drizzle-kit migrate
```

### Drizzle Config
```typescript
// drizzle.config.ts
import { defineConfig } from 'drizzle-kit'

export default defineConfig({
  schema: './lib/db/schema.ts',
  out: './drizzle',
  dialect: 'postgresql',
  dbCredentials: {
    url: process.env.DATABASE_URL!,
  },
})
```

## Common Patterns

### Soft Delete
```typescript
export const items = pgTable('items', {
  id: uuid('id').defaultRandom().primaryKey(),
  deletedAt: timestamp('deleted_at'),
})

// Query only non-deleted
const activeItems = await db
  .select()
  .from(items)
  .where(isNull(items.deletedAt))
```

### Timestamps
```typescript
// Always include these in tables
createdAt: timestamp('created_at').defaultNow().notNull(),
updatedAt: timestamp('updated_at').defaultNow().notNull(),

// Update updatedAt on change
await db
  .update(table)
  .set({ ...data, updatedAt: new Date() })
  .where(eq(table.id, id))
```

### UUID Primary Keys
```typescript
// Always use UUID for primary keys
id: uuid('id').defaultRandom().primaryKey()
```

## Integration with Next.js 16 Cache

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
```

### Cache Invalidation on Mutation

```typescript
// app/api/users/route.ts
import { revalidateTag } from 'next/cache'
import { db } from '@/lib/db'
import { users } from '@/lib/db/schema'

export async function POST(request: Request) {
  const body = await request.json()

  // Insert to database
  const [user] = await db.insert(users).values(body).returning()

  // Invalidate cache
  revalidateTag('users')

  return Response.json(user, { status: 201 })
}

export async function PATCH(request: Request) {
  const body = await request.json()
  const { id, ...data } = body

  const [user] = await db
    .update(users)
    .set({ ...data, updatedAt: new Date() })
    .where(eq(users.id, id))
    .returning()

  // Invalidate both list and specific user
  revalidateTag('users')
  revalidateTag(`user-${id}`)

  return Response.json(user)
}
```

## Type Exports for Frontend

```typescript
// lib/db/schema.ts
export const users = pgTable('users', {
  id: uuid('id').defaultRandom().primaryKey(),
  name: text('name').notNull(),
  email: text('email').notNull().unique(),
  role: text('role').notNull().default('user'),
  createdAt: timestamp('created_at').defaultNow().notNull(),
})

// Export types for use throughout the app
export type User = typeof users.$inferSelect
export type NewUser = typeof users.$inferInsert

// Use in components
import type { User } from '@/lib/db/schema'

function UserCard({ user }: { user: User }) {
  return <div>{user.name}</div>
}
```

## Integration with Upstash Redis

```typescript
// Multi-layer caching: Next.js + Redis + Database
import { db } from '@/lib/db'
import { redis } from '@/lib/redis'
import { revalidateTag } from 'next/cache'

export async function getExpensiveReport(orgId: string) {
  "use cache"
  cacheLife('hours')
  cacheTag('reports', `report-${orgId}`)

  // Check Redis for pre-computed result
  const cached = await redis.get<Report>(`report:${orgId}`)
  if (cached) return cached

  // Expensive database operation
  const report = await computeReportFromDb(orgId)

  // Store in Redis for other server instances
  await redis.set(`report:${orgId}`, report, { ex: 3600 })

  return report
}

// Invalidate all layers on change
export async function invalidateReport(orgId: string) {
  await redis.del(`report:${orgId}`)
  revalidateTag(`report-${orgId}`)
}
