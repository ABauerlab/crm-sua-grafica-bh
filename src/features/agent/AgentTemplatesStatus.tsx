import { Badge } from '@/components/ui/badge'
import { useTemplates } from '@/hooks/queries'
import { AGENT_TEMPLATES } from '@/lib/agent-templates'
import { cn } from '@/lib/utils'

const STATUS: Record<string, { label: string; className: string }> = {
  APPROVED: { label: 'Aprovado', className: 'bg-emerald-100 text-emerald-800' },
  PENDING: { label: 'Em análise', className: 'bg-amber-100 text-amber-800' },
  IN_APPEAL: { label: 'Em recurso', className: 'bg-amber-100 text-amber-800' },
  REJECTED: { label: 'Rejeitado', className: 'bg-rose-100 text-rose-800' },
  PAUSED: { label: 'Pausado', className: 'bg-orange-100 text-orange-800' },
  DISABLED: { label: 'Desativado', className: 'bg-zinc-200 text-zinc-700' },
}

const CATEGORY: Record<string, string> = { MARKETING: 'Marketing', UTILITY: 'Utilidade' }

/** Status de aprovação dos templates do agente, lido do cache sincronizado com a Meta (botão Sincronizar abaixo). */
export default function AgentTemplatesStatus() {
  const { data, isLoading } = useTemplates()
  const byName = new Map((data ?? []).filter((t) => t.language === 'pt_BR').map((t) => [t.name, t]))
  const approved = AGENT_TEMPLATES.filter((t) => byName.get(t.name)?.status === 'APPROVED').length

  return (
    <section aria-labelledby="agent-templates-title" className="rounded-md border">
      <header className="flex flex-wrap items-center justify-between gap-2 border-b px-3 py-2">
        <h2 id="agent-templates-title" className="text-sm font-bold">Templates do agente de IA</h2>
        <p className="text-xs text-muted-foreground tabular">{isLoading ? 'Carregando…' : `${approved} de ${AGENT_TEMPLATES.length} aprovados`}</p>
      </header>
      <ul className="divide-y">
        {AGENT_TEMPLATES.map((t) => {
          const cached = byName.get(t.name)
          const s = cached?.status ? (STATUS[cached.status] ?? { label: cached.status, className: 'bg-zinc-200 text-zinc-700' }) : { label: 'Não sincronizado', className: 'bg-zinc-200 text-zinc-700' }
          const reclassified = cached?.category && cached.category !== t.category
          return (
            <li key={t.name} className="flex flex-wrap items-center justify-between gap-2 px-3 py-2">
              <div className="min-w-0">
                <p className="truncate text-sm font-semibold">{t.name}</p>
                <p className="text-xs text-muted-foreground">{t.use}</p>
              </div>
              <div className="flex flex-wrap items-center gap-1.5">
                <Badge className={cn('bg-zinc-100 text-zinc-700')}>{CATEGORY[cached?.category ?? t.category] ?? t.category}</Badge>
                {reclassified && <Badge className="bg-rose-100 text-rose-800">Reclassificado pela Meta (pedido: {CATEGORY[t.category]})</Badge>}
                <Badge className={s.className}>{s.label}</Badge>
              </div>
            </li>
          )
        })}
      </ul>
    </section>
  )
}
