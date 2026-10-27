import { useEffect } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import type { Contact, ConversationWithContact, Message, Profile, Template } from '@/lib/types'

export function useConversations() {
  return useQuery({
    queryKey: ['conversations'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('conversations')
        .select('*, contact:contacts(*)')
        .order('last_message_at', { ascending: false, nullsFirst: false })
      if (error) throw error
      return data as unknown as ConversationWithContact[]
    },
  })
}

export function useMessages(conversationId: string | undefined) {
  return useQuery({
    queryKey: ['messages', conversationId],
    enabled: !!conversationId,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('messages')
        .select('*')
        .eq('conversation_id', conversationId!)
        .order('created_at', { ascending: true })
        .limit(500)
      if (error) throw error
      return data as Message[]
    },
  })
}

export function useProfiles() {
  return useQuery({
    queryKey: ['profiles'],
    queryFn: async () => {
      const { data, error } = await supabase.from('profiles').select('*').order('name')
      if (error) throw error
      return data as Profile[]
    },
  })
}

export function useTemplates() {
  return useQuery({
    queryKey: ['templates'],
    queryFn: async () => {
      const { data, error } = await supabase.from('templates_cache').select('*').order('name')
      if (error) throw error
      return data as Template[]
    },
  })
}

export function useContacts() {
  return useQuery({
    queryKey: ['contacts'],
    queryFn: async () => {
      const { data, error } = await supabase.from('contacts').select('*').order('created_at', { ascending: false })
      if (error) throw error
      return data as Contact[]
    },
  })
}

/** Mantém o cache do TanStack Query em sincronia com mudanças em tempo real. */
export function useRealtimeSync() {
  const qc = useQueryClient()
  useEffect(() => {
    const channel = supabase
      .channel('crm-realtime')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'messages' }, (payload) => {
        const row = (payload.new ?? payload.old) as Partial<Message>
        if (row.conversation_id) qc.invalidateQueries({ queryKey: ['messages', row.conversation_id] })
        qc.invalidateQueries({ queryKey: ['conversations'] })
      })
      .on('postgres_changes', { event: '*', schema: 'public', table: 'conversations' }, () => {
        qc.invalidateQueries({ queryKey: ['conversations'] })
        qc.invalidateQueries({ queryKey: ['orders'] })
      })
      .on('postgres_changes', { event: '*', schema: 'public', table: 'orders' }, () => {
        qc.invalidateQueries({ queryKey: ['orders'] })
      })
      .subscribe()
    return () => {
      supabase.removeChannel(channel)
    }
  }, [qc])
}

export interface QualityAlert {
  level: 'warning' | 'danger'
  title: string
  detail: string
}

const QUALITY_DAYS = 7

/** Sinais de risco para a qualidade do número no WhatsApp (falhas de entrega e pedidos de PARAR nos últimos 7 dias). */
export function useQualityAlerts() {
  return useQuery({
    queryKey: ['quality-alerts'],
    refetchInterval: 5 * 60_000,
    queryFn: async (): Promise<QualityAlert[]> => {
      const since = new Date(Date.now() - QUALITY_DAYS * 86_400_000).toISOString()
      const count = async (q: PromiseLike<{ count: number | null; error: unknown }>) => {
        const { count: n, error } = await q
        if (error) throw error
        return n ?? 0
      }
      const [sent, failed, templates, optOuts] = await Promise.all([
        count(supabase.from('messages').select('id', { count: 'exact', head: true }).eq('direction', 'out').gte('created_at', since)),
        count(supabase.from('messages').select('id', { count: 'exact', head: true }).eq('direction', 'out').eq('status', 'failed').gte('created_at', since)),
        count(supabase.from('messages').select('id', { count: 'exact', head: true }).eq('direction', 'out').eq('type', 'template').gte('created_at', since)),
        count(supabase.from('contacts').select('id', { count: 'exact', head: true }).eq('marketing_consent', 'opted_out').eq('marketing_consent_source', 'whatsapp').gte('marketing_consent_at', since)),
      ])

      const alerts: QualityAlert[] = []
      if (sent >= 20 && failed / sent >= 0.1) {
        const pct = Math.round((failed / sent) * 100)
        alerts.push({
          level: failed / sent >= 0.2 ? 'danger' : 'warning',
          title: `${pct}% das mensagens falharam nos últimos ${QUALITY_DAYS} dias`,
          detail: 'Muitas falhas derrubam a qualidade do número. Confira se os telefones têm WhatsApp e evite listas antigas.',
        })
      }
      if (optOuts >= 3 && templates >= 30 && optOuts / templates >= 0.03) {
        const pct = Math.round((optOuts / templates) * 100)
        alerts.push({
          level: optOuts / templates >= 0.05 ? 'danger' : 'warning',
          title: `${optOuts} pedidos de PARAR em ${QUALITY_DAYS} dias (${pct}% dos templates enviados)`,
          detail: 'Muitos descadastros e denúncias reduzem seu limite de envio. Reduza a frequência e envie só para quem autorizou.',
        })
      }
      return alerts
    },
  })
}
