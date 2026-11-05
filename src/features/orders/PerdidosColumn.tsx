import { Skeleton } from '@/components/ui/skeleton'
import { useOrcamentosPerdidos, type OrcamentoPerdido } from '@/hooks/orcamentos'
import { MOTIVO_PERDA, orcamentoNumero } from '@/lib/orcamentos'
import { formatBRL } from '@/lib/money'

const dataCurta = (iso: string | null) => (iso ? new Date(iso).toLocaleDateString('pt-BR', { day: '2-digit', month: '2-digit', timeZone: 'America/Sao_Paulo' }) : '')

/**
 * Coluna Perdidos do Kanban: orçamentos que não fecharam, com o motivo obrigatório.
 * Fica fora do arrastar e soltar, porque o motivo é registrado na aba Orçamentos do pedido.
 * O motivo e a observação ficam guardados para um disparo futuro (só para quem consentiu).
 */
export function PerdidosColumn({ mobile = false }: { mobile?: boolean }) {
  const { data, isLoading } = useOrcamentosPerdidos()
  const lista = data ?? []

  return (
    <section
      id={mobile ? 'col-perdidos-mobile' : 'col-perdidos'}
      aria-label="Orçamentos perdidos"
      className={mobile ? 'mt-6' : 'flex w-72 shrink-0 flex-col rounded-md border bg-card'}
    >
      <header className={mobile ? 'mb-2 flex items-center justify-between' : 'flex items-center justify-between gap-2 border-b px-3 py-2.5'}>
        <h2 className="text-sm font-black">Orçamento perdido</h2>
        <span className="rounded-sm bg-background/80 px-1.5 text-xs font-bold tabular">{lista.length}</span>
      </header>
      <p className="px-3 pb-2 text-xs text-muted-foreground">Para disparo futuro: só quem consentiu recebe promoção.</p>

      <div className={mobile ? 'space-y-2' : 'flex-1 space-y-2 overflow-y-auto p-2'}>
        {isLoading && <Skeleton className="h-20 w-full" />}
        {!isLoading && lista.length === 0 && (
          <p className="rounded-md border border-dashed p-3 text-center text-xs text-muted-foreground">Nenhum orçamento perdido.</p>
        )}
        {lista.map((o) => (
          <CartaoPerdido key={o.id} o={o} />
        ))}
      </div>
    </section>
  )
}

function CartaoPerdido({ o }: { o: OrcamentoPerdido }) {
  const nome = o.contact?.name?.trim() || o.contact?.phone || 'Contato sem nome'
  return (
    <article className="rounded-md border bg-background p-2.5 text-sm">
      <div className="flex items-center justify-between gap-2">
        <p className="truncate font-bold">{nome}</p>
        <span className="shrink-0 text-xs tabular text-muted-foreground">{dataCurta(o.motivo_perda_em)}</span>
      </div>
      <p className="text-xs text-muted-foreground tabular">{orcamentoNumero(o.numero)} · {formatBRL(o.total)}</p>
      <p className="mt-1.5 text-xs">
        <strong>Motivo:</strong> {o.motivo_perda ? MOTIVO_PERDA[o.motivo_perda] : 'não informado'}
      </p>
      {o.motivo_perda_obs && <p className="mt-1 text-xs text-muted-foreground">{o.motivo_perda_obs}</p>}
    </article>
  )
}
