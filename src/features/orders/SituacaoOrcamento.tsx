import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { AlertTriangle, CheckCircle2, RefreshCw } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { useToast } from '@/components/ui/toast'
import { orcamentoNumero } from '@/lib/orcamentos'
import type { OrderCard } from '@/lib/orders'
import { supabase } from '@/lib/supabase'

type Situacao = {
  situacao: 'sem_orcamento' | 'atualizado' | 'desatualizado'
  numero?: number
  itens_divergentes?: number
  desconto_divergente?: boolean
}

/**
 * Mostra no topo do pedido se o orçamento ativo está em dia com os itens e o desconto.
 * Compara o conteúdo (não a data), então qualquer alteração no pedido aparece aqui até a sincronização.
 */
export function SituacaoOrcamento({ order }: { order: OrderCard }) {
  const toast = useToast()
  const qc = useQueryClient()
  const { data } = useQuery({
    queryKey: ['orcamento-situacao', order.id],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('pedido_orcamento_situacao', { p_order: order.id })
      if (error) throw new Error(error.message)
      return data as Situacao
    },
  })
  const atualizar = useMutation({
    mutationFn: async () => {
      const { data, error } = await supabase.rpc('pedido_sincronizar_orcamento', { p_order: order.id })
      if (error) throw new Error(error.message)
      return data
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['orcamentos'] })
      qc.invalidateQueries({ queryKey: ['orcamento-situacao', order.id] })
      toast('ok', 'Orçamento atualizado com o pedido. Gere o PDF de novo para enviar.')
    },
    onError: (e: Error) => toast('error', `O orçamento não foi atualizado: ${e.message}`),
  })

  if (!data || data.situacao === 'sem_orcamento') return null

  if (data.situacao === 'atualizado') {
    return (
      <div role="status" className="mx-4 mt-3 flex items-center gap-2 rounded-md border p-2.5 text-sm">
        <CheckCircle2 className="h-4 w-4 shrink-0" aria-hidden />
        <span>Orçamento {orcamentoNumero(data.numero ?? 0)} em dia com o pedido.</span>
      </div>
    )
  }

  return (
    <div role="alert" className="mx-4 mt-3 flex flex-wrap items-center justify-between gap-2 rounded-md border border-brand-yellow bg-brand-yellow/20 p-2.5 text-sm">
      <span className="flex items-center gap-2 font-semibold">
        <AlertTriangle className="h-4 w-4 shrink-0" aria-hidden />
        O pedido mudou depois do último orçamento{data.numero ? ` (${orcamentoNumero(data.numero)})` : ''}. O PDF e o link podem estar desatualizados.
      </span>
      <Button size="sm" onClick={() => atualizar.mutate()} disabled={atualizar.isPending}>
        <RefreshCw className="h-4 w-4" aria-hidden /> {atualizar.isPending ? 'Atualizando…' : 'Atualizar orçamento'}
      </Button>
    </div>
  )
}
