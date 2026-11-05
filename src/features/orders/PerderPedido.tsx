import { useState } from 'react'
import { Button } from '@/components/ui/button'
import { Label } from '@/components/ui/label'
import { Modal } from '@/components/ui/sheet'
import { Select } from '@/components/ui/select'
import { Textarea } from '@/components/ui/textarea'
import { useToast } from '@/components/ui/toast'
import { useRegistrarPerdaPedido } from '@/hooks/orders'
import { MOTIVO_PERDA, type MotivoPerda } from '@/lib/orcamentos'
import type { OrderCard } from '@/lib/orders'

/**
 * Pergunta o motivo antes de mandar o pedido para Perdido (arrastar, menu do card ou ficha).
 * Motivo é obrigatório; observação também quando o motivo é Outro. Pedido pago não entra.
 */
export function PerderPedido({ order, onClose }: { order: OrderCard | null; onClose: () => void }) {
  return (
    <Modal open={!!order} onOpenChange={(o) => !o && onClose()} title={order ? `Pedido #${order.number} perdido` : 'Pedido perdido'} description="Informe o motivo. Ele fica salvo para um disparo futuro.">
      {order && <Formulario key={order.id} order={order} onClose={onClose} />}
    </Modal>
  )
}

function Formulario({ order, onClose }: { order: OrderCard; onClose: () => void }) {
  const toast = useToast()
  const perda = useRegistrarPerdaPedido()
  const [motivo, setMotivo] = useState<MotivoPerda | ''>('')
  const [obs, setObs] = useState('')
  const precisaObs = motivo === 'outro'

  return (
    <div className="space-y-3 p-1">
      <div className="space-y-1.5">
        <Label htmlFor={`perda-pedido-${order.id}`}>Motivo da perda (obrigatório)</Label>
        <Select id={`perda-pedido-${order.id}`} value={motivo} onChange={(e) => setMotivo(e.target.value as MotivoPerda | '')}>
          <option value="">Escolha o motivo</option>
          {(Object.keys(MOTIVO_PERDA) as MotivoPerda[]).map((m) => (
            <option key={m} value={m}>{MOTIVO_PERDA[m]}</option>
          ))}
        </Select>
      </div>
      <div className="space-y-1.5">
        <Label htmlFor={`perda-pedido-obs-${order.id}`}>{precisaObs ? 'Observação (obrigatória)' : 'Observação (opcional)'}</Label>
        <Textarea id={`perda-pedido-obs-${order.id}`} rows={3} maxLength={500} value={obs} onChange={(e) => setObs(e.target.value)} />
      </div>
      <div className="flex flex-wrap justify-end gap-2">
        <Button variant="ghost" onClick={onClose}>Cancelar</Button>
        <Button
          disabled={!motivo || (precisaObs && !obs.trim()) || perda.isPending}
          onClick={() =>
            perda.mutate(
              { orderId: order.id, motivo, obs: obs.trim() || null },
              {
                onSuccess: () => {
                  toast('ok', `Pedido #${order.number} marcado como perdido.`)
                  onClose()
                },
                onError: (e) => toast('error', e.message),
              },
            )
          }
        >
          {perda.isPending ? 'Salvando…' : 'Marcar como perdido'}
        </Button>
      </div>
    </div>
  )
}
