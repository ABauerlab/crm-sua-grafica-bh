import { PackageCheck, Truck } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { useToast } from '@/components/ui/toast'
import { AVISO_LABEL, AVISO_STATUS, useDefinirSubestatus, useMarcarEntregue, usePedidoAvisos } from '@/hooks/etapa7'
import { SUBESTATUS_LABEL, type OrderCard } from '@/lib/orders'
import { cn } from '@/lib/utils'

/** Subestatus do pedido em Produção: botões rápidos, aviso ao cliente e confirmação visual de que a mensagem foi enviada. */
export function StatusPedido({ order, compact = false }: { order: OrderCard; compact?: boolean }) {
  const toast = useToast()
  const { data: avisos } = usePedidoAvisos()
  const sub = useDefinirSubestatus()
  const entregue = useMarcarEntregue()
  if (order.stage !== 'producao') return null
  const meus = (avisos?.get(order.id) ?? []).slice(0, 4)
  const ocupado = sub.isPending || entregue.isPending
  const pago = order.payment_status === 'aprovado' || order.payment_manual

  function definir(s: 'pronto_retirada' | 'saiu_entrega') {
    if (!pago) return toast('error', 'O pedido ainda não está pago. O aviso ao cliente só sai depois do pagamento.')
    let rastreio: string | null = null
    if (s === 'saiu_entrega' && !compact) rastreio = window.prompt('Link ou código de rastreio (deixe em branco para entrega própria)', order.delivery_tracking ?? '')
    sub.mutate(
      { order_id: order.id, sub: s, rastreio },
      {
        onSuccess: (r) => toast('ok', (r as { aviso?: string }).aviso === 'ja_enviado' ? 'O cliente já tinha sido avisado.' : 'Pronto. O aviso ao cliente sai em até 1 minuto.'),
        onError: (e) => toast('error', e.message),
      },
    )
  }
  function concluir() {
    if (!window.confirm('Marcar como entregue? O pedido vai para Entregue e a satisfação e a recompra são agendadas.')) return
    entregue.mutate(order.id, { onSuccess: () => toast('ok', 'Pedido entregue.'), onError: (e) => toast('error', e.message) })
  }

  return (
    <div className={cn('mt-2 rounded-sm bg-secondary/60 p-2', !compact && 'rounded-md border bg-card p-3')} aria-label="Status do pedido">
      <p className="text-[11px] font-bold uppercase tracking-wide text-muted-foreground">
        {order.subestatus_pedido ? SUBESTATUS_LABEL[order.subestatus_pedido] : 'Em produção'}
      </p>
      <div className="mt-1.5 flex flex-wrap gap-1.5">
        {order.delivery_method !== 'uber' && (
          <Button type="button" size="sm" variant={order.subestatus_pedido === 'pronto_retirada' ? 'default' : 'outline'} disabled={ocupado} onClick={() => definir('pronto_retirada')}>
            <PackageCheck className="mr-1 h-3.5 w-3.5" aria-hidden /> Pronto
          </Button>
        )}
        <Button type="button" size="sm" variant={order.subestatus_pedido === 'saiu_entrega' ? 'default' : 'outline'} disabled={ocupado} onClick={() => definir('saiu_entrega')}>
          <Truck className="mr-1 h-3.5 w-3.5" aria-hidden /> Saiu
        </Button>
        <Button type="button" size="sm" variant="outline" disabled={ocupado} onClick={concluir}>Entregue</Button>
      </div>
      {meus.length > 0 && (
        <ul className="mt-2 space-y-0.5 text-[11px]">
          {meus.map((a) => (
            <li key={a.id} className="flex items-center gap-1.5">
              <span className={cn('rounded-sm px-1.5 py-0.5 font-bold', AVISO_STATUS[a.status].chip)}>{AVISO_STATUS[a.status].label}</span>
              <span>{AVISO_LABEL[a.tipo]}{a.enviado_em ? ` em ${new Date(a.enviado_em).toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' })}` : ''}{a.via ? ` (${a.via === 'template' ? 'template' : a.via === 'simulado' ? 'teste' : 'mensagem livre'})` : ''}</span>
              {a.status === 'falhou' && a.erro && <span className="text-brand-red">{a.erro}</span>}
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
