import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'

export interface AgentSettings {
  enabled: boolean
  hours: { start: string; end: string; days: number[] }
  handoff_message: string
}

export interface CompanySettings {
  name: string
  legal_name: string
  cnpj: string
  address: string
  email: string
  phone: string
  hours: string
}

export interface CampaignGoals {
  max_cost_per_conversation: number
  max_cost_per_sale: number
  min_roas: number
}

export const DEFAULTS = {
  agent: { enabled: false, hours: { start: '08:00', end: '18:00', days: [1, 2, 3, 4, 5] }, handoff_message: 'Vou chamar um atendente para te ajudar. Um instante!' } as AgentSettings,
  company: { name: 'Sua Gráfica BH', legal_name: '', cnpj: '', address: '', email: '', phone: '', hours: '' } as CompanySettings,
  labels: ['dúvida', 'orçamento', 'reclamação', 'arte', 'recompra'] as string[],
  campaign_goals: { max_cost_per_conversation: 6, max_cost_per_sale: 60, min_roas: 4 } as CampaignGoals,
  repurchase: { days: 45 } as { days: number },
}

type Key = keyof typeof DEFAULTS

/** Lê uma configuração (tabela app_settings) mesclada com o padrão. */
export function useSetting<K extends Key>(key: K) {
  return useQuery({
    queryKey: ['setting', key],
    staleTime: 30_000,
    queryFn: async (): Promise<(typeof DEFAULTS)[K]> => {
      const { data, error } = await supabase.from('app_settings').select('value').eq('key', key).maybeSingle()
      if (error) throw error
      const v = data?.value
      const d = DEFAULTS[key]
      if (Array.isArray(d)) return (Array.isArray(v) ? v : d) as (typeof DEFAULTS)[K]
      return { ...(d as object), ...((v as object) ?? {}) } as (typeof DEFAULTS)[K]
    },
  })
}

export function useSaveSetting<K extends Key>(key: K) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (value: (typeof DEFAULTS)[K]) => {
      const { error } = await supabase.from('app_settings').upsert({ key, value, updated_at: new Date().toISOString() })
      if (error) throw new Error(error.message)
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['setting', key] }),
  })
}
