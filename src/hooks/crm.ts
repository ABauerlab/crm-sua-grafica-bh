import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import type { ContactStats, ConversationNote, QuickReply, Task } from '@/lib/types'

export function useQuickReplies() {
  return useQuery({
    queryKey: ['quick-replies'],
    staleTime: 60_000,
    queryFn: async () => {
      const { data, error } = await supabase.from('quick_replies').select('*').order('shortcut')
      if (error) throw error
      return data as QuickReply[]
    },
  })
}

export function useNotes(conversationId: string | undefined) {
  return useQuery({
    queryKey: ['notes', conversationId],
    enabled: !!conversationId,
    queryFn: async () => {
      const { data, error } = await supabase.from('conversation_notes').select('*').eq('conversation_id', conversationId!).order('created_at')
      if (error) throw error
      return data as ConversationNote[]
    },
  })
}

export function useContactStats() {
  return useQuery({
    queryKey: ['contact-stats'],
    queryFn: async () => {
      const { data, error } = await supabase.from('contact_stats').select('*').limit(5000)
      if (error) throw error
      return new Map((data as ContactStats[]).map((s) => [s.contact_id, s]))
    },
  })
}

export function useTasks() {
  return useQuery({
    queryKey: ['tasks'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('tasks')
        .select('*, contact:contacts(id,name,wa_id), order:orders(id,number,title)')
        .order('due_at', { ascending: true, nullsFirst: false })
        .limit(1000)
      if (error) throw error
      return data as unknown as (Task & { contact: { id: string; name: string | null; wa_id: string } | null; order: { id: string; number: number; title: string } | null })[]
    },
  })
}
