export type OrderStage = 'novo' | 'cotando' | 'aguardando_pagamento' | 'pago' | 'arte' | 'prova' | 'producao' | 'entregue' | 'recompra' | 'perdido'
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
  { value: 'perdido', short: 'Perdido', label: 'Perdido', bar: 'bg-ink/60', chip: 'bg-ink/10 text-ink' },
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
  aguardando: 'Aguardando arte',
  em_criacao: 'Em ajuste / gabarito',
  enviada: 'Arte recebida (do cliente)',
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
  motivo_perda: string | null
  motivo_perda_obs: string | null
  motivo_perda_em: string | null
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
  subestatus_pedido: 'em_producao' | 'pronto_retirada' | 'saiu_entrega' | null
  subestatus_em: string | null
  parcelas: number | null
  taxa_fonte: 'estimada' | 'metodo' | 'mercado_pago'
  taxa_pagamento_real_valor: number | null
  liquido_recebido: number | null
  urgente: boolean
  urgente_motivo: string | null
  urgente_em: string | null
  excluido_em: string | null
  arquivado_em: string | null
  cancelado_em: string | null
  reembolso_pendente: boolean
  enviado_fabrica_em: string | null
  created_at: string
  updated_at: string
}

export interface OrderCard extends Order {
  contact: { id: string; name: string | null; wa_id: string }
  conversation: { id: string; ai_handled: boolean; unread_count: number; last_inbound_at: string | null } | null
  items: { description: string; qty: number; code: string | null }[]
  fin: OrderFinancials
  /** Status do orçamento mais recente do pedido (null quando não há orçamento) */
  orcamento_status?: import('./orcamentos').OrcamentoStatus | null
}

export interface OrderItem {
  id: string
  order_id: string
  code: string | null
  fora_catalogo?: boolean
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
    perdido: 0,
  },
}

/** Motivo pelo qual o pedido não pode ir para a etapa (as mesmas regras existem no banco), ou null. */
export function blockReason(o: Pick<Order, 'payment_status' | 'payment_manual' | 'art_status'>, to: OrderStage): string | null {
  if (to === 'perdido') return 'Para marcar como perdido, informe o motivo.'
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

export const SUBESTATUS_LABEL: Record<'em_producao' | 'pronto_retirada' | 'saiu_entrega', string> = {
  em_producao: 'Em produção',
  pronto_retirada: 'Pronto para retirada',
  saiu_entrega: 'Saiu para entrega',
}

/** Métodos que o dono escolhe no pedido manual. Dinheiro e transferência não têm taxa; crédito aceita parcelas. */
export const METODOS_PAGAMENTO = [
  { value: 'pix', label: 'Pix' },
  { value: 'cartao_credito', label: 'Cartão de crédito' },
  { value: 'cartao_debito', label: 'Cartão de débito' },
  { value: 'dinheiro', label: 'Dinheiro' },
  { value: 'transferencia', label: 'Transferência' },
  { value: 'outro', label: 'Outro' },
] as const
export type MetodoPagamento = (typeof METODOS_PAGAMENTO)[number]['value']
export const metodoValido = (m: string | null | undefined): m is MetodoPagamento => METODOS_PAGAMENTO.some((x) => x.value === m)
export const metodoLabel = (m: string | null | undefined) => METODOS_PAGAMENTO.find((x) => x.value === m)?.label ?? (m === 'cartao' ? 'Cartão' : m || 'Não definido')

/**
 * Regra única de atraso (a mesma de public.pedido_esta_atrasado): só é atrasado o pedido que JÁ está em produção,
 * não foi entregue e passou do prazo útil. Antes da produção nunca é atrasado. `hoje` no formato AAAA-MM-DD.
 */
export function pedidoAtrasado(o: Pick<Order, 'stage' | 'due_date' | 'delivered_at'>, hoje: string): boolean {
  return o.stage === 'producao' && !o.delivered_at && !!o.due_date && o.due_date < hoje
}
