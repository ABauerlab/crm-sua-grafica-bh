import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { ChevronDown, ChevronRight, Megaphone, RefreshCw, Trash2 } from 'lucide-react'
import { Fragment, useMemo, useState } from 'react'
import { Bar, BarChart, CartesianGrid, Legend, ResponsiveContainer, Tooltip, XAxis, YAxis } from 'recharts'
import { Link } from 'react-router-dom'
import { Button } from '@/components/ui/button'
import { EmptyState, ErrorState } from '@/components/ui/empty-state'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { Skeleton } from '@/components/ui/skeleton'
import { useToast } from '@/components/ui/toast'
import { useSetting } from '@/hooks/settings'
import { invokeFunction } from '@/lib/api'
import { BRAND, SERIES } from '@/lib/brand'
import { groupCampaigns, goalState, metrics, type GoalState, type ManualSpend, type Metrics } from '@/lib/campaigns'
import { formatBRL, formatBRLCompact, formatNumber, formatPct, parseMoney } from '@/lib/money'
import { supabase } from '@/lib/supabase'
import type { AdPerformance } from '@/lib/types'
import { cn } from '@/lib/utils'

type Range = '7' | '30' | '90' | 'month'

function bounds(range: Range): { from: string; to: string } {
  const to = new Date()
  const from = new Date()
  if (range === 'month') from.setDate(1)
  else from.setDate(from.getDate() - (Number(range) - 1))
  const iso = (d: Date) => new Date(d.getTime() - d.getTimezoneOffset() * 60_000).toISOString().slice(0, 10)
  return { from: iso(from), to: iso(to) }
}

const money = (v: number | null) => (v === null ? '—' : formatBRL(v))

function Goal({ state, children }: { state: GoalState; children: React.ReactNode }) {
  return (
    <span className={cn('tabular', state === 'good' && 'font-bold text-brand-green', state === 'bad' && 'font-bold text-brand-red')}>
      {state === 'good' && <span aria-label="dentro da meta">▲ </span>}
      {state === 'bad' && <span aria-label="fora da meta">▼ </span>}
      {children}
    </span>
  )
}

function Tile({ label, value, sub, state }: { label: string; value: string; sub?: string; state?: GoalState }) {
  return (
    <div className={cn('min-w-0 rounded-md border bg-card p-3 sm:p-4', state === 'good' && 'border-l-4 border-l-brand-green', state === 'bad' && 'border-l-4 border-l-brand-red')}>
      <p className="truncate text-[11px] font-medium uppercase tracking-[0.12em] text-muted-foreground">{label}</p>
      <p className="mt-1 truncate text-2xl font-black leading-none tabular">{value}</p>
      {sub && <p className="mt-1.5 text-xs text-muted-foreground">{sub}</p>}
    </div>
  )
}

export default function Campaigns() {
  const qc = useQueryClient()
  const toast = useToast()
  const { data: goals } = useSetting('campaign_goals')
  const [range, setRange] = useState<Range>('30')
  const [open, setOpen] = useState<Set<string>>(new Set())
  const { from, to } = bounds(range)
  const g = goals ?? { max_cost_per_conversation: 6, max_cost_per_sale: 60, min_roas: 4 }

  const perf = useQuery({
    queryKey: ['ad-performance', from, to],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('ad_performance', { p_from: from, p_to: to })
      if (error) throw new Error(error.message)
      return (data as Record<string, unknown>[]).map((r) => ({
        ...r,
        spend: Number(r.spend),
        impressions: Number(r.impressions),
        clicks: Number(r.clicks),
        meta_conversations: Number(r.meta_conversations),
        conversations: Number(r.conversations),
        quotes: Number(r.quotes),
        paid_orders: Number(r.paid_orders),
        revenue: Number(r.revenue),
        net_profit: Number(r.net_profit),
      })) as AdPerformance[]
    },
  })

  const manual = useQuery({
    queryKey: ['ad-manual', from, to],
    queryFn: async () => {
      const { data, error } = await supabase.from('ad_manual_spend').select('*').gte('day', from).lte('day', to).order('day', { ascending: false })
      if (error) throw new Error(error.message)
      return (data as ManualSpend[]).map((r) => ({ ...r, amount: Number(r.amount) }))
    },
  })

  const lastSync = useQuery({
    queryKey: ['ad-last-sync'],
    queryFn: async () => {
      const { data } = await supabase.from('ad_entities').select('updated_at').order('updated_at', { ascending: false }).limit(1)
      return (data?.[0]?.updated_at as string | undefined) ?? null
    },
  })

  const sync = useMutation({
    mutationFn: () => invokeFunction<{ ads: number; days_with_data: number }>('meta-ads-sync', { days: Number(range) || 30 }),
    onSuccess: (r) => {
      toast('ok', `Sincronizado: ${r.ads} anúncio(s), ${r.days_with_data} dia(s) com gasto.`)
      qc.invalidateQueries({ queryKey: ['ad-performance'] })
      qc.invalidateQueries({ queryKey: ['ad-last-sync'] })
    },
    onError: (e: Error) => toast('error', e.message),
  })

  const [form, setForm] = useState({ day: new Date().toISOString().slice(0, 10), campaign: '', amount: '', note: '' })
  const addSpend = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.from('ad_manual_spend').insert({ day: form.day, campaign_name: form.campaign.trim(), amount: parseMoney(form.amount), note: form.note.trim() || null })
      if (error) throw new Error(error.message)
    },
    onSuccess: () => {
      setForm({ ...form, campaign: '', amount: '', note: '' })
      qc.invalidateQueries({ queryKey: ['ad-manual'] })
      toast('ok', 'Investimento registrado.')
    },
    onError: (e: Error) => toast('error', e.message),
  })
  const delSpend = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.from('ad_manual_spend').delete().eq('id', id)
      if (error) throw new Error(error.message)
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['ad-manual'] }),
  })

  const groups = useMemo(() => groupCampaigns(perf.data ?? [], manual.data ?? []), [perf.data, manual.data])
  const total: Metrics = useMemo(
    () =>
      metrics(
        groups.reduce(
          (a, c) => ({
            spend: a.spend + c.m.spend,
            conversations: a.conversations + c.m.conversations,
            quotes: a.quotes + c.m.quotes,
            paid_orders: a.paid_orders + c.m.paid,
            revenue: a.revenue + c.m.revenue,
            net_profit: a.net_profit + c.m.profit,
            impressions: a.impressions + c.m.impressions,
            clicks: a.clicks + c.m.clicks,
          }),
          { spend: 0, conversations: 0, quotes: 0, paid_orders: 0, revenue: 0, net_profit: 0, impressions: 0, clicks: 0 },
        ),
      ),
    [groups],
  )

  const chart = groups.slice(0, 8).map((c) => ({ name: c.name.length > 24 ? `${c.name.slice(0, 23)}…` : c.name, Investimento: Math.round(c.m.spend), Faturamento: Math.round(c.m.revenue) }))
  const funnel = [
    { etapa: 'Conversas iniciadas', Total: total.conversations },
    { etapa: 'Orçamentos enviados', Total: total.quotes },
    { etapa: 'Pedidos pagos', Total: total.paid },
  ]
  const campaignNames = [...new Set(groups.map((c) => c.name))]
  const loading = perf.isLoading || manual.isLoading
  const empty = !loading && groups.length === 0

  return (
    <div className="h-full overflow-y-auto">
      <header className="flex flex-wrap items-center justify-between gap-3 border-b px-4 py-3">
        <div>
          <h1 className="text-xl font-black">Campanhas</h1>
          <p className="text-xs text-muted-foreground">
            {lastSync.data ? `Última sincronização com a Meta: ${new Date(lastSync.data).toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' })}` : 'Ainda não sincronizado com a Meta.'}
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <Select aria-label="Período" className="w-44" value={range} onChange={(e) => setRange(e.target.value as Range)}>
            <option value="7">Últimos 7 dias</option>
            <option value="30">Últimos 30 dias</option>
            <option value="90">Últimos 90 dias</option>
            <option value="month">Este mês</option>
          </Select>
          <Button variant="outline" onClick={() => sync.mutate()} disabled={sync.isPending}>
            <RefreshCw className={cn('h-4 w-4', sync.isPending && 'animate-spin')} /> {sync.isPending ? 'Sincronizando…' : 'Sincronizar com a Meta'}
          </Button>
        </div>
      </header>

      {perf.error ? (
        <ErrorState message={(perf.error as Error).message} onRetry={() => perf.refetch()} />
      ) : loading ? (
        <div className="grid grid-cols-2 gap-3 p-4 lg:grid-cols-4">{[0, 1, 2, 3].map((i) => <Skeleton key={i} className="h-24" />)}</div>
      ) : (
        <div className="space-y-4 p-4">
          {empty && (
            <EmptyState icon={Megaphone} title="Nenhuma campanha com dados neste período">
              Assim que sua primeira campanha (clique para o WhatsApp) gerar conversas, o custo por conversa, o custo por venda e o ROAS aparecem aqui. Você também pode registrar um investimento manual abaixo.
            </EmptyState>
          )}

          <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
            <Tile label="Investimento" value={formatBRL(total.spend)} sub={total.impressions ? `${formatNumber(total.impressions)} impressões · ${formatNumber(total.clicks)} cliques` : undefined} />
            <Tile label="Conversas iniciadas" value={formatNumber(total.conversations)} sub={`Meta contou ${formatNumber(groups.reduce((n, c) => n + c.ads.reduce((x, a) => x + a.meta_conversations, 0), 0))}`} />
            <Tile label="Custo por conversa" value={money(total.cpc)} state={goalState('cost', total.cpc, g.max_cost_per_conversation)} sub={`Meta: até ${formatBRL(g.max_cost_per_conversation)}`} />
            <Tile label="Orçamentos" value={formatNumber(total.quotes)} sub={total.quoteRate !== null ? `${formatPct(total.quoteRate)} das conversas` : undefined} />
            <Tile label="Vendas pagas" value={formatNumber(total.paid)} sub={total.paidRate !== null ? `${formatPct(total.paidRate, 1)} das conversas` : undefined} />
            <Tile label="Custo por venda" value={money(total.cps)} state={goalState('cost', total.cps, g.max_cost_per_sale)} sub={`Meta: até ${formatBRL(g.max_cost_per_sale)}`} />
            <Tile label="ROAS" value={total.roas === null ? '—' : `${total.roas.toFixed(1).replace('.', ',')}x`} state={goalState('roas', total.roas, g.min_roas)} sub={`Meta: ${g.min_roas.toString().replace('.', ',')}x ou mais · faturamento ${formatBRL(total.revenue)}`} />
            <Tile label="Lucro após anúncio" value={formatBRL(total.profitAfterAds)} state={total.spend > 0 ? (total.profitAfterAds >= 0 ? 'good' : 'bad') : 'none'} sub={`Lucro líquido ${formatBRL(total.profit)} − investimento`} />
          </div>

          {!empty && (
            <div className="grid gap-4 xl:grid-cols-2">
              <section className="rounded-md border bg-card p-4">
                <h2 className="text-base font-black">Investimento x faturamento por campanha</h2>
                <div role="img" aria-label="Gráfico de barras comparando investimento e faturamento por campanha" className="mt-3 h-64">
                  <ResponsiveContainer width="100%" height="100%">
                    <BarChart data={chart} margin={{ top: 8, right: 12, left: 0, bottom: 0 }}>
                      <CartesianGrid stroke="#ececec" vertical={false} />
                      <XAxis dataKey="name" tick={{ fontSize: 12, fill: '#525252' }} tickLine={false} axisLine={{ stroke: '#d4d4d4' }} />
                      <YAxis tick={{ fontSize: 12, fill: '#525252' }} tickLine={false} axisLine={false} tickFormatter={formatBRLCompact} width={76} />
                      <Tooltip contentStyle={{ border: '1px solid #e0e0e0', borderRadius: 6, boxShadow: 'none', fontSize: 12, color: BRAND.ink }} cursor={{ fill: '#f5f5f5' }} formatter={(v) => formatBRL(Number(v))} />
                      <Legend wrapperStyle={{ fontSize: 12 }} />
                      <Bar dataKey="Investimento" fill={SERIES[1]} radius={[4, 4, 0, 0]} />
                      <Bar dataKey="Faturamento" fill={SERIES[0]} radius={[4, 4, 0, 0]} />
                    </BarChart>
                  </ResponsiveContainer>
                </div>
              </section>
              <section className="rounded-md border bg-card p-4">
                <h2 className="text-base font-black">Funil: conversa, orçamento e venda</h2>
                <div role="img" aria-label="Gráfico de barras com conversas, orçamentos e vendas" className="mt-3 h-64">
                  <ResponsiveContainer width="100%" height="100%">
                    <BarChart data={funnel} layout="vertical" margin={{ top: 0, right: 32, left: 0, bottom: 0 }}>
                      <CartesianGrid stroke="#ececec" horizontal={false} />
                      <XAxis type="number" tick={{ fontSize: 12, fill: '#525252' }} tickLine={false} axisLine={false} allowDecimals={false} />
                      <YAxis type="category" dataKey="etapa" tick={{ fontSize: 12, fill: '#525252' }} tickLine={false} axisLine={false} width={130} />
                      <Tooltip contentStyle={{ border: '1px solid #e0e0e0', borderRadius: 6, boxShadow: 'none', fontSize: 12 }} cursor={{ fill: '#f5f5f5' }} />
                      <Bar dataKey="Total" fill={SERIES[0]} radius={[0, 4, 4, 0]} barSize={18} label={{ position: 'right', fontSize: 12, fill: BRAND.ink }} />
                    </BarChart>
                  </ResponsiveContainer>
                </div>
              </section>
            </div>
          )}

          {groups.length > 0 && (
            <section className="overflow-x-auto rounded-md border bg-card">
              <table className="w-full min-w-[980px] text-sm">
                <thead>
                  <tr className="border-b text-left text-[11px] uppercase tracking-wide text-muted-foreground">
                    <th className="px-3 py-2 font-medium">Campanha / anúncio</th>
                    <th className="py-2 text-right font-medium">Investimento</th>
                    <th className="py-2 text-right font-medium">Conversas</th>
                    <th className="py-2 text-right font-medium">Custo/conversa</th>
                    <th className="py-2 text-right font-medium">Orçamentos</th>
                    <th className="py-2 text-right font-medium">Vendas</th>
                    <th className="py-2 text-right font-medium">Custo/venda</th>
                    <th className="py-2 text-right font-medium">Faturamento</th>
                    <th className="py-2 text-right font-medium">Lucro após anúncio</th>
                    <th className="px-3 py-2 text-right font-medium">ROAS</th>
                  </tr>
                </thead>
                <tbody>
                  {groups.map((c) => {
                    const isOpen = open.has(c.key)
                    const row = (name: string, m: Metrics, nested: boolean, id: string, canOpen: boolean) => (
                      <tr key={id} className={cn('border-b', nested ? 'bg-secondary/40' : 'font-medium')}>
                        <td className={cn('py-2 pr-2', nested ? 'pl-9' : 'px-3')}>
                          {canOpen ? (
                            <button
                              className="flex min-h-9 items-center gap-1 text-left font-bold"
                              aria-expanded={isOpen}
                              onClick={() => setOpen((s) => { const n = new Set(s); if (n.has(c.key)) n.delete(c.key); else n.add(c.key); return n })}
                            >
                              {isOpen ? <ChevronDown className="h-4 w-4" aria-hidden /> : <ChevronRight className="h-4 w-4" aria-hidden />}
                              {name}
                            </button>
                          ) : (
                            name
                          )}
                        </td>
                        <td className="py-2 text-right tabular">{formatBRL(m.spend)}</td>
                        <td className="py-2 text-right tabular">{m.conversations}</td>
                        <td className="py-2 text-right"><Goal state={goalState('cost', m.cpc, g.max_cost_per_conversation)}>{money(m.cpc)}</Goal></td>
                        <td className="py-2 text-right tabular">{m.quotes}</td>
                        <td className="py-2 text-right tabular">{m.paid}</td>
                        <td className="py-2 text-right"><Goal state={goalState('cost', m.cps, g.max_cost_per_sale)}>{money(m.cps)}</Goal></td>
                        <td className="py-2 text-right tabular">{formatBRL(m.revenue)}</td>
                        <td className={cn('py-2 text-right tabular', m.profitAfterAds < 0 && 'font-bold text-brand-red')}>{formatBRL(m.profitAfterAds)}</td>
                        <td className="px-3 py-2 text-right"><Goal state={goalState('roas', m.roas, g.min_roas)}>{m.roas === null ? '—' : `${m.roas.toFixed(1).replace('.', ',')}x`}</Goal></td>
                      </tr>
                    )
                    return (
                      <Fragment key={c.key}>
                        {row(c.name + (c.manual ? ` (inclui ${formatBRL(c.manual)} manual)` : ''), c.m, false, c.key, c.ads.length > 0)}
                        {isOpen && c.ads.map((a) => row(a.ad_name ?? a.ad_id, metrics(a), true, `${c.key}-${a.ad_id}`, false))}
                      </Fragment>
                    )
                  })}
                </tbody>
              </table>
            </section>
          )}

          <section className="rounded-md border bg-card p-4">
            <h2 className="text-base font-black">Investimento manual</h2>
            <p className="text-xs text-muted-foreground">Para gastos fora da Meta ou antes de sincronizar. Se o nome for igual ao de uma campanha, soma nela.</p>
            <form
              className="mt-3 flex flex-wrap items-end gap-2"
              onSubmit={(e) => {
                e.preventDefault()
                addSpend.mutate()
              }}
            >
              <div className="space-y-1"><Label htmlFor="m-day">Data</Label><Input id="m-day" type="date" required value={form.day} onChange={(e) => setForm({ ...form, day: e.target.value })} /></div>
              <div className="space-y-1">
                <Label htmlFor="m-camp">Campanha</Label>
                <Input id="m-camp" required list="camp-names" className="w-56" value={form.campaign} onChange={(e) => setForm({ ...form, campaign: e.target.value })} />
                <datalist id="camp-names">{campaignNames.map((n) => <option key={n} value={n} />)}</datalist>
              </div>
              <div className="space-y-1"><Label htmlFor="m-amt">Valor (R$)</Label><Input id="m-amt" required inputMode="decimal" className="w-32" value={form.amount} onChange={(e) => setForm({ ...form, amount: e.target.value })} /></div>
              <div className="space-y-1"><Label htmlFor="m-note">Observação</Label><Input id="m-note" className="w-48" value={form.note} onChange={(e) => setForm({ ...form, note: e.target.value })} /></div>
              <Button type="submit" disabled={addSpend.isPending}>Registrar</Button>
            </form>
            {(manual.data ?? []).length > 0 && (
              <ul className="mt-3 divide-y rounded-md border text-sm">
                {manual.data!.map((s) => (
                  <li key={s.id} className="flex items-center justify-between gap-2 px-3 py-1.5">
                    <span className="min-w-0 truncate"><span className="tabular text-muted-foreground">{new Date(s.day + 'T12:00').toLocaleDateString('pt-BR')}</span> · {s.campaign_name}{s.note ? ` · ${s.note}` : ''}</span>
                    <span className="flex items-center gap-1"><strong className="tabular">{formatBRL(s.amount)}</strong><Button variant="ghost" size="icon" aria-label="Remover investimento" onClick={() => delSpend.mutate(s.id)}><Trash2 className="h-4 w-4" /></Button></span>
                  </li>
                ))}
              </ul>
            )}
          </section>

          <p className="text-xs text-muted-foreground">
            Conversas e vendas por anúncio vêm do id do anúncio gravado quando o cliente clica e abre o WhatsApp (<Link to="/contatos" className="underline">Contatos</Link> mostra a origem de cada um). Metas em Configurações.
          </p>
        </div>
      )}
    </div>
  )
}
