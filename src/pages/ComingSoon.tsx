import type { LucideIcon } from 'lucide-react'
import { EmptyState } from '@/components/ui/empty-state'

export default function ComingSoon({ title, icon, children }: { title: string; icon: LucideIcon; children: string }) {
  return (
    <div className="flex h-full flex-col">
      <header className="border-b px-4 py-3">
        <h1 className="text-xl font-black">{title}</h1>
      </header>
      <div className="flex flex-1 items-center justify-center">
        <EmptyState icon={icon} title="Em breve">{children}</EmptyState>
      </div>
    </div>
  )
}
