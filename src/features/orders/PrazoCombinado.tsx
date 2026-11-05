import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { useToast } from '@/components/ui/toast'
import { useUpdateOrder } from '@/hooks/orders'
import type { OrderCard } from '@/lib/orders'

/**
 * Data de entrega combinada com o cliente. Ao escolher uma data, ela fica marcada como manual e o cálculo
 * automático do banco para de mexer nela. "Recalcular pelo sistema" desliga a marcação e o trigger refaz a conta.
 */
export function PrazoCombinado({ order }: { order: OrderCard }) {
  const toast = useToast()
  const update = useUpdateOrder()
  const manual = !!order.due_date_manual
  const id = order.id

  return (
    <div className="space-y-1.5">
      <div className="flex flex-wrap items-center gap-2">
        <Label htmlFor={`prazo-${id}`}>Data de entrega / prazo combinado</Label>
        {manual && <Badge className="rounded-sm bg-brand-yellow/30 px-1.5 py-0.5 text-[11px] font-semibold text-ink">Prazo manual / combinado</Badge>}
      </div>
      <Input
        id={`prazo-${id}`}
        type="date"
        value={order.due_date ?? ''}
        disabled={update.isPending}
        onChange={(e) => {
          if (!e.target.value) return
          update.mutate(
            { id, patch: { due_date: e.target.value, due_date_manual: true } },
            { onSuccess: () => toast('ok', 'Prazo combinado salvo.'), onError: (err) => toast('error', err.message) },
          )
        }}
      />
      <p className="text-xs text-muted-foreground">
        {manual
          ? 'Data combinada à mão: o sistema não altera mais este prazo.'
          : order.lead_days != null
            ? `Automático: ${order.lead_days} dia(s) úteis do fornecedor a partir do pagamento confirmado e da arte aprovada.`
            : 'Calculado sozinho quando o pagamento for confirmado e algum item tiver prazo.'}
      </p>
      {manual && (
        <Button
          size="sm"
          variant="ghost"
          disabled={update.isPending}
          onClick={() =>
            update.mutate(
              { id, patch: { due_date_manual: false, due_date: null } },
              { onSuccess: () => toast('ok', 'Prazo voltou para o cálculo automático.'), onError: (err) => toast('error', err.message) },
            )
          }
        >
          Recalcular pelo sistema
        </Button>
      )}
    </div>
  )
}
