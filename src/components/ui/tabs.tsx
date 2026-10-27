import * as T from '@radix-ui/react-tabs'
import { forwardRef, type ComponentPropsWithoutRef, type ElementRef } from 'react'
import { cn } from '@/lib/utils'

export const Tabs = T.Root

export const TabsList = forwardRef<ElementRef<typeof T.List>, ComponentPropsWithoutRef<typeof T.List>>(({ className, ...p }, ref) => (
  <T.List ref={ref} className={cn('flex gap-1 overflow-x-auto border-b px-2', className)} {...p} />
))
TabsList.displayName = 'TabsList'

export const TabsTrigger = forwardRef<ElementRef<typeof T.Trigger>, ComponentPropsWithoutRef<typeof T.Trigger>>(({ className, ...p }, ref) => (
  <T.Trigger
    ref={ref}
    className={cn(
      'relative h-11 shrink-0 whitespace-nowrap px-3 text-sm font-medium text-muted-foreground transition-colors hover:text-foreground md:h-10',
      'data-[state=active]:font-bold data-[state=active]:text-foreground',
      'after:absolute after:inset-x-2 after:bottom-0 after:h-[3px] after:rounded-t after:bg-transparent data-[state=active]:after:bg-primary',
      className,
    )}
    {...p}
  />
))
TabsTrigger.displayName = 'TabsTrigger'

export const TabsContent = forwardRef<ElementRef<typeof T.Content>, ComponentPropsWithoutRef<typeof T.Content>>(({ className, ...p }, ref) => (
  <T.Content ref={ref} className={cn('min-h-0 flex-1 overflow-y-auto p-4 outline-none', className)} {...p} />
))
TabsContent.displayName = 'TabsContent'
