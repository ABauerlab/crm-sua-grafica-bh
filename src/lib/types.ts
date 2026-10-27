export type Role = 'admin' | 'agent'
export type ConversationStatus = 'open' | 'pending' | 'closed'
export type Stage = 'novo' | 'orcamento' | 'negociando' | 'fechado' | 'perdido'
export type MarketingConsent = 'none' | 'opted_in' | 'opted_out'
export type ConsentSource = 'whatsapp' | 'manual' | 'formulario' | 'loja' | 'outro'
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
