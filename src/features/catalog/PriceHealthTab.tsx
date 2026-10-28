import { useQuery } from '@tanstack/react-query'
import { BarChart3 } from 'lucide-react'
import { EmptyState, ErrorState } from '@/components/ui/empty-state'
import { Skeleton } from '@/components/ui/skeleton'
import { formatPct } from '@/lib/money'
import { supabase } from '@/lib/supabase'

type Saude = {
  grupo_produto: string | null
  itens_ativos: number
  cobertura_mercado: number
  nao_competitivos: number
  nao_vender: number
  margem_liquida_media: number | null
  orcamentos_30d: number
  ganhos_30d: number
}

/** Painel interno: mostra dados de mercado e resultado, nunca custo ou piso ao cliente. */
export function PriceHealthTab() {
  const q = useQuery({
    queryKey: ['saude-precos'],
    queryFn: async () => {
      const { data, error } = await supabase.from('saude_precos').select('*').order('grupo_produto').limit(500)
      if (error) throw error
      return data as Saude[]
    },
  })
  const ajustes = useQuery({
    queryKey: ['ajustes-preco'],
    queryFn: async () => {
      const { data, error } = await supabase.from('ajustes_fator_preco').select('*').order('criado_em', { ascending: false }).limit(20)
      if (error) throw error
      return data as { id: string; grupo_produto: string; fator_antes: number; fator_depois: number; motivo: string; criado_em: string }[]
    },
  })
  if (q.isLoading) return <div className="space-y-2 p-4"><Skeleton className="h-12 w-full" /><Skeleton className="h-12 w-full" /></div>
  if (q.error) return <ErrorState message="Não foi possível carregar a saúde de preços." onRetry={() => q.refetch()} />
  if (!(q.data ?? []).length) return <EmptyState icon={BarChart3} title="Ainda não há dados de preço">A cobertura aparece quando as pesquisas sob demanda forem concluídas.</EmptyState>
  return <div className="min-h-0 flex-1 space-y-5 overflow-auto p-4">
    <p className="text-sm text-muted-foreground">Painel interno. A pesquisa é feita somente quando há orçamento; nenhum preço de custo aparece para o cliente.</p>
    <div className="overflow-x-auto rounded-md border">
      <table className="w-full min-w-[760px] text-sm">
        <thead><tr className="border-b text-left text-[11px] uppercase tracking-wide text-muted-foreground"><th className="px-3 py-2">Grupo</th><th className="py-2 text-right">Cobertura</th><th className="py-2 text-right">Margem líquida</th><th className="py-2 text-right">Não competitivo</th><th className="py-2 text-right">Não vender</th><th className="px-3 py-2 text-right">Conversão 30 dias</th></tr></thead>
        <tbody>{q.data!.map((r) => {
          const conv = r.orcamentos_30d ? r.ganhos_30d / r.orcamentos_30d : null
          return <tr key={r.grupo_produto ?? 'sem-grupo'} className="border-b last:border-0"><td className="px-3 py-2 font-semibold">{r.grupo_produto || 'Sem grupo'}</td><td className="py-2 text-right tabular">{r.cobertura_mercado}/{r.itens_ativos}</td><td className="py-2 text-right tabular">{r.margem_liquida_media == null ? '—' : formatPct(r.margem_liquida_media, 1)}</td><td className="py-2 text-right tabular">{r.nao_competitivos}</td><td className="py-2 text-right tabular">{r.nao_vender}</td><td className="px-3 py-2 text-right tabular">{conv == null ? '—' : formatPct(conv * 100, 1)}</td></tr>
        })}</tbody>
      </table>
    </div>
    <section><h2 className="mb-2 text-sm font-black">Ajustes automáticos do fator</h2>{ajustes.isLoading ? <Skeleton className="h-20 w-full" /> : (ajustes.data ?? []).length === 0 ? <p className="rounded-md border border-dashed p-3 text-sm text-muted-foreground">Nenhum ajuste ainda. São necessários ao menos 8 orçamentos no grupo em 30 dias.</p> : <ul className="divide-y rounded-md border">{ajustes.data!.map((a) => <li className="p-3 text-sm" key={a.id}><strong>{a.grupo_produto}</strong>: {a.fator_antes.toFixed(2)} → {a.fator_depois.toFixed(2)}<p className="text-xs text-muted-foreground">{a.motivo} · {new Date(a.criado_em).toLocaleDateString('pt-BR')}</p></li>)}</ul>}</section>
  </div>
}
