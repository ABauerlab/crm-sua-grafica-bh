import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import type { FunilIA } from '@/lib/types'

const DAY = 86_400_000
/** Data (AAAA-MM-DD) no fuso de Belo Horizonte, n dias atrás (0 = hoje). */
const diaSP = (diasAtras: number) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Sao_Paulo' }).format(new Date(Date.now() - diasAtras * DAY))

/** Linhas diárias do funil da IA no período (1 = hoje; 7, 15 ou 30 dias incluem o dia atual). */
export function useFunilIA(dias: number) {
  const desde = diaSP(dias - 1)
  return useQuery({
    queryKey: ['funil-ia', dias],
    queryFn: async () => {
      const { data, error } = await supabase.from('v_funil_vendas_ia').select('*').gte('data', desde).order('data', { ascending: true })
      if (error) throw error
      return (data ?? []) as FunilIA[]
    },
    staleTime: 60_000,
  })
}

/** Orçamentos criados no período (contagem, sem trazer as linhas). */
export function useOrcamentosIA(dias: number) {
  const desde = `${diaSP(dias - 1)}T00:00:00-03:00`
  return useQuery({
    queryKey: ['orcamentos-ia', dias],
    queryFn: async () => {
      const { count, error } = await supabase.from('orcamentos').select('id', { count: 'exact', head: true }).gte('criado_em', desde)
      if (error) throw error
      return count ?? 0
    },
    staleTime: 60_000,
  })
}
