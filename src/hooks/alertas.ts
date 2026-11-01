import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'

export interface Alerta {
  id: string
  tipo: string
  gravidade: 'alta' | 'baixa'
  motivo: string
  status_whatsapp: string | null
  status_push: string | null
  criado_em: string
  lido_em: string | null
  dados: { url?: string; cliente?: string } | null
}

export interface Aparelho {
  id: string
  dispositivo: string | null
  ativo: boolean
  criado_em: string
  ultimo_envio_em: string | null
}

export function useAlertas(limit = 30) {
  return useQuery({
    queryKey: ['alertas', limit],
    refetchInterval: 60_000,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('alertas')
        .select('id, tipo, gravidade, motivo, status_whatsapp, status_push, criado_em, lido_em, dados')
        .order('criado_em', { ascending: false })
        .limit(limit)
      if (error) throw error
      return data as Alerta[]
    },
  })
}

/** Pendências = avisos de gravidade alta ainda não lidos nas últimas 48 h (o mesmo número do selo do ícone). */
export function useAlertasPendentes() {
  return useQuery({
    queryKey: ['alertas-pendentes'],
    refetchInterval: 60_000,
    queryFn: async () => {
      const desde = new Date(Date.now() - 48 * 3_600_000).toISOString()
      const { count, error } = await supabase
        .from('alertas')
        .select('id', { count: 'exact', head: true })
        .is('lido_em', null)
        .eq('gravidade', 'alta')
        .neq('tipo', 'resumo')
        .gte('criado_em', desde)
      if (error) throw error
      return count ?? 0
    },
  })
}

export function useMarcarLidos() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (ids?: string[]) => {
      let q = supabase.from('alertas').update({ lido_em: new Date().toISOString() }).is('lido_em', null)
      if (ids) q = q.in('id', ids)
      const { error } = await q
      if (error) throw new Error(error.message)
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['alertas'] })
      void qc.invalidateQueries({ queryKey: ['alertas-pendentes'] })
    },
  })
}

export function useAparelhos() {
  return useQuery({
    queryKey: ['aparelhos-push'],
    queryFn: async () => {
      const { data, error } = await supabase.from('push_subscriptions').select('id, dispositivo, ativo, criado_em, ultimo_envio_em').eq('ativo', true).order('criado_em', { ascending: false })
      if (error) throw error
      return data as Aparelho[]
    },
  })
}
