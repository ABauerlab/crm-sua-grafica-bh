import { useMutation, useQueryClient } from '@tanstack/react-query'
import { Trash2 } from 'lucide-react'
import { useState } from 'react'
import { Button } from '@/components/ui/button'
import { Modal } from '@/components/ui/sheet'
import { Textarea } from '@/components/ui/textarea'
import { useToast } from '@/components/ui/toast'
import { supabase } from '@/lib/supabase'
import type { OrderCard } from '@/lib/orders'

type Acao = 'excluir' | 'cancelar' | 'arquivar'

/**
 * Pedido sem pagamento: exclusão lógica com motivo e auditoria (pedido de teste some por completo).
 * Pedido com pagamento aprovado: nunca é apagado, só cancelado (reembolso fica com o dono) ou arquivado.
 */
export function ExcluirPedido({ order, onDone }: { order: OrderCard; onDone: () => void }) {
  const toast = useToast()
  const qc = useQueryClient()
  const [acao, setAcao] = useState<Acao | null>(null)
  const [motivo, setMotivo] = useState('')
  const pago = order.payment_status === 'aprovado' || order.payment_manual

  const executar = useMutation({
    mutationFn: async () => {
      if (!acao) return
      const r = acao === 'excluir'
        ? await supabase.rpc('pedido_excluir', { p_order: order.id, p_motivo: motivo })
        : await supabase.rpc('pedido_cancelar_ou_arquivar', { p_order: order.id, p_acao: acao, p_motivo: motivo })
      if (r.error) throw new Error(r.error.message)
      if (r.data && r.data.ok === false) throw new Error(r.data.orientacao ?? 'Não foi possível concluir.')
    },
    onSuccess: () => {
      toast('ok', acao === 'excluir' ? 'Pedido excluído.' : acao === 'cancelar' ? 'Pedido cancelado. O reembolso, se houver, é decisão sua no Mercado Pago.' : 'Pedido arquivado.')
      setAcao(null)
      setMotivo('')
      qc.invalidateQueries({ queryKey: ['orders'] })
      onDone()
    },
    onError: (e: Error) => toast('error', e.message),
  })

  const titulo = acao === 'excluir' ? 'Excluir pedido?' : acao === 'cancelar' ? 'Cancelar pedido pago?' : 'Arquivar pedido?'
  const descricao =
    acao === 'excluir'
      ? order.teste ? 'Pedido de teste: é removido por completo.' : 'O pedido sai do kanban, mas fica o registro de auditoria (quem, quando e motivo). Orçamentos e avisos ligados são cancelados.'
      : acao === 'cancelar'
        ? 'O pedido já foi pago: ele não é apagado. Fica cancelado com o histórico financeiro e você recebe um alerta de reembolso pendente (a decisão é sua).'
        : 'O pedido sai do kanban e fica guardado com o histórico financeiro e a conversa.'

  return (
    <fieldset className="space-y-2 rounded-md border border-brand-red/30 p-3">
      <legend className="px-1 text-xs font-bold uppercase tracking-wide text-brand-red">Zona de risco</legend>
      <div className="flex flex-wrap gap-2">
        {!pago && <Button variant="outline" size="sm" onClick={() => setAcao('excluir')}><Trash2 className="h-4 w-4" /> Excluir pedido</Button>}
        {pago && <Button variant="outline" size="sm" onClick={() => setAcao('cancelar')}>Cancelar pedido pago</Button>}
        {pago && <Button variant="outline" size="sm" onClick={() => setAcao('arquivar')}>Arquivar</Button>}
      </div>
      {pago && <p className="text-xs text-muted-foreground">Pedido com pagamento aprovado nunca é apagado.</p>}
      <Modal open={!!acao} onOpenChange={(o) => !o && setAcao(null)} title={titulo} description={descricao}>
        <label htmlFor="motivo-exclusao" className="text-sm font-bold">Motivo (obrigatório)</label>
        <Textarea id="motivo-exclusao" rows={3} value={motivo} onChange={(e) => setMotivo(e.target.value)} placeholder="Ex.: cliente desistiu antes de pagar" />
        <div className="mt-4 flex justify-end gap-2">
          <Button variant="outline" onClick={() => setAcao(null)}>Voltar</Button>
          <Button variant="destructive" disabled={motivo.trim().length < 5 || executar.isPending} onClick={() => executar.mutate()}>Confirmar</Button>
        </div>
      </Modal>
    </fieldset>
  )
}
