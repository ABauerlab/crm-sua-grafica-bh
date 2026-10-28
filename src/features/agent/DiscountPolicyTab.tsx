import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { AlertTriangle, CheckCircle2 } from 'lucide-react'
import { useEffect, useMemo, useState } from 'react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Skeleton } from '@/components/ui/skeleton'
import { useToast } from '@/components/ui/toast'
import { formatBRL } from '@/lib/money'
import { supabase } from '@/lib/supabase'
import { cn } from '@/lib/utils'

type Rule = {
  degrau: number
  nome: string
  tipo: 'vantagem' | 'desconto'
  percentual: number
  desconto_max_reais: number
  fracao_gordura_max: number
  valor_minimo_reais: number
  validade_horas: number
  intervalo_dias_contato: number
  ativo: boolean
}
type DegrauSim = { degrau: number; tipo: string; pior_lucro_liquido?: number; maior_desconto_reais?: number; seguro: boolean; nota?: string }
type Simulacao = { ok: boolean; seguro: boolean; degraus: DegrauSim[] }

const num = (v: string) => (v.trim() === '' || Number.isNaN(Number(v.replace(',', '.'))) ? 0 : Number(v.replace(',', '.')))

/**
 * Política de condição especial. A função do banco decide cada oferta; aqui só se mudam os limites.
 * Toda alteração mostra a simulação do pior caso de lucro líquido (amostra do catálogo, três tipos de entrega,
 * quatro níveis de preço) e o banco recusa a política que permita prejuízo.
 */
export default function DiscountPolicyTab() {
  const toast = useToast()
  const qc = useQueryClient()
  const q = useQuery({
    queryKey: ['politica-desconto'],
    queryFn: async () => {
      const { data, error } = await supabase.from('politica_desconto').select('*').order('degrau')
      if (error) throw error
      return data as Rule[]
    },
  })
  const [rules, setRules] = useState<Rule[]>([])
  useEffect(() => { if (q.data) setRules(q.data) }, [q.data])

  // espera o dono parar de digitar antes de simular
  const [paraSimular, setParaSimular] = useState<Rule[]>([])
  useEffect(() => {
    const t = setTimeout(() => setParaSimular(rules), 500)
    return () => clearTimeout(t)
  }, [rules])
  const payload = useMemo(
    () => paraSimular.map((r) => ({ degrau: r.degrau, percentual: r.percentual, fracao_gordura_max: r.fracao_gordura_max, desconto_max_reais: r.desconto_max_reais, valor_minimo_reais: r.valor_minimo_reais, validade_horas: r.validade_horas, intervalo_dias_contato: r.intervalo_dias_contato, ativo: r.ativo })),
    [paraSimular],
  )
  const sim = useQuery({
    queryKey: ['simulacao-politica', JSON.stringify(payload)],
    enabled: payload.length > 0,
    staleTime: 60_000,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('simular_politica_desconto', { p_regras: payload, p_amostra: 200 })
      if (error) throw new Error(error.message)
      return data as Simulacao
    },
  })

  const save = useMutation({
    mutationFn: async () => {
      const { data, error } = await supabase.rpc('salvar_politica_desconto', { p_regras: payload })
      if (error) throw new Error(error.message)
      return data as Simulacao
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['politica-desconto'] })
      toast('ok', 'Política salva. A trava de lucro continua ativa.')
    },
    onError: (e: Error) => toast('error', e.message),
  })

  const grupos = useGruposSemDesconto()

  if (q.isLoading) return <Skeleton className="h-48 w-full" />
  const patch = (id: number, next: Partial<Rule>) => setRules((old) => old.map((x) => (x.degrau === id ? { ...x, ...next } : x)))
  const simulando = sim.isFetching || paraSimular !== rules
  const seguro = sim.data?.seguro === true && !simulando
  const dirty = JSON.stringify(rules) !== JSON.stringify(q.data)

  return (
    <div className="max-w-3xl space-y-4">
      <p className="text-sm text-muted-foreground">
        A condição especial é calculada pelo banco: o desconto sai só da margem acima do piso, nunca passa do teto em reais nem da fração da gordura, e vale por tempo curto.
        O agente só comunica o resultado. Antes de salvar, o sistema simula o pior caso e recusa qualquer configuração que permita lucro líquido negativo.
      </p>

      {rules.map((r) => {
        const d = sim.data?.degraus.find((x) => x.degrau === r.degrau)
        return (
          <section key={r.degrau} className="rounded-md border p-3">
            <div className="mb-3 flex items-center justify-between gap-3">
              <div>
                <strong>Degrau {r.degrau}</strong>
                <p className="text-xs text-muted-foreground">{r.nome}</p>
              </div>
              <label className="text-sm"><input type="checkbox" checked={r.ativo} onChange={(e) => patch(r.degrau, { ativo: e.target.checked })} /> Ativo</label>
            </div>
            {r.tipo === 'desconto' ? (
              <div className="grid gap-3 sm:grid-cols-4">
                <label className="text-sm">Desconto máximo (%)<Input type="number" min="0" max="10" step="0.5" value={r.percentual} onChange={(e) => patch(r.degrau, { percentual: num(e.target.value) })} /></label>
                <label className="text-sm">Teto (R$)<Input type="number" min="0" value={r.desconto_max_reais} onChange={(e) => patch(r.degrau, { desconto_max_reais: num(e.target.value) })} /></label>
                <label className="text-sm">Fração da gordura (0 a 1)<Input type="number" min="0" max="1" step="0.05" value={r.fracao_gordura_max} onChange={(e) => patch(r.degrau, { fracao_gordura_max: num(e.target.value) })} /></label>
                <label className="text-sm">Mínimo em dinheiro (R$)<Input type="number" min="0" value={r.valor_minimo_reais} onChange={(e) => patch(r.degrau, { valor_minimo_reais: num(e.target.value) })} /></label>
              </div>
            ) : (
              <p className="text-sm text-muted-foreground">Oferece arte grátis ou frete grátis (sem pedido mínimo) quando o preço sem frete ou arte continuar acima do piso. Não corta o preço.</p>
            )}
            <div className="mt-3 grid gap-3 sm:grid-cols-2">
              <label className="text-sm">Validade (horas)<Input type="number" min="1" value={r.validade_horas} onChange={(e) => patch(r.degrau, { validade_horas: Math.max(1, Math.round(num(e.target.value))) })} /></label>
              <label className="text-sm">Intervalo por contato (dias)<Input type="number" min="0" value={r.intervalo_dias_contato} onChange={(e) => patch(r.degrau, { intervalo_dias_contato: Math.max(0, Math.round(num(e.target.value))) })} /></label>
            </div>
            <p className={cn('mt-3 flex items-start gap-2 rounded-md p-2 text-xs', d && !d.seguro ? 'bg-brand-red/10 text-brand-red' : 'bg-secondary text-muted-foreground')} aria-live="polite">
              {d && !d.seguro ? <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden /> : <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0" aria-hidden />}
              {simulando && !d ? 'Simulando o pior caso...' : d?.tipo === 'desconto'
                ? <span>Pior caso (amostra do catálogo): lucro líquido de <strong>{formatBRL(d.pior_lucro_liquido ?? 0)}</strong> depois do desconto; maior desconto possível {formatBRL(d.maior_desconto_reais ?? 0)}. {d.seguro ? 'Seguro.' : 'RECUSADO: haveria prejuízo.'}</span>
                : <span>{d?.nota ?? 'Vantagem sem desconto em dinheiro.'}</span>}
            </p>
          </section>
        )
      })}

      <div className="flex items-center gap-3">
        <Button disabled={!dirty || !seguro || save.isPending} onClick={() => save.mutate()}>Salvar política</Button>
        {!seguro && dirty && <span className="text-xs text-muted-foreground">{simulando ? 'Simulando...' : 'Corrija os valores: o pior caso precisa ter lucro líquido maior ou igual a zero.'}</span>}
      </div>

      <section className="rounded-md border p-3">
        <strong>Grupos que não aceitam desconto em dinheiro</strong>
        <p className="mb-2 text-xs text-muted-foreground">Marque os grupos de margem baixa. Frete e arte nunca recebem desconto em dinheiro. Vale também por item (coluna do catálogo).</p>
        {grupos.isLoading ? <Skeleton className="h-10 w-full" /> : (
          <div className="grid gap-1 sm:grid-cols-2">
            {grupos.todos.map((g) => (
              <label key={g} className="flex items-center gap-2 text-sm">
                <input type="checkbox" checked={grupos.marcados.includes(g)} onChange={(e) => grupos.alternar(g, e.target.checked)} /> {g}
              </label>
            ))}
          </div>
        )}
      </section>
    </div>
  )
}

function useGruposSemDesconto() {
  const toast = useToast()
  const qc = useQueryClient()
  const lista = useQuery({
    queryKey: ['grupos-sem-desconto'],
    queryFn: async () => {
      const [{ data: p, error: e1 }, { data: g, error: e2 }] = await Promise.all([
        supabase.from('parametros_comerciais').select('categorias_sem_desconto').eq('id', 1).maybeSingle(),
        supabase.from('saude_precos').select('grupo_produto').order('grupo_produto').limit(500),
      ])
      if (e1) throw e1
      if (e2) throw e2
      return { marcados: (p?.categorias_sem_desconto ?? []) as string[], todos: ((g ?? []) as { grupo_produto: string }[]).map((x) => x.grupo_produto).filter((x) => x && x !== 'Sem grupo') }
    },
  })
  const salvar = useMutation({
    mutationFn: async (novos: string[]) => {
      const { error } = await supabase.rpc('definir_grupos_sem_desconto', { p_grupos: novos })
      if (error) throw new Error(error.message)
    },
    onSuccess: () => { qc.invalidateQueries({ queryKey: ['grupos-sem-desconto'] }); toast('ok', 'Grupos sem desconto salvos.') },
    onError: (e: Error) => toast('error', e.message),
  })
  const marcados = lista.data?.marcados ?? []
  return {
    isLoading: lista.isLoading,
    todos: Array.from(new Set([...(lista.data?.todos ?? []), ...marcados])),
    marcados,
    alternar: (g: string, on: boolean) => salvar.mutate(on ? [...marcados, g] : marcados.filter((x) => x !== g)),
  }
}
