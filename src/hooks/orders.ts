import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import {
  blockReason,
  DEFAULT_KANBAN,
  type KanbanSettings,
  type Order,
  type OrderCard,
  type OrderEvent,
  type OrderFile,
  type OrderFinancials,
  type OrderItem,
  type OrderStage,
} from '@/lib/orders'
import type { OrcamentoStatus } from '@/lib/orcamentos'
import { DEFAULT_PRICING, type PricingRules } from '@/lib/pricing'

const ORDER_SELECT =
  '*, contact:contacts(id,name,wa_id), conversation:conversations(id,ai_handled,unread_count,last_inbound_at), items:order_items(description,qty,code), orcamentos(status,criado_em)'

export function useOrders() {
  return useQuery({
    queryKey: ['orders'],
    queryFn: async (): Promise<OrderCard[]> => {
      const [orders, fins] = await Promise.all([
        supabase.from('orders').select(ORDER_SELECT).is('excluido_em', null).is('arquivado_em', null).order('created_at', { ascending: false }).limit(2000),
        supabase.from('order_financials').select('*').limit(2000),
      ])
      if (orders.error) throw orders.error
      if (fins.error) throw fins.error
      const byId = new Map((fins.data as OrderFinancials[]).map((f) => [f.order_id, f]))
      return (orders.data as unknown as (Omit<OrderCard, 'fin' | 'orcamento_status'> & { orcamentos?: { status: OrcamentoStatus; criado_em: string }[] })[]).map(({ orcamentos, ...o }) => ({
        ...o,
        // status do orçamento mais recente do pedido, para o cartão do kanban
        orcamento_status: [...(orcamentos ?? [])].sort((a, b) => b.criado_em.localeCompare(a.criado_em))[0]?.status ?? null,
        fin: byId.get(o.id) ?? { order_id: o.id, gross: 0, total: 0, cost: 0, tax: 0, fee: 0, net_profit: 0, margin_pct: 0 },
      }))
    },
  })
}

export function useOrderItems(orderId: string | undefined) {
  return useQuery({
    queryKey: ['order-items', orderId],
    enabled: !!orderId,
    queryFn: async () => {
      const { data, error } = await supabase.from('order_items').select('*').eq('order_id', orderId!).order('created_at')
      if (error) throw error
      return data as OrderItem[]
    },
  })
}

export function useOrderEvents(orderId: string | undefined) {
  return useQuery({
    queryKey: ['order-events', orderId],
    enabled: !!orderId,
    queryFn: async () => {
      const { data, error } = await supabase.from('order_events').select('*').eq('order_id', orderId!).order('created_at', { ascending: false })
      if (error) throw error
      return data as OrderEvent[]
    },
  })
}

export function useOrderFiles(orderId: string | undefined) {
  return useQuery({
    queryKey: ['order-files', orderId],
    enabled: !!orderId,
    queryFn: async () => {
      const { data, error } = await supabase.from('order_files').select('*').eq('order_id', orderId!).order('created_at', { ascending: false })
      if (error) throw error
      return data as OrderFile[]
    },
  })
}

export interface AppSettings {
  pricing: PricingRules
  kanban: KanbanSettings
}

export function useSettings() {
  return useQuery({
    queryKey: ['settings'],
    staleTime: 60_000,
    queryFn: async (): Promise<AppSettings> => {
      const { data, error } = await supabase.from('app_settings').select('key,value')
      if (error) throw error
      const get = (k: string) => data.find((r) => r.key === k)?.value as Record<string, unknown> | undefined
      const kanban = get('kanban') as Partial<KanbanSettings> | undefined
      return {
        pricing: { ...DEFAULT_PRICING, ...(get('pricing') as Partial<PricingRules> | undefined) },
        kanban: { stage_limit_hours: { ...DEFAULT_KANBAN.stage_limit_hours, ...(kanban?.stage_limit_hours ?? {}) } },
      }
    },
  })
}

export function useInvalidateOrders() {
  const qc = useQueryClient()
  return (orderId?: string) => {
    qc.invalidateQueries({ queryKey: ['orders'] })
    if (orderId) {
      qc.invalidateQueries({ queryKey: ['order-items', orderId] })
      qc.invalidateQueries({ queryKey: ['order-events', orderId] })
      qc.invalidateQueries({ queryKey: ['order-files', orderId] })
    }
  }
}

/** Mover etapa com atualização otimista, regras de bloqueio e reversão em caso de erro. */
export function useMoveOrder() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async ({ order, to }: { order: OrderCard; to: OrderStage }) => {
      const reason = blockReason(order, to)
      if (reason) throw new Error(reason)
      const { error } = await supabase.from('orders').update({ stage: to }).eq('id', order.id)
      if (error) throw new Error(error.message)
    },
    onMutate: async ({ order, to }) => {
      await qc.cancelQueries({ queryKey: ['orders'] })
      const prev = qc.getQueryData<OrderCard[]>(['orders'])
      qc.setQueryData<OrderCard[]>(['orders'], (old) =>
        old?.map((o) => (o.id === order.id ? { ...o, stage: to, stage_entered_at: new Date().toISOString() } : o)),
      )
      return { prev }
    },
    onError: (_e, _v, ctx) => qc.setQueryData(['orders'], ctx?.prev),
    onSettled: (_d, _e, v) => {
      qc.invalidateQueries({ queryKey: ['orders'] })
      qc.invalidateQueries({ queryKey: ['order-events', v.order.id] })
    },
  })
}

export function useUpdateOrder() {
  const invalidate = useInvalidateOrders()
  return useMutation({
    mutationFn: async ({ id, patch }: { id: string; patch: Partial<Order> }) => {
      const { error } = await supabase.from('orders').update(patch).eq('id', id)
      if (error) throw new Error(error.message)
    },
    onSettled: (_d, _e, v) => invalidate(v.id),
  })
}

export function useAddOrderEvent() {
  const invalidate = useInvalidateOrders()
  return useMutation({
    mutationFn: async ({ orderId, kind, message }: { orderId: string; kind: OrderEvent['kind']; message: string }) => {
      const { error } = await supabase.from('order_events').insert({ order_id: orderId, kind, message })
      if (error) throw new Error(error.message)
    },
    onSettled: (_d, _e, v) => invalidate(v.orderId),
  })
}

export function useCreateOrder() {
  const invalidate = useInvalidateOrders()
  return useMutation({
    mutationFn: async (input: { contactId: string; title: string; metodo: string; parcelas?: number | null }) => {
      if (!input.metodo) throw new Error('Escolha o método de pagamento.')
      const { data: contact, error: cErr } = await supabase
        .from('contacts')
        .select('id, first_referral, conversations(id)')
        .eq('id', input.contactId)
        .single()
      if (cErr) throw new Error(cErr.message)
      const ref = (contact as { first_referral: Record<string, string> | null }).first_referral
      const conv = (contact as { conversations: { id: string }[] | { id: string } | null }).conversations
      const convId = Array.isArray(conv) ? conv[0]?.id : conv?.id
      const { data, error } = await supabase
        .from('orders')
        .insert({
          contact_id: input.contactId,
          conversation_id: convId ?? null,
          title: input.title.trim() || 'Novo pedido',
          payment_method: input.metodo,
          parcelas: input.metodo === 'cartao_credito' ? Math.max(1, input.parcelas ?? 1) : null,
          origin_ad_id: ref?.source_id ?? null,
          origin_label: ref?.headline ?? null,
          origin_url: ref?.source_url ?? null,
        })
        .select('id')
        .single()
      if (error) throw new Error(error.message)
      return data.id as string
    },
    onSettled: () => invalidate(),
  })
}
