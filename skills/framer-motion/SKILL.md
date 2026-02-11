---
name: framer-motion
description: Framer Motion animation patterns and best practices
context: fork
---

# Framer Motion Patterns

Reference for animations with Framer Motion in React.

## Basic Animation

```tsx
"use client"

import { motion } from 'framer-motion'

// Simple animation
<motion.div
  initial={{ opacity: 0, y: 20 }}
  animate={{ opacity: 1, y: 0 }}
  transition={{ duration: 0.5 }}
>
  Content fades in and slides up
</motion.div>
```

## Variants Pattern

```tsx
"use client"

import { motion } from 'framer-motion'

// Define variants outside component
const containerVariants = {
  hidden: { opacity: 0 },
  visible: {
    opacity: 1,
    transition: {
      staggerChildren: 0.1,
    },
  },
}

const itemVariants = {
  hidden: { opacity: 0, y: 20 },
  visible: {
    opacity: 1,
    y: 0,
    transition: { duration: 0.3 },
  },
}

export function AnimatedList({ items }) {
  return (
    <motion.ul
      variants={containerVariants}
      initial="hidden"
      animate="visible"
    >
      {items.map((item) => (
        <motion.li key={item.id} variants={itemVariants}>
          {item.name}
        </motion.li>
      ))}
    </motion.ul>
  )
}
```

## Page Transitions

```tsx
"use client"

import { motion, AnimatePresence } from 'framer-motion'

const pageVariants = {
  initial: { opacity: 0, x: -20 },
  animate: { opacity: 1, x: 0 },
  exit: { opacity: 0, x: 20 },
}

// Wrap page content
export function PageWrapper({ children }) {
  return (
    <motion.div
      variants={pageVariants}
      initial="initial"
      animate="animate"
      exit="exit"
      transition={{ duration: 0.3 }}
    >
      {children}
    </motion.div>
  )
}
```

## AnimatePresence (Exit Animations)

```tsx
"use client"

import { motion, AnimatePresence } from 'framer-motion'
import { useState } from 'react'

export function ToggleContent() {
  const [isVisible, setIsVisible] = useState(true)

  return (
    <>
      <button onClick={() => setIsVisible(!isVisible)}>Toggle</button>

      <AnimatePresence mode="wait">
        {isVisible && (
          <motion.div
            key="content"
            initial={{ opacity: 0, height: 0 }}
            animate={{ opacity: 1, height: 'auto' }}
            exit={{ opacity: 0, height: 0 }}
            transition={{ duration: 0.3 }}
          >
            Content that animates in and out
          </motion.div>
        )}
      </AnimatePresence>
    </>
  )
}
```

## Gesture Animations

### Hover & Tap

```tsx
<motion.button
  whileHover={{ scale: 1.05 }}
  whileTap={{ scale: 0.95 }}
  transition={{ type: 'spring', stiffness: 400, damping: 17 }}
>
  Interactive Button
</motion.button>
```

### Drag

```tsx
<motion.div
  drag
  dragConstraints={{ left: 0, right: 300, top: 0, bottom: 300 }}
  dragElastic={0.2}
  whileDrag={{ scale: 1.1 }}
>
  Drag me
</motion.div>
```

## Layout Animations

```tsx
"use client"

import { motion } from 'framer-motion'
import { useState } from 'react'

export function ExpandableCard() {
  const [isExpanded, setIsExpanded] = useState(false)

  return (
    <motion.div
      layout
      onClick={() => setIsExpanded(!isExpanded)}
      style={{
        width: isExpanded ? 400 : 200,
        height: isExpanded ? 300 : 100,
      }}
      transition={{ layout: { duration: 0.3 } }}
    >
      <motion.h2 layout="position">Title</motion.h2>
      {isExpanded && (
        <motion.p
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          transition={{ delay: 0.2 }}
        >
          Expanded content
        </motion.p>
      )}
    </motion.div>
  )
}
```

## Scroll Animations

### On Scroll Into View

```tsx
"use client"

import { motion } from 'framer-motion'

export function ScrollReveal({ children }) {
  return (
    <motion.div
      initial={{ opacity: 0, y: 50 }}
      whileInView={{ opacity: 1, y: 0 }}
      viewport={{ once: true, margin: '-100px' }}
      transition={{ duration: 0.5 }}
    >
      {children}
    </motion.div>
  )
}
```

### Scroll Progress

```tsx
"use client"

import { motion, useScroll, useSpring } from 'framer-motion'

export function ScrollProgress() {
  const { scrollYProgress } = useScroll()
  const scaleX = useSpring(scrollYProgress, {
    stiffness: 100,
    damping: 30,
    restDelta: 0.001,
  })

  return (
    <motion.div
      style={{
        scaleX,
        position: 'fixed',
        top: 0,
        left: 0,
        right: 0,
        height: 4,
        background: 'var(--primary)',
        transformOrigin: '0%',
      }}
    />
  )
}
```

## Stagger Children

```tsx
const container = {
  hidden: { opacity: 0 },
  show: {
    opacity: 1,
    transition: {
      staggerChildren: 0.1,
      delayChildren: 0.3,
    },
  },
}

const item = {
  hidden: { opacity: 0, y: 20 },
  show: { opacity: 1, y: 0 },
}

export function StaggeredList({ items }) {
  return (
    <motion.ul variants={container} initial="hidden" animate="show">
      {items.map((i) => (
        <motion.li key={i.id} variants={item}>
          {i.name}
        </motion.li>
      ))}
    </motion.ul>
  )
}
```

## Spring Animations

```tsx
// Spring physics for natural feel
<motion.div
  animate={{ x: 100 }}
  transition={{
    type: 'spring',
    stiffness: 100,   // Higher = faster
    damping: 10,      // Higher = less bouncy
    mass: 1,          // Higher = more momentum
  }}
/>

// Presets
<motion.div
  animate={{ scale: 1.2 }}
  transition={{ type: 'spring', bounce: 0.5 }}
/>
```

## Keyframe Animations

```tsx
<motion.div
  animate={{
    scale: [1, 1.2, 1.2, 1, 1],
    rotate: [0, 0, 180, 180, 0],
    borderRadius: ['0%', '0%', '50%', '50%', '0%'],
  }}
  transition={{
    duration: 2,
    ease: 'easeInOut',
    times: [0, 0.2, 0.5, 0.8, 1],
    repeat: Infinity,
    repeatDelay: 1,
  }}
/>
```

## Modal Animation Pattern

```tsx
"use client"

import { motion, AnimatePresence } from 'framer-motion'

const overlayVariants = {
  hidden: { opacity: 0 },
  visible: { opacity: 1 },
}

const modalVariants = {
  hidden: { opacity: 0, scale: 0.95, y: 20 },
  visible: { opacity: 1, scale: 1, y: 0 },
}

export function AnimatedModal({ isOpen, onClose, children }) {
  return (
    <AnimatePresence>
      {isOpen && (
        <>
          <motion.div
            className="fixed inset-0 bg-black/50"
            variants={overlayVariants}
            initial="hidden"
            animate="visible"
            exit="hidden"
            onClick={onClose}
          />
          <motion.div
            className="fixed inset-0 flex items-center justify-center p-4"
            variants={modalVariants}
            initial="hidden"
            animate="visible"
            exit="hidden"
            transition={{ type: 'spring', damping: 25, stiffness: 300 }}
          >
            <div className="bg-background rounded-lg p-6 max-w-md w-full">
              {children}
            </div>
          </motion.div>
        </>
      )}
    </AnimatePresence>
  )
}
```

## Notification Toast Animation

```tsx
const toastVariants = {
  initial: { opacity: 0, y: 50, scale: 0.9 },
  animate: { opacity: 1, y: 0, scale: 1 },
  exit: { opacity: 0, y: 20, scale: 0.9 },
}

<motion.div
  variants={toastVariants}
  initial="initial"
  animate="animate"
  exit="exit"
  transition={{ type: 'spring', damping: 20, stiffness: 300 }}
>
  Toast content
</motion.div>
```

## Integration with ShadCN UI

### Animated ShadCN Components

ShadCN components can be animated by wrapping them with Framer Motion or using the `asChild` prop with `forceMount`.

### Key Pattern: forceMount + AnimatePresence

```tsx
"use client"

import { Dialog, DialogContent, DialogTrigger } from '@/components/ui/dialog'
import { motion, AnimatePresence } from 'framer-motion'
import { useState } from 'react'

export function AnimatedDialog({ trigger, children }) {
  const [open, setOpen] = useState(false)

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>{trigger}</DialogTrigger>
      <AnimatePresence>
        {open && (
          <DialogContent forceMount asChild>
            <motion.div
              initial={{ opacity: 0, scale: 0.95 }}
              animate={{ opacity: 1, scale: 1 }}
              exit={{ opacity: 0, scale: 0.95 }}
              transition={{ type: 'spring', damping: 25, stiffness: 300 }}
            >
              {children}
            </motion.div>
          </DialogContent>
        )}
      </AnimatePresence>
    </Dialog>
  )
}
```

### Animated Cards with ShadCN

```tsx
"use client"

import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { motion } from 'framer-motion'

const cardVariants = {
  hidden: { opacity: 0, y: 20 },
  visible: (i: number) => ({
    opacity: 1,
    y: 0,
    transition: { delay: i * 0.1, duration: 0.3 },
  }),
}

export function AnimatedCardGrid({ items }) {
  return (
    <div className="grid grid-cols-3 gap-4">
      {items.map((item, i) => (
        <motion.div
          key={item.id}
          custom={i}
          variants={cardVariants}
          initial="hidden"
          animate="visible"
          whileHover={{ y: -4, transition: { duration: 0.2 } }}
        >
          <Card className="h-full transition-shadow hover:shadow-lg">
            <CardHeader>
              <CardTitle>{item.title}</CardTitle>
            </CardHeader>
            <CardContent>{item.content}</CardContent>
          </Card>
        </motion.div>
      ))}
    </div>
  )
}
```

### Animated Buttons

```tsx
"use client"

import { Button } from '@/components/ui/button'
import { motion } from 'framer-motion'

// Create a motion-enabled button
const MotionButton = motion(Button)

export function AnimatedButton({ children, ...props }) {
  return (
    <MotionButton
      whileHover={{ scale: 1.02 }}
      whileTap={{ scale: 0.98 }}
      transition={{ type: 'spring', stiffness: 400, damping: 17 }}
      {...props}
    >
      {children}
    </MotionButton>
  )
}
```

### Animated Data Lists

```tsx
"use client"

import { motion, AnimatePresence } from 'framer-motion'

const listVariants = {
  hidden: { opacity: 0 },
  visible: { opacity: 1, transition: { staggerChildren: 0.05 } },
}

const itemVariants = {
  hidden: { opacity: 0, x: -20 },
  visible: { opacity: 1, x: 0 },
  exit: { opacity: 0, x: 20 },
}

export function AnimatedList({ items, renderItem }) {
  return (
    <motion.ul variants={listVariants} initial="hidden" animate="visible">
      <AnimatePresence mode="popLayout">
        {items.map((item) => (
          <motion.li
            key={item.id}
            variants={itemVariants}
            exit="exit"
            layout
          >
            {renderItem(item)}
          </motion.li>
        ))}
      </AnimatePresence>
    </motion.ul>
  )
}
```

## Best Practices

1. **Use `"use client"`**: Framer Motion requires client components
2. **Define variants outside**: Prevents recreation on re-render
3. **Use `layout` prop sparingly**: Can be performance intensive
4. **Prefer spring animations**: More natural than linear/ease
5. **Use `AnimatePresence` for exits**: Required for exit animations
6. **Set `viewport={{ once: true }}`**: For scroll animations that should only play once
7. **Use `whileHover`/`whileTap`**: Instead of CSS hover states for consistency
8. **forceMount for ShadCN**: Required when using AnimatePresence with ShadCN dialogs
9. **motion() wrapper**: Use to add animation to any component
