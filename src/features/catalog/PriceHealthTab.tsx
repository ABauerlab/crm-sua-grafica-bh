import { useQuery } from '@tanstack/react-query'
import { BarChart3, ChevronDown } from 'lucide-react'
import { useState } from 'react'
import { SkuBadge } from '@/components/SkuBadge'
import { EmptyState, ErrorState } from '@/components/ui/empty-state'
import { Skeleton } from '@/components/ui/skeleton'
import { formatBRL, formatPct } from '@/lib/money'
import { supabase } from '@/lib/supabase'
import { cn } from '@/lib/utils'

type Saude = {
  grupo_produto: string | null
  itens_ativos: number
  cobertura_mercado: number
  nao_competitivos: number
  nao_vender: number
  margem_liquida_media: number | null
  orcamentos_30d: number
  ganhos_30d: number
  fator_atual: number | null
}
type Ajuste = { id: string; grupo_produto: string; fator_antes: number; fator_depois: number; motivo: string; criado_em: string }
type Consulta = { id: string; sku: string | null; status: string; confianca: string | null; mediana: number | null; minimo: number | null; maximo: number | null; fontes_validas: number; duracao_ms: number | null; requisicoes: number; tokens_usados: number; criado_em: string }
type Fonte = { id: string; fonte: string; url: string | null; preco: number; outlier: boolean; motivo_descarte: string | null; coletado_em: string }
type ItemRuim = { sku: string; descricao: string | null; status_venda: string; grupo_produto: string | null }
type Relatorio = { degraus: { degrau: number; ofertas: number; aceitas: number; conversao_pct: number | null; margem_media_pct: number; receita: number; desconto_total: number }[]; consumo_da_margem_pct: number; receita_incremental_estimada: number; sugestoes: string[] }
type Resumo = { id: string; motivo: string; criado_em: string }

const STATUS: Record<string, string> = { concluida: 'Pesquisada', cache: 'Cache', sem_dado: 'Sem dado', erro: 'Erro', pendente: 'Em andamento' }
const fmtData = (d: string) => new Date(d).toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' })

/** Painel interno (só o dono): mostra mercado, margem, conversão e ajustes. Custo e piso nunca vão para o cliente nem para o agente. */
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
      return data as Ajuste[]
    },
  })
  const consultas = useQuery({
    queryKey: ['consultas-mercado'],
    queryFn: async () => {
      const { data, error } = await supabase.from('consultas_preco_mercado').select('id, sku, status, confianca, mediana, minimo, maximo, fontes_validas, duracao_ms, requisicoes, tokens_usados, criado_em').order('criado_em', { ascending: false }).limit(20)
      if (error) throw error
      return data as Consulta[]
    },
  })
  const ruins = useQuery({
    queryKey: ['itens-nao-competitivos'],
    queryFn: async () => {
      const { data, error } = await supabase.from('catalogo').select('sku, descricao, status_venda, grupo_produto').in('status_venda', ['nao_competitivo', 'nao_vender']).eq('active', true).order('grupo_produto').limit(60)
      if (error) throw error
      return data as ItemRuim[]
    },
  })
  const relatorio = useQuery({
    queryKey: ['relatorio-condicoes-30'],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('relatorio_condicoes_semana', { p_dias: 30, p_alertar: false })
      if (error) throw new Error(error.message)
      return data as Relatorio
    },
  })
  const resumo = useQuery({
    queryKey: ['resumo-semanal-precos'],
    queryFn: async () => {
      const { data, error } = await supabase.from('alertas').select('id, motivo, criado_em').eq('tipo', 'resumo_semanal_precos').order('criado_em', { ascending: false }).limit(1)
      if (error) throw error
      return (data ?? []) as Resumo[]
    },
  })

  if (q.isLoading) return <div className="space-y-2 p-4"><Skeleton className="h-12 w-full" /><Skeleton className="h-12 w-full" /></div>
  if (q.error) return <ErrorState message="Não foi possível carregar a saúde de preços." onRetry={() => q.refetch()} />
  const linhas = q.data ?? []
  if (!linhas.length) return <EmptyState icon={BarChart3} title="Ainda não há dados de preço">A cobertura aparece quando as pesquisas sob demanda forem concluídas.</EmptyState>

  const ativos = linhas.reduce((n, r) => n + r.itens_ativos, 0)
  const cobertos = linhas.reduce((n, r) => n + r.cobertura_mercado, 0)
  const orc = linhas.reduce((n, r) => n + r.orcamentos_30d, 0)
  const ganhos = linhas.reduce((n, r) => n + r.ganhos_30d, 0)
  const comMargem = linhas.filter((r) => r.margem_liquida_media != null)
  const margem = comMargem.length ? comMargem.reduce((n, r) => n + (r.margem_liquida_media ?? 0), 0) / comMargem.length : null
  const naoComp = linhas.reduce((n, r) => n + r.nao_competitivos, 0)
  const naoVender = linhas.reduce((n, r) => n + r.nao_vender, 0)

  return (
    <div className="min-h-0 flex-1 space-y-6 overflow-auto p-4">
      <p className="text-sm text-muted-foreground">Painel interno. A pesquisa de mercado só acontece quando há orçamento (cache de 14 dias); nenhum custo, piso ou margem aparece para o cliente.</p>

      <dl className="grid grid-cols-2 gap-3 lg:grid-cols-5">
        <Card titulo="Cobertura de mercado" valor={ativos ? formatPct((cobertos / ativos) * 100, 1) : '0%'} nota={`${cobertos} de ${ativos} itens com mercado válido`} />
        <Card titulo="Margem líquida média" valor={margem == null ? '—' : formatPct(margem, 1)} nota="orçamentos dos últimos 30 dias" />
        <Card titulo="Conversão 30 dias" valor={orc ? formatPct((ganhos / orc) * 100, 1) : '—'} nota={`${ganhos} ganhos em ${orc} orçamentos`} />
        <Card titulo="Não competitivos" valor={String(naoComp)} nota="mercado abaixo do piso" />
        <Card titulo="Fora de venda" valor={String(naoVender)} nota="status nao_vender" />
      </dl>

      {resumo.data?.[0] && (
        <section className="rounded-md border p-3">
          <h2 className="text-sm font-black">Resumo semanal ao dono</h2>
          <p className="mt-1 text-sm">{resumo.data[0].motivo}</p>
          <p className="text-xs text-muted-foreground">Gerado em {fmtData(resumo.data[0].criado_em)}</p>
        </section>
      )}

      <section>
        <h2 className="mb-2 text-sm font-black">Por grupo</h2>
        <div className="overflow-x-auto rounded-md border">
          <table className="w-full min-w-[820px] text-sm">
            <thead><tr className="border-b text-left text-[11px] uppercase tracking-wide text-muted-foreground"><th className="px-3 py-2">Grupo</th><th className="py-2 text-right">Cobertura</th><th className="py-2 text-right">Fator</th><th className="py-2 text-right">Margem líquida</th><th className="py-2 text-right">Não competitivo</th><th className="py-2 text-right">Não vender</th><th className="px-3 py-2 text-right">Conversão 30 dias</th></tr></thead>
            <tbody>{linhas.map((r) => {
              const conv = r.orcamentos_30d ? r.ganhos_30d / r.orcamentos_30d : null
              return <tr key={r.grupo_produto ?? 'sem-grupo'} className="border-b last:border-0"><td className="px-3 py-2 font-semibold">{r.grupo_produto || 'Sem grupo'}</td><td className="py-2 text-right tabular">{r.cobertura_mercado}/{r.itens_ativos}</td><td className="py-2 text-right tabular">{r.fator_atual == null ? 'padrão' : r.fator_atual.toFixed(2)}</td><td className="py-2 text-right tabular">{r.margem_liquida_media == null ? '—' : formatPct(r.margem_liquida_media, 1)}</td><td className="py-2 text-right tabular">{r.nao_competitivos}</td><td className="py-2 text-right tabular">{r.nao_vender}</td><td className="px-3 py-2 text-right tabular">{conv == null ? '—' : formatPct(conv * 100, 1)}</td></tr>
            })}</tbody>
          </table>
        </div>
      </section>

      <section>
        <h2 className="mb-2 text-sm font-black">Fontes de cada preço (últimas pesquisas)</h2>
        {consultas.isLoading ? <Skeleton className="h-20 w-full" /> : (consultas.data ?? []).length === 0 ? (
          <p className="rounded-md border border-dashed p-3 text-sm text-muted-foreground">Nenhuma pesquisa ainda. Elas começam no primeiro orçamento depois que o workflow de pesquisa for ativado.</p>
        ) : (
          <ul className="divide-y rounded-md border">{consultas.data!.map((c) => <ConsultaLinha key={c.id} c={c} />)}</ul>
        )}
      </section>

      <section>
        <h2 className="mb-2 text-sm font-black">Condições especiais (30 dias)</h2>
        {relatorio.isLoading ? <Skeleton className="h-20 w-full" /> : relatorio.error ? <p className="text-sm text-muted-foreground">Relatório indisponível.</p> : (
          <div className="space-y-2">
            {(relatorio.data?.degraus ?? []).length === 0 ? <p className="rounded-md border border-dashed p-3 text-sm text-muted-foreground">Nenhuma condição oferecida no período.</p> : (
              <div className="overflow-x-auto rounded-md border">
                <table className="w-full min-w-[640px] text-sm">
                  <thead><tr className="border-b text-left text-[11px] uppercase tracking-wide text-muted-foreground"><th className="px-3 py-2">Degrau</th><th className="py-2 text-right">Ofertas</th><th className="py-2 text-right">Aceitas</th><th className="py-2 text-right">Conversão</th><th className="py-2 text-right">Margem após desconto</th><th className="px-3 py-2 text-right">Desconto dado</th></tr></thead>
                  <tbody>{relatorio.data!.degraus.map((d) => <tr key={d.degrau} className="border-b last:border-0"><td className="px-3 py-2 font-semibold">{d.degrau}</td><td className="py-2 text-right tabular">{d.ofertas}</td><td className="py-2 text-right tabular">{d.aceitas}</td><td className="py-2 text-right tabular">{d.conversao_pct == null ? '—' : formatPct(d.conversao_pct, 1)}</td><td className="py-2 text-right tabular">{formatPct(d.margem_media_pct, 1)}</td><td className="px-3 py-2 text-right tabular">{formatBRL(d.desconto_total)}</td></tr>)}</tbody>
                </table>
              </div>
            )}
            <p className="text-xs text-muted-foreground">Descontos consumiram {formatPct(relatorio.data?.consumo_da_margem_pct ?? 0, 1)} da margem · receita incremental estimada {formatBRL(relatorio.data?.receita_incremental_estimada ?? 0)}.</p>
            {(relatorio.data?.sugestoes ?? []).map((s) => <p key={s} className="rounded-md border border-brand-red/40 bg-brand-red/5 p-2 text-sm">{s}</p>)}
          </div>
        )}
      </section>

      <section>
        <h2 className="mb-2 text-sm font-black">Itens não competitivos e fora de venda</h2>
        {ruins.isLoading ? <Skeleton className="h-16 w-full" /> : (ruins.data ?? []).length === 0 ? <p className="rounded-md border border-dashed p-3 text-sm text-muted-foreground">Nenhum item marcado.</p> : (
          <ul className="divide-y rounded-md border">{ruins.data!.map((i) => <li key={i.sku} className="flex flex-wrap items-center gap-2 p-2 text-sm"><SkuBadge sku={i.sku} /><span className="min-w-0 flex-1 truncate">{i.descricao}</span><span className="text-xs text-muted-foreground">{i.grupo_produto}</span><span className={cn('rounded px-1.5 py-0.5 text-[11px] font-bold', i.status_venda === 'nao_vender' ? 'bg-brand-red/10 text-brand-red' : 'bg-secondary')}>{i.status_venda === 'nao_vender' ? 'Não vender' : 'Não competitivo'}</span></li>)}</ul>
        )}
      </section>

      <section>
        <h2 className="mb-2 text-sm font-black">Ajustes automáticos do fator</h2>
        {ajustes.isLoading ? <Skeleton className="h-20 w-full" /> : (ajustes.data ?? []).length === 0 ? <p className="rounded-md border border-dashed p-3 text-sm text-muted-foreground">Nenhum ajuste ainda. São necessários ao menos 8 orçamentos encerrados no grupo em 30 dias.</p> : (
          <ul className="divide-y rounded-md border">{ajustes.data!.map((a) => <li className="p-3 text-sm" key={a.id}><strong>{a.grupo_produto}</strong>: {a.fator_antes.toFixed(2)} → {a.fator_depois.toFixed(2)}<p className="text-xs text-muted-foreground">{a.motivo} · {new Date(a.criado_em).toLocaleDateString('pt-BR')}</p></li>)}</ul>
        )}
      </section>
    </div>
  )
}

function Card({ titulo, valor, nota }: { titulo: string; valor: string; nota: string }) {
  return (
    <div className="rounded-md border p-3">
      <dt className="text-[11px] uppercase tracking-wide text-muted-foreground">{titulo}</dt>
      <dd className="mt-1 text-2xl font-black tabular">{valor}</dd>
      <p className="text-xs text-muted-foreground">{nota}</p>
    </div>
  )
}

function ConsultaLinha({ c }: { c: Consulta }) {
  const [aberta, setAberta] = useState(false)
  const fontes = useQuery({
    queryKey: ['fontes-consulta', c.id],
    enabled: aberta,
    queryFn: async () => {
      const { data, error } = await supabase.from('precos_mercado').select('id, fonte, url, preco, outlier, motivo_descarte, coletado_em').eq('consulta_id', c.id).order('preco')
      if (error) throw error
      return data as Fonte[]
    },
  })
  return (
    <li className="p-2 text-sm">
      <button type="button" className="flex w-full items-center gap-2 text-left" onClick={() => setAberta((a) => !a)} aria-expanded={aberta}>
        <ChevronDown className={cn('h-4 w-4 shrink-0 transition-transform', aberta && 'rotate-180')} aria-hidden />
        {c.sku && <SkuBadge sku={c.sku} />}
        <span className="rounded bg-secondary px-1.5 py-0.5 text-[11px] font-bold">{STATUS[c.status] ?? c.status}</span>
        <span className="tabular text-muted-foreground">{c.mediana == null ? 'sem mediana' : `mediana ${formatBRL(c.mediana)}`}{c.confianca ? ` · confiança ${c.confianca}` : ''} · {c.fontes_validas} fonte(s)</span>
        <span className="ml-auto text-xs text-muted-foreground">{c.duracao_ms != null ? `${(c.duracao_ms / 1000).toFixed(1)} s · ` : ''}{fmtData(c.criado_em)}</span>
      </button>
      {aberta && (
        <div className="mt-2 pl-6 text-xs">
          {fontes.isLoading ? <Skeleton className="h-8 w-full" /> : (fontes.data ?? []).length === 0 ? <p className="text-muted-foreground">Sem fontes gravadas ({c.requisicoes} requisições, {c.tokens_usados} tokens).</p> : (
            <ul className="space-y-1">{fontes.data!.map((f) => <li key={f.id} className={cn(f.outlier && 'text-muted-foreground line-through')}>{f.fonte}: {formatBRL(f.preco)}{f.outlier ? ` (descartada: ${f.motivo_descarte ?? 'fora do padrão'})` : ''}{f.url && <> · <a className="underline" href={f.url} target="_blank" rel="noreferrer">página</a></>}</li>)}</ul>
          )}
        </div>
      )}
    </li>
  )
}
