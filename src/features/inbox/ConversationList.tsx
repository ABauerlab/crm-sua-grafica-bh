import { Search } from 'lucide-react'
import { useMemo, useState } from 'react'
import { NavLink } from 'react-router-dom'
import { StageBadge } from '@/components/StageBadge'
import { Input } from '@/components/ui/input'
import { useConversations } from '@/hooks/queries'
import { contactLabel, formatListTime } from '@/lib/format'
import { cn } from '@/lib/utils'

export function ConversationList() {
  const { data, isLoading, error } = useConversations()
  const [search, setSearch] = useState('')

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase()
    if (!q) return data ?? []
    return (data ?? []).filter((c) => contactLabel(c.contact).toLowerCase().includes(q) || c.contact.wa_id.includes(q.replace(/\D/g, '') || '\0'))
  }, [data, search])

  return (
    <div className="flex h-full flex-col">
      <div className="relative border-b p-3">
        <Search className="pointer-events-none absolute left-5 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
        <Input className="pl-8" placeholder="Buscar conversa" value={search} onChange={(e) => setSearch(e.target.value)} aria-label="Buscar conversa" />
      </div>
      <div className="min-h-0 flex-1 overflow-y-auto">
        {isLoading && <p className="p-4 text-sm text-muted-foreground">Carregando…</p>}
        {error && <p className="p-4 text-sm text-destructive">Erro ao carregar conversas.</p>}
        {!isLoading && !filtered.length && <p className="p-4 text-sm text-muted-foreground">Nenhuma conversa ainda.</p>}
        {filtered.map((c) => (
          <NavLink
            key={c.id}
            to={`/inbox/${c.id}`}
            className={({ isActive }) =>
              cn('block border-b px-4 py-3 transition-colors hover:bg-accent/60', isActive && 'bg-accent')
            }
          >
            <div className="flex items-baseline justify-between gap-2">
              <span className={cn('truncate text-sm', c.unread_count > 0 ? 'font-semibold' : 'font-medium')}>{contactLabel(c.contact)}</span>
              <span className={cn('shrink-0 text-xs', c.unread_count > 0 ? 'font-medium text-primary' : 'text-muted-foreground')}>
                {formatListTime(c.last_message_at)}
              </span>
            </div>
            <div className="mt-1 flex items-center justify-between gap-2">
              <span className="truncate text-xs text-muted-foreground">{c.last_message_preview ?? 'Sem mensagens'}</span>
              {c.unread_count > 0 && (
                <span className="flex h-5 min-w-5 shrink-0 items-center justify-center rounded-full bg-primary px-1.5 text-[11px] font-medium text-primary-foreground">
                  {c.unread_count}
                </span>
              )}
            </div>
            <StageBadge stage={c.stage} className="mt-1.5" />
          </NavLink>
        ))}
      </div>
    </div>
  )
}
