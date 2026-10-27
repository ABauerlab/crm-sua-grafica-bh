import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useState, type DragEvent } from 'react'
import { Link } from 'react-router-dom'
import { Badge } from '@/components/ui/badge'
import { useConversations } from '@/hooks/queries'
import { STAGES, contactLabel, formatListTime } from '@/lib/format'
import { supabase } from '@/lib/supabase'
import type { ConversationWithContact, Stage } from '@/lib/types'
import { cn } from '@/lib/utils'

export default function Funnel() {
  const qc = useQueryClient()
  const { data, isLoading, error } = useConversations()
  const [over, setOver] = useState<Stage | null>(null)

  const move = useMutation({
    mutationFn: async ({ id, stage }: { id: string; stage: Stage }) => {
      const { error } = await supabase.from('conversations').update({ stage }).eq('id', id)
      if (error) throw error
    },
    // Atualização otimista: o cartão muda de coluna na hora
    onMutate: async ({ id, stage }) => {
      await qc.cancelQueries({ queryKey: ['conversations'] })
      const prev = qc.getQueryData<ConversationWithContact[]>(['conversations'])
      qc.setQueryData<ConversationWithContact[]>(['conversations'], (old) => old?.map((c) => (c.id === id ? { ...c, stage } : c)))
      return { prev }
    },
    onError: (_e, _v, ctx) => qc.setQueryData(['conversations'], ctx?.prev),
    onSettled: () => qc.invalidateQueries({ queryKey: ['conversations'] }),
  })

  function onDrop(e: DragEvent, stage: Stage) {
    e.preventDefault()
    setOver(null)
    const id = e.dataTransfer.getData('text/plain')
    const current = data?.find((c) => c.id === id)
    if (id && current && current.stage !== stage) move.mutate({ id, stage })
  }

  return (
    <div className="flex h-full flex-col">
      <header className="border-b px-4 py-3">
        <h1 className="text-lg font-semibold">Funil de vendas</h1>
        <p className="text-xs text-muted-foreground">Arraste os cartões entre as etapas.</p>
        {move.isError && <p role="alert" className="mt-1 text-xs text-destructive">Não foi possível mover o cartão.</p>}
      </header>
      {isLoading && <p className="p-4 text-sm text-muted-foreground">Carregando…</p>}
      {error && <p className="p-4 text-sm text-destructive">Erro ao carregar o funil.</p>}
      <div className="flex min-h-0 flex-1 gap-3 overflow-x-auto p-4">
        {STAGES.map((stage) => {
          const items = (data ?? []).filter((c) => c.stage === stage.value)
          return (
            <section
              key={stage.value}
              onDragOver={(e) => {
                e.preventDefault()
                setOver(stage.value)
              }}
              onDragLeave={() => setOver((o) => (o === stage.value ? null : o))}
              onDrop={(e) => onDrop(e, stage.value)}
              className={cn('flex w-64 shrink-0 flex-col rounded-lg bg-muted p-2 transition-colors', over === stage.value && 'bg-accent ring-2 ring-primary/40')}
              aria-label={`Etapa ${stage.label}`}
            >
              <div className="mb-2 flex items-center justify-between px-1">
                <Badge className={stage.color}>{stage.label}</Badge>
                <span className="text-xs text-muted-foreground">{items.length}</span>
              </div>
              <div className="min-h-0 flex-1 space-y-2 overflow-y-auto">
                {items.map((c) => (
                  <Link
                    key={c.id}
                    to={`/inbox/${c.id}`}
                    draggable
                    onDragStart={(e) => {
                      e.dataTransfer.setData('text/plain', c.id)
                      e.dataTransfer.effectAllowed = 'move'
                    }}
                    className="block cursor-grab rounded-md border bg-card p-3 shadow-sm active:cursor-grabbing"
                  >
                    <div className="flex items-baseline justify-between gap-2">
                      <span className="truncate text-sm font-medium">{contactLabel(c.contact)}</span>
                      {c.unread_count > 0 && (
                        <span className="rounded-full bg-primary px-1.5 text-[11px] font-medium text-primary-foreground">{c.unread_count}</span>
                      )}
                    </div>
                    <p className="mt-1 truncate text-xs text-muted-foreground">{c.last_message_preview ?? 'Sem mensagens'}</p>
                    <p className="mt-1 text-[11px] text-muted-foreground">{formatListTime(c.last_message_at)}</p>
                  </Link>
                ))}
              </div>
            </section>
          )
        })}
      </div>
    </div>
  )
}
