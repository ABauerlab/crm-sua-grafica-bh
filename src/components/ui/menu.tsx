import * as M from '@radix-ui/react-dropdown-menu'
import { forwardRef, type ComponentPropsWithoutRef, type ElementRef } from 'react'
import { cn } from '@/lib/utils'

export const Menu = M.Root
export const MenuTrigger = M.Trigger

export const MenuContent = forwardRef<ElementRef<typeof M.Content>, ComponentPropsWithoutRef<typeof M.Content>>(({ className, sideOffset = 4, ...p }, ref) => (
  <M.Portal>
    <M.Content ref={ref} sideOffset={sideOffset} className={cn('z-[80] min-w-48 rounded-md border bg-background p-1 shadow-lg', className)} {...p} />
  </M.Portal>
))
MenuContent.displayName = 'MenuContent'

export const MenuItem = forwardRef<ElementRef<typeof M.Item>, ComponentPropsWithoutRef<typeof M.Item>>(({ className, ...p }, ref) => (
  <M.Item
    ref={ref}
    className={cn('flex min-h-11 cursor-pointer select-none items-center gap-2 rounded-sm px-2.5 text-sm outline-none data-[disabled]:opacity-50 data-[highlighted]:bg-secondary md:min-h-9', className)}
    {...p}
  />
))
MenuItem.displayName = 'MenuItem'

export const MenuLabel = M.Label
export const MenuSeparator = () => <M.Separator className="my-1 h-px bg-border" />
