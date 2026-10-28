export type OrderStage = 'novo' | 'cotando' | 'aguardando_pagamento' | 'pago' | 'arte' | 'prova' | 'producao' | 'entregue' | 'recompra'
export type PaymentStatus = 'pendente' | 'aprovado' | 'recusado' | 'expirado' | 'estornado'
export type ArtStatus = 'aguardando' | 'em_criacao' | 'enviada' | 'aprovada' | 'ajuste'

export interface StageInfo {
  value: OrderStage
  label: string
  /** Nome curto para faixas e chips */
  short: string
  /** Faixa de cor no topo da coluna */
  bar: string
  /** Chip: fundo translúcido da cor da marca + texto escuro (contraste AA) */
  chip: string
}

export const ORDER_STAGES: StageInfo[] = [
  { value: 'novo', short: 'Novo', label: 'Novo', bar: 'bg-brand-cyan', chip: 'bg-brand-cyan/15 text-ink' },
  { value: 'cotando', short: 'Cotando', label: 'Cotando', bar: 'bg-brand-blue', chip: 'bg-brand-blue/10 text-brand-blue' },
  { value: 'aguardando_pagamento', short: 'Aguardando pgto', label: 'Aguardando pagamento', bar: 'bg-brand-yellow', chip: 'bg-brand-yellow/30 text-ink' },
  { value: 'pago', short: 'Pago', label: 'Pago', bar: 'bg-brand-green', chip: 'bg-brand-green/10 text-brand-green' },
  { value: 'arte', short: 'Arte', label: 'Arte', bar: 'bg-brand-magenta', chip: 'bg-brand-magenta/10 text-ink' },
  { value: 'prova', short: 'Prova', label: 'Prova', bar: 'bg-[#FF8A00]', chip: 'bg-[#FF8A00]/20 text-ink' },
  { value: 'producao', short: 'Produção', label: 'Produção', bar: 'bg-ink', chip: 'bg-ink/10 text-ink' },
  { value: 'entregue', short: 'Entregue', label: 'Entregue', bar: 'bg-brand-green', chip: 'bg-brand-green/10 text-brand-green' },
  { value: 'recompra', short: 'Recompra', label: 'Recompra', bar: 'bg-brand-red', chip: 'bg-brand-red/10 text-brand-red' },
]

export const stageInfo = (s: OrderStage) => ORDER_STAGES.find((x) => x.value === s) ?? ORDER_STAGES[0]

export const PAYMENT_LABELS: Record<PaymentStatus, string> = {
  pendente: 'Pendente',
  aprovado: 'Aprovado',
  recusado: 'Recusado',
  expirado: 'Expirado',
  estornado: 'Estornado',
}

export const ART_LABELS: Record<ArtStatus, string> = {
  aguardando: 'Aguardando',
  em_criacao: 'Em criação',
  enviada: 'Enviada ao cliente',
  aprovada: 'Aprovada',
  ajuste: 'Ajuste solicitado',
}

export interface OrderFinancials {
  order_id: string
  gross: number
  total: number
  cost: number
  tax: number
  fee: number
  net_profit: number
  margin_pct: number
}

export interface Order {
  id: string
  number: number
  contact_id: string
  conversation_id: string | null
  title: string
  stage: OrderStage
  stage_entered_at: string
  notes: string | null
  origin_ad_id: string | null
  origin_label: string | null
  origin_url: string | null
  discount_pct: number
  tax_pct: number
  payment_fee_pct: number
  price_override_reason: string | null
  payment_status: PaymentStatus
  payment_method: string | null
  payment_link: string | null
  payment_external_id: string | null
  payment_confirmed_at: string | null
  payment_manual: boolean
  paid_at: string | null
  art_mode: 'cliente' | 'criamos' | null
  art_status: ArtStatus
  art_approved_at: string | null
  art_checklist: Record<string, boolean>
  supplier_order_no: string | null
  due_date: string | null
  lead_days: number | null
  due_date_manual: boolean
  teste: boolean
  delivery_method: 'retirada' | 'uber' | null
  delivery_address: string | null
  delivery_fee: number | null
  delivery_tracking: string | null
  delivered_at: string | null
  created_at: string
  updated_at: string
}

export interface OrderCard extends Order {
  contact: { id: string; name: string | null; wa_id: string }
  conversation: { id: string; ai_handled: boolean; unread_count: number; last_inbound_at: string | null } | null
  items: { description: string; qty: number; code: string | null }[]
  fin: OrderFinancials
}

export interface OrderItem {
  id: string
  order_id: string
  code: string | null
  description: string
  qty: number
  unit_cost: number
  unit_price: number
  lead_days: number | null
}

export interface OrderEvent {
  id: string
  order_id: string
  kind: 'create' | 'stage' | 'payment' | 'note' | 'price' | 'art' | 'delivery'
  from_stage: OrderStage | null
  to_stage: OrderStage | null
  message: string | null
  created_at: string
}

export interface OrderFile {
  id: string
  order_id: string
  kind: 'arte' | 'prova' | 'anexo'
  version: number
  path: string
  filename: string
  status: 'enviada' | 'aprovada' | 'ajuste' | null
  created_at: string
}

export interface KanbanSettings {
  stage_limit_hours: Record<OrderStage, number>
}

export const DEFAULT_KANBAN: KanbanSettings = {
  stage_limit_hours: {
    novo: 4,
    cotando: 8,
    aguardando_pagamento: 24,
    pago: 12,
    arte: 24,
    prova: 24,
    producao: 72,
    entregue: 0,
    recompra: 0,
  },
}

/** Motivo pelo qual o pedido não pode ir para a etapa (as mesmas regras existem no banco), ou null. */
export function blockReason(o: Pick<Order, 'payment_status' | 'payment_manual' | 'art_status'>, to: OrderStage): string | null {
  if (to === 'pago' && o.payment_status !== 'aprovado' && !o.payment_manual) {
    return 'O pagamento ainda não foi confirmado. Confirme o pagamento (ou marque como pago manualmente) antes de mover para Pago.'
  }
  if (to === 'producao' && o.art_status !== 'aprovada') {
    return 'A arte ainda não foi aprovada pelo cliente. Aprove a arte antes de mover para Produção.'
  }
  return null
}

/** Horas na etapa atual. */
export const hoursInStage = (o: Pick<Order, 'stage_entered_at'>, now = Date.now()) => (now - new Date(o.stage_entered_at).getTime()) / 3_600_000

/** Limite de horas da etapa (0 = sem limite). */
export function isStalled(o: Pick<Order, 'stage' | 'stage_entered_at'>, settings: KanbanSettings, now = Date.now()): boolean {
  const limit = settings.stage_limit_hours[o.stage] ?? 0
  return limit > 0 && hoursInStage(o, now) > limit
}

export function formatDuration(hours: number): string {
  if (hours < 1) return `${Math.max(1, Math.round(hours * 60))} min`
  if (hours < 48) return `${Math.floor(hours)} h`
  return `${Math.floor(hours / 24)} d`
}
