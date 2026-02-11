---
name: typescript-strict
description: TypeScript strict mode patterns and best practices
context: fork
---

# TypeScript Strict Patterns

Reference for writing type-safe TypeScript code.

## ABSOLUTE RULE: NO `any` TYPES

```typescript
// NEVER do this
const data: any = fetchData()
function process(input: any) { }

// ALWAYS define types
interface UserData {
  id: string
  name: string
}
const data: UserData = fetchData()
function process(input: UserData) { }
```

**If you truly don't know the type, use `unknown`:**
```typescript
// unknown requires type checking before use
function handleResponse(data: unknown) {
  if (typeof data === 'string') {
    console.log(data.toUpperCase()) // OK - type narrowed
  }
}
```

## Type Guards

```typescript
// Type predicate
function isUser(obj: unknown): obj is User {
  return (
    typeof obj === 'object' &&
    obj !== null &&
    'id' in obj &&
    'name' in obj
  )
}

// Usage
if (isUser(data)) {
  console.log(data.name) // TypeScript knows it's User
}
```

## Utility Types

```typescript
// Partial - all properties optional
type PartialUser = Partial<User>

// Required - all properties required
type RequiredUser = Required<User>

// Pick - select specific properties
type UserName = Pick<User, 'name'>

// Omit - exclude specific properties
type UserWithoutId = Omit<User, 'id'>

// Record - key-value mapping
type UserMap = Record<string, User>

// Readonly - immutable properties
type ReadonlyUser = Readonly<User>
```

## Generics

```typescript
// Generic function
function firstElement<T>(arr: T[]): T | undefined {
  return arr[0]
}

// Generic with constraint
function getProperty<T, K extends keyof T>(obj: T, key: K): T[K] {
  return obj[key]
}

// Generic interface
interface ApiResponse<T> {
  data: T
  status: number
  message: string
}
```

## Discriminated Unions

```typescript
// Use a common property to discriminate
type Result<T> =
  | { success: true; data: T }
  | { success: false; error: string }

function handleResult<T>(result: Result<T>) {
  if (result.success) {
    console.log(result.data) // TypeScript knows data exists
  } else {
    console.log(result.error) // TypeScript knows error exists
  }
}
```

## Null Handling

```typescript
// Optional chaining
const name = user?.profile?.name

// Nullish coalescing
const displayName = user.name ?? 'Anonymous'

// Non-null assertion (use sparingly)
const element = document.getElementById('app')!

// Type narrowing
function processName(name: string | null) {
  if (name === null) {
    return 'Anonymous'
  }
  return name.toUpperCase() // TypeScript knows it's string
}
```

## Async Types

```typescript
// Async function return type
async function fetchUser(id: string): Promise<User> {
  const response = await fetch(`/api/users/${id}`)
  return response.json()
}

// Awaited type (unwrap Promise)
type UserResult = Awaited<ReturnType<typeof fetchUser>>
```

## React Component Types

```typescript
// Props interface
interface ButtonProps {
  label: string
  onClick: () => void
  disabled?: boolean
}

// Functional component
function Button({ label, onClick, disabled = false }: ButtonProps) {
  return (
    <button onClick={onClick} disabled={disabled}>
      {label}
    </button>
  )
}

// With children
interface CardProps {
  title: string
  children: React.ReactNode
}

// Event handlers
function handleClick(event: React.MouseEvent<HTMLButtonElement>) { }
function handleChange(event: React.ChangeEvent<HTMLInputElement>) { }
```

## Common Patterns

### Exhaustive Switch
```typescript
type Status = 'pending' | 'active' | 'completed'

function handleStatus(status: Status): string {
  switch (status) {
    case 'pending':
      return 'Waiting...'
    case 'active':
      return 'In progress'
    case 'completed':
      return 'Done!'
    default:
      // This ensures all cases are handled
      const _exhaustive: never = status
      return _exhaustive
  }
}
```

### Const Assertions
```typescript
// Without as const
const config = { timeout: 1000 } // { timeout: number }

// With as const
const config = { timeout: 1000 } as const // { readonly timeout: 1000 }

// For arrays
const statuses = ['pending', 'active'] as const
type Status = typeof statuses[number] // 'pending' | 'active'
```

### Index Signatures
```typescript
interface StringMap {
  [key: string]: string
}

// With specific keys
interface UserRecord {
  id: string
  name: string
  [key: string]: string // Additional properties allowed
}
```
