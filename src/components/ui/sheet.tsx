import * as Dialog from '@radix-ui/react-dialog'
import { X } from 'lucide-react'
import type { ReactNode } from 'react'
import { cn } from '@/lib/utils'

/** Gaveta lateral (pedido). No celular ocupa a tela toda. */
export function Sheet({
  open,
  onOpenChange,
  title,
  description,
  children,
  className,
}: {
  open: boolean
  onOpenChange: (o: boolean) => void
  title: ReactNode
  description?: string
  children: ReactNode
  className?: string
}) {
  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-40 bg-ink/50" />
        <Dialog.Content
          className={cn('fixed inset-y-0 right-0 z-50 flex w-full flex-col bg-background shadow-xl outline-none sm:max-w-2xl', className)}
          aria-describedby={description ? undefined : undefined}
        >
          <header className="flex items-start justify-between gap-3 border-b px-4 py-3">
            <div className="min-w-0">
              <Dialog.Title className="truncate text-lg font-black">{title}</Dialog.Title>
              {description && <Dialog.Description className="text-xs text-muted-foreground">{description}</Dialog.Description>}
            </div>
            <Dialog.Close className="flex h-11 w-11 items-center justify-center rounded-md hover:bg-secondary md:h-9 md:w-9" aria-label="Fechar">
              <X className="h-5 w-5" />
            </Dialog.Close>
          </header>
          {children}
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  )
}

/** Diálogo centralizado (confirmações). */
export function Modal({
  open,
  onOpenChange,
  title,
  description,
  children,
}: {
  open: boolean
  onOpenChange: (o: boolean) => void
  title: string
  description?: string
  children: ReactNode
}) {
  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-[60] bg-ink/50" />
        <Dialog.Content className="fixed left-1/2 top-1/2 z-[70] w-[calc(100%-2rem)] max-w-md -translate-x-1/2 -translate-y-1/2 rounded-lg border bg-background p-5 shadow-xl outline-none">
          <Dialog.Title className="text-lg font-black">{title}</Dialog.Title>
          {description && <Dialog.Description className="mt-1 text-sm text-muted-foreground">{description}</Dialog.Description>}
          <div className="mt-4">{children}</div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  )
}
