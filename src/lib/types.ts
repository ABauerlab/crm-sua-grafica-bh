export type Role = 'admin' | 'agent'
export type ConversationStatus = 'open' | 'pending' | 'closed'
export type Stage = 'novo' | 'orcamento' | 'negociando' | 'fechado' | 'perdido'
export type MarketingConsent = 'none' | 'opted_in' | 'opted_out'
export type ConsentSource = 'whatsapp' | 'manual' | 'formulario' | 'loja' | 'outro'
export type MessageType = 'text' | 'image' | 'document' | 'audio' | 'template' | 'other'
export type MessageStatus = 'sent' | 'delivered' | 'read' | 'failed'

export interface Profile {
  id: string
  name: string
  role: Role
  created_at: string
}

export interface Contact {
  id: string
  wa_id: string
  name: string | null
  notes: string | null
  tags: string[]
  marketing_consent: MarketingConsent
  marketing_consent_at: string | null
  marketing_consent_source: ConsentSource | null
  first_referral?: Record<string, string> | null
  first_referral_at?: string | null
  email?: string | null
  document?: string | null
  company?: string | null
  segment?: 'barbearia' | 'delivery' | 'loja' | 'outro' | null
  address?: string | null
  created_at: string
}

export interface Conversation {
  id: string
  contact_id: string
  status: ConversationStatus
  stage: Stage
  assigned_to: string | null
  ai_handled: boolean
  last_message_at: string | null
  last_message_preview: string | null
  last_inbound_at: string | null
  unread_count: number
  attendant_changed_at?: string | null
  attendant_change_reason?: string | null
  needs_human?: boolean
  summary?: string | null
  collected_data?: Record<string, unknown>
  labels?: string[]
  ad_window_until?: string | null
  last_referral?: Record<string, string> | null
  created_at: string
}

export interface ConversationWithContact extends Conversation {
  contact: Contact
}

export interface Message {
  id: string
  conversation_id: string
  wa_message_id: string | null
  direction: 'in' | 'out'
  type: 'text' | 'image' | 'document' | 'audio' | 'template' | 'other'
  body: string | null
  template_name: string | null
  media_id: string | null
  media_path: string | null
  status: MessageStatus | null
  error: string | null
  created_at: string
}

export interface Template {
  name: string
  language: string
  category: string | null
  status: string | null
  body: string | null
  has_opt_out_button: boolean
  synced_at: string
}

export interface ConversationNote {
  id: string
  conversation_id: string
  body: string
  created_at: string
}

export interface QuickReply {
  id: string
  shortcut: string
  title: string
  body: string
}

export interface ContactStats {
  contact_id: string
  orders_count: number
  paid_orders: number
  ltv: number
  profit: number
  last_order_at: string | null
}

export interface Task {
  id: string
  title: string
  due_at: string | null
  priority: 'baixa' | 'media' | 'alta'
  contact_id: string | null
  order_id: string | null
  kind: 'cobrar_pagamento' | 'aprovar_prova' | 'avisar_entrega' | 'recompra' | null
  done_at: string | null
  created_at: string
}

export interface Product {
  id: string
  code: string
  description: string
  category: string | null
  supplier: string
  colors: string | null
  weight: number | null
  grammage: number | null
  qty: number | null
  size: string | null
  lead_days: number | null
  cost: number
  suggested_price: number
  active: boolean
  floor_price: number
  max_discount_price: number
  est_net_profit: number
}

export interface Kit {
  id: string
  name: string
  segment: 'barbearia' | 'delivery' | 'loja' | 'lancamento' | 'outro' | null
  description: string | null
  price: number
  active: boolean
}

export interface KitItem {
  id: string
  kit_id: string
  product_id: string | null
  description: string
  qty: number
  unit_cost: number
}

export interface AdPerformance {
  ad_id: string
  ad_name: string | null
  adset_id: string | null
  adset_name: string | null
  campaign_id: string | null
  campaign_name: string | null
  spend: number
  impressions: number
  clicks: number
  meta_conversations: number
  conversations: number
  quotes: number
  paid_orders: number
  revenue: number
  net_profit: number
}

export interface AgentLog {
  id: string
  conversation_id: string | null
  actor: 'ia' | 'humano' | 'sistema'
  action: string
  detail: Record<string, unknown>
  result: string | null
  created_at: string
}
