---
name: design
description: Design thinking and aesthetic patterns for distinctive UI
context: fork
---

# Design Skill

Reference for creating distinctive, intentional UI designs. This skill unlocks creative potential and avoids generic AI aesthetics.

## Creative Unlocking Directive

> **Claude is capable of extraordinary creative work.** Don't hold back - show what can truly be created when thinking outside the box and committing fully to a distinctive vision.
>
> **CRITICAL:** Choose a clear conceptual direction and execute it with precision. Bold maximalism and refined minimalism both work - the key is **intentionality, not intensity**.

## Design Thinking Process

Before writing any code, commit to a BOLD aesthetic direction:

1. **Define the Mood** - What emotion should users feel?
2. **Choose an Aesthetic Direction** - Pick ONE and commit fully
3. **Select Typography** - NEVER use Inter, Roboto, or Arial
4. **Define Color Strategy** - Dominant + accent, not rainbow
5. **Plan Motion Philosophy** - Few high-impact moments vs. scattered micro-interactions
6. **Establish Spatial Composition** - Embrace asymmetry, overlap, negative space

## Aesthetic Directions

Choose ONE and execute with conviction:

### Brutalist
- Raw, unpolished aesthetic
- Harsh borders, monospace fonts
- High contrast, limited colors
- Intentionally "ugly" but memorable
- **Fonts:** JetBrains Mono, Space Mono, IBM Plex Mono
- **Colors:** Black, white, single accent (red, yellow)

### Maximalist
- Bold, layered, visually rich
- Multiple patterns, textures, gradients
- Dense information, many visual elements
- **Fonts:** Playfair Display, Bebas Neue, Anton
- **Colors:** Rich palette, deep saturation

### Retro-Futuristic
- 80s/90s meets sci-fi
- Neon colors, chrome effects
- Grid patterns, scanlines
- **Fonts:** Orbitron, Audiowide, Rajdhani
- **Colors:** Neon pink, cyan, purple on dark

### Luxury
- Elegant, refined, expensive feel
- Generous whitespace, subtle animations
- High-end photography, fine typography
- **Fonts:** Playfair Display, Cormorant, Didot
- **Colors:** Black, gold, cream, deep navy

### Playful
- Fun, approachable, energetic
- Rounded shapes, bouncy animations
- Bright colors, illustrated elements
- **Fonts:** Nunito, Quicksand, Fredoka One
- **Colors:** Bright primaries, pastels

### Editorial
- Magazine/newspaper inspired
- Strong typographic hierarchy
- Column layouts, pull quotes
- **Fonts:** Editorial New, Newsreader, Source Serif Pro
- **Colors:** Black, white, single accent

### Art Deco
- 1920s glamour, geometric patterns
- Gold accents, symmetrical layouts
- Ornate details, bold lines
- **Fonts:** Poiret One, Josefin Sans, Cinzel
- **Colors:** Gold, black, cream, emerald

### Organic/Natural
- Soft, flowing, nature-inspired
- Earthy tones, subtle gradients
- Rounded corners, leaf shapes
- **Fonts:** Lora, Crimson Text, Merriweather
- **Colors:** Forest green, terracotta, sand, sky blue

## Typography Rules

### NEVER Use These Fonts
- Inter (generic AI default)
- Roboto (overused)
- Arial/Helvetica (boring)
- Open Sans (forgettable)

### Font Pairing Strategies

**Contrast Pairing:** Serif heading + Sans body
```css
--font-heading: 'Playfair Display', serif;
--font-body: 'Source Sans Pro', sans-serif;
```

**Monospace Accent:** For technical/modern feel
```css
--font-heading: 'Space Grotesk', sans-serif;
--font-mono: 'JetBrains Mono', monospace;
```

**Display + Readable:** Bold display for impact
```css
--font-display: 'Bebas Neue', sans-serif;
--font-body: 'Nunito', sans-serif;
```

### Loading Custom Fonts

```tsx
// app/layout.tsx
import { Playfair_Display, Source_Sans_3 } from 'next/font/google'

const playfair = Playfair_Display({
  subsets: ['latin'],
  variable: '--font-heading',
  display: 'swap',
})

const sourceSans = Source_Sans_3({
  subsets: ['latin'],
  variable: '--font-body',
  display: 'swap',
})

export default function RootLayout({ children }) {
  return (
    <html className={`${playfair.variable} ${sourceSans.variable}`}>
      <body>{children}</body>
    </html>
  )
}
```

## Color Strategy

### CSS Variable System

```css
/* globals.css */
:root {
  /* Core palette */
  --color-background: 250 250 250;
  --color-foreground: 10 10 10;

  /* Brand colors */
  --color-primary: 220 80 60;       /* Dominant */
  --color-primary-hover: 200 70 50;
  --color-accent: 45 200 180;       /* Accent (use sparingly) */

  /* Semantic */
  --color-muted: 120 120 120;
  --color-border: 230 230 230;
  --color-surface: 255 255 255;

  /* Status */
  --color-success: 34 197 94;
  --color-warning: 250 204 21;
  --color-error: 239 68 68;
}

.dark {
  --color-background: 10 10 10;
  --color-foreground: 250 250 250;
  --color-surface: 20 20 20;
  --color-border: 40 40 40;
}
```

### Tailwind Integration

```typescript
// tailwind.config.ts
export default {
  theme: {
    extend: {
      colors: {
        background: 'rgb(var(--color-background) / <alpha-value>)',
        foreground: 'rgb(var(--color-foreground) / <alpha-value>)',
        primary: {
          DEFAULT: 'rgb(var(--color-primary) / <alpha-value>)',
          hover: 'rgb(var(--color-primary-hover) / <alpha-value>)',
        },
        accent: 'rgb(var(--color-accent) / <alpha-value>)',
        muted: 'rgb(var(--color-muted) / <alpha-value>)',
        surface: 'rgb(var(--color-surface) / <alpha-value>)',
      },
      fontFamily: {
        heading: ['var(--font-heading)', 'serif'],
        body: ['var(--font-body)', 'sans-serif'],
      },
    },
  },
}
```

## Motion Philosophy

### High-Impact Moments (Preferred)

Focus animation on KEY moments:
- Page transitions
- Modal open/close
- Important state changes
- Loading → content transitions

```tsx
// Good: Meaningful page transition
const pageVariants = {
  initial: { opacity: 0, y: 30 },
  enter: { opacity: 1, y: 0 },
  exit: { opacity: 0, y: -20 },
}

<motion.main
  variants={pageVariants}
  initial="initial"
  animate="enter"
  exit="exit"
  transition={{ duration: 0.4, ease: [0.22, 1, 0.36, 1] }}
>
  {children}
</motion.main>
```

### Avoid Scattered Micro-interactions

```tsx
// BAD: Everything bounces and wiggles
<motion.button whileHover={{ scale: 1.1 }} whileTap={{ scale: 0.9 }}>
<motion.icon animate={{ rotate: 360 }} transition={{ repeat: Infinity }}>
<motion.text initial={{ opacity: 0 }} animate={{ opacity: 1 }}>

// GOOD: Subtle, purposeful
<motion.button
  whileHover={{ backgroundColor: 'var(--color-primary-hover)' }}
  transition={{ duration: 0.2 }}
>
```

### Motion Recipes by Aesthetic

**Luxury:** Slow, smooth, minimal
```tsx
transition={{ duration: 0.6, ease: [0.22, 1, 0.36, 1] }}
```

**Playful:** Bouncy, quick
```tsx
transition={{ type: 'spring', stiffness: 400, damping: 15 }}
```

**Brutalist:** Instant or none
```tsx
transition={{ duration: 0 }}
// Or simply no animation at all
```

**Editorial:** Elegant reveals
```tsx
transition={{ duration: 0.5, ease: 'easeOut', staggerChildren: 0.1 }}
```

## Spatial Composition

### Embrace Asymmetry

```tsx
// Good: Intentional asymmetry
<div className="grid grid-cols-12 gap-6">
  <div className="col-span-7">
    <h1 className="text-6xl font-heading">Large Title</h1>
  </div>
  <div className="col-span-5 pt-12">
    <p className="text-lg text-muted">Supporting text offset</p>
  </div>
</div>
```

### Use Negative Space

```tsx
// Good: Generous breathing room
<section className="py-32 px-8">
  <div className="max-w-2xl mx-auto">
    <h2 className="text-4xl mb-8">Single focus</h2>
    <p className="text-xl leading-relaxed">
      Content with room to breathe creates premium feel.
    </p>
  </div>
</section>
```

### Overlap Elements

```tsx
// Good: Intentional overlap
<div className="relative">
  <div className="absolute -top-8 -left-8 w-64 h-64 bg-accent/20 rounded-full blur-3xl" />
  <div className="relative z-10 bg-surface p-8 rounded-lg shadow-lg">
    Card content
  </div>
</div>
```

## Visual Details

### Gradients (Use with Intention)

```tsx
// Subtle gradient background
<div className="bg-gradient-to-br from-background via-surface to-background">

// Bold gradient text
<span className="bg-gradient-to-r from-primary to-accent bg-clip-text text-transparent">
  Gradient Text
</span>

// Glass morphism (luxury/futuristic)
<div className="backdrop-blur-lg bg-white/10 border border-white/20 rounded-2xl">
```

### Shadows

```css
/* Tailwind: Soft, layered shadows */
.shadow-soft {
  box-shadow:
    0 2px 4px rgb(0 0 0 / 0.02),
    0 4px 8px rgb(0 0 0 / 0.04),
    0 8px 16px rgb(0 0 0 / 0.06);
}

/* Colored shadows */
.shadow-primary {
  box-shadow: 0 8px 30px rgb(var(--color-primary) / 0.3);
}
```

### Custom Cursors

```css
/* For interactive elements */
.cursor-custom {
  cursor: url('/cursors/pointer.svg'), pointer;
}

.cursor-grab {
  cursor: grab;
}

.cursor-grab:active {
  cursor: grabbing;
}
```

## ShadCN Component Customization

### Button Variants

```tsx
// components/ui/button.tsx customization
const buttonVariants = cva(
  'inline-flex items-center justify-center font-medium transition-colors',
  {
    variants: {
      variant: {
        default: 'bg-primary text-primary-foreground hover:bg-primary-hover',
        outline: 'border-2 border-primary text-primary hover:bg-primary/10',
        ghost: 'hover:bg-accent/10 text-foreground',
        brutalist: 'border-4 border-foreground bg-background hover:bg-foreground hover:text-background transition-none',
        luxury: 'bg-gradient-to-r from-amber-500 to-amber-600 text-white shadow-lg shadow-amber-500/30',
      },
      size: {
        sm: 'h-9 px-4 text-sm',
        default: 'h-11 px-6 text-base',
        lg: 'h-14 px-8 text-lg',
        xl: 'h-16 px-10 text-xl',
      },
    },
    defaultVariants: {
      variant: 'default',
      size: 'default',
    },
  }
)
```

### Card Variants

```tsx
// Different card styles by aesthetic
const cardVariants = {
  default: 'bg-surface rounded-lg border shadow-sm',
  brutalist: 'bg-background border-4 border-foreground',
  luxury: 'bg-surface rounded-2xl shadow-soft backdrop-blur-sm',
  playful: 'bg-surface rounded-3xl border-2 border-primary/20 shadow-xl',
}
```

## Framer Motion + ShadCN Patterns

### Animated Dialog

```tsx
"use client"

import { Dialog, DialogContent, DialogTrigger } from '@/components/ui/dialog'
import { motion, AnimatePresence } from 'framer-motion'

export function AnimatedDialog({ children, trigger }) {
  return (
    <Dialog>
      <DialogTrigger asChild>{trigger}</DialogTrigger>
      <AnimatePresence>
        <DialogContent asChild>
          <motion.div
            initial={{ opacity: 0, scale: 0.95, y: 10 }}
            animate={{ opacity: 1, scale: 1, y: 0 }}
            exit={{ opacity: 0, scale: 0.95, y: 10 }}
            transition={{ type: 'spring', damping: 25, stiffness: 300 }}
          >
            {children}
          </motion.div>
        </DialogContent>
      </AnimatePresence>
    </Dialog>
  )
}
```

### Animated List Items

```tsx
"use client"

import { motion } from 'framer-motion'

const listVariants = {
  hidden: { opacity: 0 },
  show: {
    opacity: 1,
    transition: { staggerChildren: 0.05 },
  },
}

const itemVariants = {
  hidden: { opacity: 0, x: -20 },
  show: { opacity: 1, x: 0 },
}

export function AnimatedList({ items }) {
  return (
    <motion.ul variants={listVariants} initial="hidden" animate="show">
      {items.map((item) => (
        <motion.li key={item.id} variants={itemVariants}>
          {item.content}
        </motion.li>
      ))}
    </motion.ul>
  )
}
```

## Anti-Patterns to Avoid

### Generic AI Aesthetics
- ❌ Blue gradient backgrounds with floating shapes
- ❌ Inter font everywhere
- ❌ Rounded everything with soft shadows
- ❌ Generic tech-startup look
- ❌ Overuse of primary color
- ❌ Same spacing everywhere (8, 16, 24 on repeat)

### Motion Crimes
- ❌ Everything animates on load
- ❌ Bouncing icons
- ❌ Rotating loaders on static content
- ❌ Delayed animations that block interaction
- ❌ Page transitions that take >500ms

### Layout Laziness
- ❌ Everything centered
- ❌ Equal column grids
- ❌ No visual hierarchy
- ❌ Same card size throughout
- ❌ Ignoring negative space

## Design System Output Format

When creating a design system for `.issue/design-system.md`:

```markdown
# Design System: [Feature Name]

## Aesthetic Direction
**Style:** [e.g., Luxury, Brutalist, Editorial]
**Mood:** [1-2 sentence description]
**Inspiration:** [References if any]

## Color Palette
| Name | Value | Usage |
|------|-------|-------|
| Primary | `#hex` / `rgb()` | Buttons, links |
| Accent | `#hex` / `rgb()` | Highlights, badges |
| Background | `#hex` / `rgb()` | Page background |
| Surface | `#hex` / `rgb()` | Cards, modals |

## Typography
| Role | Font | Weight | Size |
|------|------|--------|------|
| Display | [Font Name] | Bold | 4xl-6xl |
| Heading | [Font Name] | Semibold | 2xl-3xl |
| Body | [Font Name] | Normal | base-lg |
| Caption | [Font Name] | Normal | sm |

## Animation Strategy
- **Page Transitions:** [description]
- **Interactive Elements:** [description]
- **Loading States:** [description]

## Component Specifications

### [Component Name]
- **Variant:** [which ShadCN variant or custom]
- **Colors:** [specific colors]
- **Spacing:** [padding, margin]
- **Animation:** [Framer Motion config if any]

## Visual Hierarchy
[Description of how elements are prioritized visually]

## Notes for Developer
[Any specific implementation notes]
```

## Resources

- [Google Fonts](https://fonts.google.com) - Free fonts
- [Coolors](https://coolors.co) - Color palette generator
- [Realtime Colors](https://realtimecolors.com) - See colors in context
- [Cubic Bezier](https://cubic-bezier.com) - Easing visualization
