import { Check } from 'lucide-react'
import { useToast } from '@/components/ui/toast'
import { useMoveOrder, useUpdateOrder } from '@/hooks/orders'
import type { ArtStatus, OrderCard } from '@/lib/orders'
import { cn } from '@/lib/utils'

/** Etapas rápidas da arte. Cada etapa grava o art_status correspondente e marca a chave em art_checklist. */
const ETAPAS: { key: string; label: string; status: ArtStatus | null }[] = [
  { key: 'arquivo_recebido', label: 'Arquivo recebido do cliente', status: 'enviada' },
  { key: 'arte_montagem', label: 'Arte em montagem ou ajuste', status: 'em_criacao' },
  { key: 'arte_aprovada', label: 'Arte finalizada e aprovada', status: 'aprovada' },
  { key: 'producao', label: 'Liberado para produção', status: null },
]

/**
 * Checklist de 4 etapas da arte. Marcar uma etapa atualiza na hora o status e o checklist do pedido,
 * e o operador pode fazer isso antes do pagamento bater. "Liberado para produção" passa pela trava do banco.
 */
export function ArtEtapas({ order }: { order: OrderCard }) {
  const toast = useToast()
  const update = useUpdateOrder()
  const move = useMoveOrder()
  const checklist = order.art_checklist ?? {}
  const busy = update.isPending || move.isPending

  function marcar(i: number) {
    const etapa = ETAPAS[i]
    if (etapa.status) {
      // Marcar uma etapa conclui as anteriores e desmarca as seguintes
      const novo: Record<string, boolean> = {}
      ETAPAS.forEach((e, j) => {
        if (e.key !== 'producao') novo[e.key] = j <= i
      })
      update.mutate(
        { id: order.id, patch: { art_status: etapa.status, art_checklist: { ...checklist, ...novo } } },
        { onSuccess: () => toast('ok', `Etapa marcada: ${etapa.label}.`), onError: (e) => toast('error', e.message) },
      )
      return
    }
    if (order.art_status !== 'aprovada') {
      toast('error', 'Aprove a arte antes de liberar para produção.')
      return
    }
    move.mutate(
      { order, to: 'producao' },
      {
        onSuccess: () => {
          update.mutate({ id: order.id, patch: { art_checklist: { ...checklist, producao: true } } })
          toast('ok', 'Pedido liberado para produção.')
        },
        onError: (e) => toast('error', e.message),
      },
    )
  }

  return (
    <fieldset className="rounded-md border p-3" disabled={busy}>
      <legend className="px-1 text-xs font-bold uppercase tracking-wide">Etapas da arte</legend>
      <ul className="space-y-1">
        {ETAPAS.map((e, i) => {
          const feito = e.key === 'producao' ? order.stage === 'producao' || !!checklist.producao : !!checklist[e.key]
          return (
            <li key={e.key}>
              <button
                type="button"
                role="checkbox"
                aria-checked={feito}
                onClick={() => marcar(i)}
                className="flex min-h-11 w-full items-center gap-2 rounded-sm text-left text-sm md:min-h-8"
              >
                <span
                  className={cn(
                    'flex h-5 w-5 shrink-0 items-center justify-center rounded-sm border md:h-4 md:w-4',
                    feito ? 'border-brand-green bg-brand-green text-white' : 'border-input bg-background',
                  )}
                  aria-hidden
                >
                  {feito && <Check className="h-3.5 w-3.5" />}
                </span>
                {e.label}
              </button>
            </li>
          )
        })}
      </ul>
    </fieldset>
  )
}
