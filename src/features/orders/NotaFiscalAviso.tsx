import { useMutation } from '@tanstack/react-query'
import { Button } from '@/components/ui/button'
import { useToast } from '@/components/ui/toast'
import { useInvalidateOrders } from '@/hooks/orders'
import { invokeFunction } from '@/lib/api'
import { resumoNfFaltando } from '@/lib/nota-fiscal'
import type { OrderCard } from '@/lib/orders'

/** Marcador "faltam dados da NF" no pedido pago. Com o CEP já informado, completa rua, bairro, cidade, UF e IBGE. */
export function NotaFiscalAviso({ order }: { order: OrderCard }) {
  const toast = useToast()
  const invalidate = useInvalidateOrders()
  const completar = useMutation({
    mutationFn: () => invokeFunction('contato-cep-completar', { contact_id: order.contact.id }),
    onSuccess: () => { toast('ok', 'Endereço completado pelo CEP.'); invalidate() },
    onError: (e: Error) => toast('error', e.message),
  })
  const texto = resumoNfFaltando(order.nf_faltantes)
  if (!texto) return null
  return (
    <div className="flex flex-wrap items-center justify-between gap-2 rounded-md border border-brand-yellow bg-brand-yellow/15 px-3 py-2 text-sm" role="status">
      <p className="font-semibold">{texto}</p>
      {order.nf_faltantes?.includes('endereco') && (
        <Button type="button" size="sm" variant="outline" disabled={completar.isPending} onClick={() => completar.mutate()}>
          {completar.isPending ? 'Buscando…' : 'Completar pelo CEP'}
        </Button>
      )}
    </div>
  )
}
