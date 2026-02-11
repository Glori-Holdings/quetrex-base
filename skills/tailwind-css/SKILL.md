---
name: tailwind-css
description: Tailwind CSS utility-first patterns and best practices
context: fork
---

# Tailwind CSS Patterns

Reference for Tailwind CSS utility-first styling.

## Core Concepts

### Utility-First
```tsx
// Instead of custom CSS, use utilities
<div className="flex items-center justify-between p-4 bg-white rounded-lg shadow-md">
  <h2 className="text-lg font-semibold text-gray-900">Title</h2>
  <button className="px-4 py-2 text-sm font-medium text-white bg-blue-600 rounded-md hover:bg-blue-700">
    Action
  </button>
</div>
```

## Responsive Design

| Breakpoint | Min Width | CSS |
|------------|-----------|-----|
| `sm:` | 640px | `@media (min-width: 640px)` |
| `md:` | 768px | `@media (min-width: 768px)` |
| `lg:` | 1024px | `@media (min-width: 1024px)` |
| `xl:` | 1280px | `@media (min-width: 1280px)` |
| `2xl:` | 1536px | `@media (min-width: 1536px)` |

```tsx
// Mobile-first: base styles, then breakpoint overrides
<div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
  {items.map(item => <Card key={item.id} />)}
</div>

// Stack on mobile, row on desktop
<div className="flex flex-col md:flex-row gap-4">
  <Sidebar />
  <Main />
</div>
```

## Flexbox & Grid

### Flexbox
```tsx
// Center content
<div className="flex items-center justify-center h-screen">
  <Content />
</div>

// Space between with gap
<div className="flex items-center justify-between gap-4">
  <Logo />
  <Nav />
  <UserMenu />
</div>

// Vertical stack
<div className="flex flex-col gap-2">
  <Item />
  <Item />
</div>
```

### Grid
```tsx
// Fixed columns
<div className="grid grid-cols-3 gap-4">
  <Card /><Card /><Card />
</div>

// Auto-fit responsive grid
<div className="grid grid-cols-[repeat(auto-fit,minmax(250px,1fr))] gap-4">
  {items.map(item => <Card key={item.id} />)}
</div>

// Named areas (with arbitrary values)
<div className="grid grid-cols-[200px_1fr] grid-rows-[auto_1fr_auto]">
  <Sidebar className="row-span-3" />
  <Header />
  <Main />
  <Footer />
</div>
```

## Dark Mode

```tsx
// Use dark: variant
<div className="bg-white dark:bg-gray-900 text-gray-900 dark:text-white">
  <h1 className="text-gray-900 dark:text-white">Title</h1>
  <p className="text-gray-600 dark:text-gray-400">Description</p>
</div>

// In tailwind.config.ts
export default {
  darkMode: 'class', // or 'media' for system preference
}
```

## Common Patterns

### Card
```tsx
<div className="rounded-lg border bg-card p-6 shadow-sm">
  <h3 className="text-lg font-semibold">Card Title</h3>
  <p className="text-muted-foreground mt-2">Card content goes here.</p>
</div>
```

### Button Variants
```tsx
// Primary
<button className="px-4 py-2 bg-primary text-primary-foreground rounded-md hover:bg-primary/90">
  Primary
</button>

// Secondary
<button className="px-4 py-2 bg-secondary text-secondary-foreground rounded-md hover:bg-secondary/80">
  Secondary
</button>

// Outline
<button className="px-4 py-2 border border-input bg-background hover:bg-accent rounded-md">
  Outline
</button>

// Ghost
<button className="px-4 py-2 hover:bg-accent hover:text-accent-foreground rounded-md">
  Ghost
</button>

// Destructive
<button className="px-4 py-2 bg-destructive text-destructive-foreground rounded-md hover:bg-destructive/90">
  Delete
</button>
```

### Form Input
```tsx
<input
  type="text"
  className="flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm ring-offset-background placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 disabled:cursor-not-allowed disabled:opacity-50"
  placeholder="Enter text..."
/>
```

### Avatar
```tsx
<div className="relative h-10 w-10 rounded-full overflow-hidden">
  <img src={avatarUrl} alt="User" className="h-full w-full object-cover" />
</div>

// With fallback
<div className="flex h-10 w-10 items-center justify-center rounded-full bg-muted">
  <span className="text-sm font-medium">JD</span>
</div>
```

## Spacing Scale

| Class | Size |
|-------|------|
| `p-1` | 4px (0.25rem) |
| `p-2` | 8px (0.5rem) |
| `p-3` | 12px (0.75rem) |
| `p-4` | 16px (1rem) |
| `p-6` | 24px (1.5rem) |
| `p-8` | 32px (2rem) |

```tsx
// Consistent spacing
<div className="space-y-4">
  <Section />
  <Section />
  <Section />
</div>

// Gap for flex/grid
<div className="flex gap-4">
  <Item />
  <Item />
</div>
```

## Typography

```tsx
// Headings
<h1 className="text-4xl font-bold tracking-tight">Heading 1</h1>
<h2 className="text-3xl font-semibold">Heading 2</h2>
<h3 className="text-2xl font-semibold">Heading 3</h3>

// Body text
<p className="text-base text-muted-foreground">Body text</p>
<p className="text-sm text-muted-foreground">Small text</p>

// Truncate
<p className="truncate">Very long text that will be truncated...</p>

// Line clamp
<p className="line-clamp-2">Text that spans multiple lines but is clamped to 2 lines...</p>
```

## Animation Classes

```tsx
// Transitions
<button className="transition-colors duration-200 hover:bg-accent">
  Hover me
</button>

// Transform on hover
<div className="transition-transform hover:scale-105">
  Scale on hover
</div>

// Spin animation
<div className="animate-spin h-5 w-5 border-2 border-current border-t-transparent rounded-full" />

// Pulse
<div className="animate-pulse bg-muted h-4 w-full rounded" />
```

## Custom Theme Extension

```typescript
// tailwind.config.ts
import type { Config } from 'tailwindcss'

export default {
  theme: {
    extend: {
      colors: {
        brand: {
          50: '#f0f9ff',
          500: '#3b82f6',
          900: '#1e3a8a',
        },
      },
      fontFamily: {
        sans: ['Inter', 'sans-serif'],
      },
      animation: {
        'fade-in': 'fadeIn 0.5s ease-in-out',
      },
      keyframes: {
        fadeIn: {
          '0%': { opacity: '0' },
          '100%': { opacity: '1' },
        },
      },
    },
  },
} satisfies Config
```

## Container Query (Modern)

```tsx
// Parent with @container
<div className="@container">
  <div className="@md:flex @md:items-center">
    {/* Responsive based on container, not viewport */}
  </div>
</div>
```

## Best Practices

1. **Mobile-first**: Start with base styles, add breakpoint variants
2. **Use design tokens**: Prefer `text-primary` over `text-blue-600`
3. **Consistent spacing**: Stick to the spacing scale (4, 8, 12, 16, 24, 32)
4. **Group related utilities**: Keep flex/grid utilities together
5. **Extract components**: When patterns repeat, create React components
