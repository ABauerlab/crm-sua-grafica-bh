import { Bot, Search, User } from 'lucide-react'
import { useMemo, useState } from 'react'
import { NavLink } from 'react-router-dom'
import { EmptyState } from '@/components/ui/empty-state'
import { Input } from '@/components/ui/input'
import { Skeleton } from '@/components/ui/skeleton'
import { useConversations } from '@/hooks/queries'
import { contactLabel, formatListTime } from '@/lib/format'
import { windowInfo } from '@/lib/window'
import { cn } from '@/lib/utils'
import { MessageSquare } from 'lucide-react'

type Filter = 'todas' | 'nao_lidas' | 'atencao' | 'ia' | 'humano'
const FILTERS: { value: Filter; label: string }[] = [
  { value: 'todas', label: 'Todas' },
  { value: 'nao_lidas', label: 'Não lidas' },
  { value: 'atencao', label: 'Atenção' },
  { value: 'ia', label: 'IA' },
  { value: 'humano', label: 'Humano' },
]

export function ConversationList() {
  const { data, isLoading, error } = useConversations()
  const [search, setSearch] = useState('')
  const [filter, setFilter] = useState<Filter>('todas')

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase()
    return (data ?? []).filter((c) => {
      if (filter === 'nao_lidas' && c.unread_count === 0) return false
      if (filter === 'atencao' && !c.needs_human) return false
      if (filter === 'ia' && !c.ai_handled) return false
      if (filter === 'humano' && c.ai_handled) return false
      if (!q) return true
      return contactLabel(c.contact).toLowerCase().includes(q) || c.contact.wa_id.includes(q.replace(/\D/g, '') || '\0') || (c.last_message_preview ?? '').toLowerCase().includes(q)
    })
  }, [data, search, filter])

  return (
    <div className="flex h-full flex-col">
      <div className="space-y-2 border-b p-3">
        <div className="relative">
          <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" aria-hidden />
          <Input className="pl-9" placeholder="Buscar conversa" value={search} onChange={(e) => setSearch(e.target.value)} aria-label="Buscar conversa" />
        </div>
        <div className="flex flex-wrap gap-1" role="group" aria-label="Filtrar conversas">
          {FILTERS.map((f) => (
            <button
              key={f.value}
              onClick={() => setFilter(f.value)}
              aria-pressed={filter === f.value}
              className={cn('min-h-9 rounded-sm px-2.5 text-xs font-bold', filter === f.value ? 'bg-ink text-white' : 'bg-secondary text-muted-foreground hover:bg-secondary/70')}
            >
              {f.label}
            </button>
          ))}
        </div>
      </div>
      <div className="min-h-0 flex-1 overflow-y-auto">
        {isLoading && (
          <div className="space-y-2 p-3">{[0, 1, 2, 3].map((i) => <Skeleton key={i} className="h-16 w-full" />)}</div>
        )}
        {error && <p role="alert" className="p-4 text-sm text-destructive">Erro ao carregar conversas.</p>}
        {!isLoading && !filtered.length && (
          <EmptyState icon={MessageSquare} title={data?.length ? 'Nada com esse filtro' : 'Nenhuma conversa ainda'}>
            {data?.length ? 'Tente outro filtro ou limpe a busca.' : 'As conversas aparecem aqui assim que um cliente escrever no WhatsApp.'}
          </EmptyState>
        )}
        {filtered.map((c) => {
          const win = windowInfo(c)
          return (
            <NavLink
              key={c.id}
              to={`/inbox/${c.id}`}
              className={({ isActive }) => cn('relative block border-b px-4 py-3 transition-colors hover:bg-secondary/70', isActive && 'bg-accent before:absolute before:inset-y-0 before:left-0 before:w-1 before:bg-primary')}
            >
              <div className="flex items-baseline justify-between gap-2">
                <span className={cn('truncate text-sm', c.unread_count > 0 ? 'font-black' : 'font-semibold')}>{contactLabel(c.contact)}</span>
                <span className={cn('shrink-0 text-xs tabular', c.unread_count > 0 ? 'font-bold text-brand-magenta' : 'text-muted-foreground')}>{formatListTime(c.last_message_at)}</span>
              </div>
              <div className="mt-1 flex items-center justify-between gap-2">
                <span className="truncate text-xs text-muted-foreground">{c.last_message_preview ?? 'Sem mensagens'}</span>
                {c.unread_count > 0 && (
                  <span className="flex h-5 min-w-5 shrink-0 items-center justify-center rounded-full bg-brand-magenta px-1.5 text-[11px] font-bold text-white tabular">{c.unread_count}</span>
                )}
              </div>
              <div className="mt-1.5 flex flex-wrap items-center gap-1">
                <span className={cn('inline-flex items-center gap-1 rounded-sm px-1.5 py-0.5 text-[11px] font-bold', c.ai_handled ? 'bg-brand-blue text-white' : 'bg-ink/10 text-ink')}>
                  {c.ai_handled ? <Bot className="h-3 w-3" aria-hidden /> : <User className="h-3 w-3" aria-hidden />}
                  {c.ai_handled ? 'IA' : 'Humano'}
                </span>
                {c.needs_human && <span className="rounded-sm bg-brand-red px-1.5 py-0.5 text-[11px] font-bold text-white">Atenção</span>}
                {(c.labels ?? []).map((l) => (
                  <span key={l} className="rounded-sm bg-brand-cyan/20 px-1.5 py-0.5 text-[11px] font-semibold">{l}</span>
                ))}
                {!win.open && c.last_inbound_at && <span className="ml-auto text-[11px] text-muted-foreground">janela fechada</span>}
              </div>
            </NavLink>
          )
        })}
      </div>
    </div>
  )
}
