import { BarChart3, FlaskConical } from 'lucide-react'
import { lazy, Suspense, useMemo, useState, type ReactNode } from 'react'
import { Bar, BarChart, CartesianGrid, Legend, Line, LineChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from 'recharts'
import { Link } from 'react-router-dom'
import { Button } from '@/components/ui/button'
import { EmptyState } from '@/components/ui/empty-state'
import { Select } from '@/components/ui/select'
import { Skeleton } from '@/components/ui/skeleton'
import { Switch } from '@/components/ui/switch'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { buildDemo } from '@/features/dashboard/demo'
import { useAdTotals } from '@/hooks/campaigns'
import { useSetting } from '@/hooks/settings'
import { goalState, metrics as adMetrics } from '@/lib/campaigns'
import { useOrders, useSettings } from '@/hooks/orders'
import { useContacts } from '@/hooks/queries'
import { BRAND, SERIES } from '@/lib/brand'
import { formatBRL, formatBRLCompact, formatNumber, formatPct } from '@/lib/money'
import { DEFAULT_KANBAN, isStalled, ORDER_STAGES, type OrderCard } from '@/lib/orders'
import type { Contact } from '@/lib/types'
import { cn } from '@/lib/utils'

const DAY = 86_400_000
type Period = 7 | 30 | 90

const startOfDay = (t: number) => {
  const d = new Date(t)
  d.setHours(0, 0, 0, 0)
  return d.getTime()
}
const isPaid = (o: OrderCard) => o.payment_status === 'aprovado' || o.payment_manual
const paidTime = (o: OrderCard) => new Date(o.paid_at ?? o.created_at).getTime()

function summarize(orders: OrderCard[], from: number, to: number) {
  const created = orders.filter((o) => {
    const t = new Date(o.created_at).getTime()
    return t >= from && t < to
  })
  const paid = orders.filter((o) => isPaid(o) && paidTime(o) >= from && paidTime(o) < to)
  const revenue = paid.reduce((n, o) => n + o.fin.total, 0)
  const profit = paid.reduce((n, o) => n + o.fin.net_profit, 0)
  return {
    revenue,
    profit,
    paid: paid.length,
    created: created.length,
    ticket: paid.length ? revenue / paid.length : 0,
    conversion: created.length ? (created.filter(isPaid).length / created.length) * 100 : 0,
  }
}

function Delta({ now, before, invert = false }: { now: number; before: number; invert?: boolean }) {
  if (!before) return <span className="text-xs text-muted-foreground">sem período anterior</span>
  const pct = ((now - before) / before) * 100
  if (Math.round(pct) === 0) return <span className="text-xs text-muted-foreground">sem variação vs período anterior</span>
  const good = invert ? pct <= 0 : pct >= 0
  return (
    <span className={cn('text-xs font-semibold tabular', good ? 'text-brand-green' : 'text-brand-red')}>
      {pct >= 0 ? '▲' : '▼'} {formatPct(Math.abs(pct), 0)} <span className="font-normal text-muted-foreground">vs período anterior</span>
    </span>
  )
}

function Tile({ label, value, children }: { label: string; value: string; children?: ReactNode }) {
  return (
    <div className="min-w-0 rounded-md border bg-card p-3 sm:p-4">
      <p className="truncate text-[11px] font-medium uppercase tracking-[0.12em] text-muted-foreground">{label}</p>
      <p className="mt-1 truncate text-2xl font-black leading-none tabular sm:text-3xl">{value}</p>
      <div className="mt-2 min-h-4">{children}</div>
    </div>
  )
}

function ChartCard({ title, subtitle, table, children }: { title: string; subtitle?: string; table: { head: string[]; rows: (string | number)[][] }; children: ReactNode }) {
  const [asTable, setAsTable] = useState(false)
  return (
    <section className="rounded-md border bg-card p-4">
      <div className="mb-3 flex items-start justify-between gap-3">
        <div>
          <h2 className="text-base font-black">{title}</h2>
          {subtitle && <p className="text-xs text-muted-foreground">{subtitle}</p>}
        </div>
        <button onClick={() => setAsTable((v) => !v)} className="min-h-11 text-xs font-semibold text-link underline md:min-h-0" aria-pressed={asTable}>
          {asTable ? 'Ver gráfico' : 'Ver como tabela'}
        </button>
      </div>
      {asTable ? (
        <div className="max-h-72 overflow-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b text-left text-xs uppercase tracking-wide text-muted-foreground">
                {table.head.map((h) => <th key={h} className="py-1.5 pr-3 font-medium">{h}</th>)}
              </tr>
            </thead>
            <tbody>
              {table.rows.map((r, i) => (
                <tr key={i} className="border-b last:border-0">
                  {r.map((c, j) => <td key={j} className="py-1.5 pr-3 tabular">{c}</td>)}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : (
        children
      )}
    </section>
  )
}

const axis = { fontSize: 12, fill: '#525252' }
const tooltipStyle = { border: '1px solid #e0e0e0', borderRadius: 6, boxShadow: 'none', fontSize: 12, color: BRAND.ink }

const AgentPanel = lazy(() => import('@/features/agent/AgentPanel'))

function VisaoGeral() {
  const { data: realOrders, isLoading } = useOrders()
  const { data: realContacts } = useContacts()
  const { data: settings } = useSettings()
  const [demo, setDemo] = useState(false)
  const [period, setPeriod] = useState<Period>(30)
  const demoData = useMemo(() => (demo ? buildDemo() : null), [demo])
  const adReal = useAdTotals(period, !demo)
  const { data: goalsData } = useSetting('campaign_goals')
  const goals = goalsData ?? { max_cost_per_conversation: 6, max_cost_per_sale: 60, min_roas: 4 }

  const orders = useMemo<OrderCard[]>(() => (demo ? demoData!.orders : (realOrders ?? [])), [demo, demoData, realOrders])
  const contacts = useMemo<Contact[]>(() => (demo ? demoData!.contacts : (realContacts ?? [])), [demo, demoData, realContacts])
  const kanban = settings?.kanban ?? DEFAULT_KANBAN

  const model = useMemo(() => {
    const today = startOfDay(Date.now())
    const to = today + DAY
    const from = to - period * DAY
    const cur = summarize(orders, from, to)
    const prev = summarize(orders, from - period * DAY, from)

    const days: { key: number; label: string; Faturamento: number; Lucro: number; Contatos: number }[] = []
    for (let t = from; t < to; t += DAY) {
      days.push({ key: t, label: new Date(t).toLocaleDateString('pt-BR', { day: '2-digit', month: '2-digit' }), Faturamento: 0, Lucro: 0, Contatos: 0 })
    }
    const idx = (t: number) => Math.floor((startOfDay(t) - from) / DAY)
    for (const o of orders) {
      if (!isPaid(o)) continue
      const i = idx(paidTime(o))
      if (i >= 0 && i < days.length) {
        days[i].Faturamento += o.fin.total
        days[i].Lucro += o.fin.net_profit
      }
    }
    for (const c of contacts) {
      const i = idx(new Date(c.created_at).getTime())
      if (i >= 0 && i < days.length) days[i].Contatos += 1
    }
    // Agrupa por semana quando o período é longo, para o gráfico respirar
    const weekly = period >= 90
    const series = weekly
      ? Array.from({ length: Math.ceil(days.length / 7) }, (_, w) => {
          const chunk = days.slice(w * 7, w * 7 + 7)
          return {
            label: chunk[0].label,
            Faturamento: chunk.reduce((n, d) => n + d.Faturamento, 0),
            Lucro: chunk.reduce((n, d) => n + d.Lucro, 0),
            Contatos: chunk.reduce((n, d) => n + d.Contatos, 0),
          }
        })
      : days

    const inPeriod = orders.filter((o) => new Date(o.created_at).getTime() >= from)
    const funnel = ORDER_STAGES.map((s) => ({ etapa: s.label, Pedidos: orders.filter((o) => o.stage === s.value).length }))
    const stalled = ORDER_STAGES.map((s) => ({ etapa: s.label, Parados: orders.filter((o) => o.stage === s.value && isStalled(o, kanban)).length })).filter((x) => x.Parados > 0)

    const byOrigin = new Map<string, number>()
    for (const o of orders.filter((o) => isPaid(o) && paidTime(o) >= from)) {
      const k = o.origin_label ? `Anúncio: ${o.origin_label}` : 'Orgânico'
      byOrigin.set(k, (byOrigin.get(k) ?? 0) + o.fin.total)
    }
    const origins = [...byOrigin.entries()].map(([origem, Faturamento]) => ({ origem, Faturamento: Math.round(Faturamento) })).sort((a, b) => b.Faturamento - a.Faturamento).slice(0, 6)

    const open = orders.filter((o) => !['entregue', 'recompra'].includes(o.stage))
    const consent = {
      aceita: contacts.filter((c) => c.marketing_consent === 'opted_in').length,
      parar: contacts.filter((c) => c.marketing_consent === 'opted_out').length,
      semRegistro: contacts.filter((c) => c.marketing_consent === 'none').length,
    }
    return { cur, prev, series, funnel, stalled, origins, open, inPeriod, consent, weekly }
  }, [orders, contacts, period, kanban])

  // Campanhas: dados reais do banco ou, no modo demonstração, números de exemplo coerentes com os pedidos
  const ads = useMemo(() => {
    if (demo) {
      const spend = Math.round(model.cur.revenue * 0.14)
      const convs = Math.round(model.cur.created * 1.4)
      return adMetrics({ spend, conversations: convs, quotes: Math.round(convs * 0.5), paid_orders: model.cur.paid, revenue: model.cur.revenue, net_profit: model.cur.profit })
    }
    return adReal.data ?? null
  }, [demo, model.cur, adReal.data])
  const showAds = !!ads && (ads.spend > 0 || ads.conversations > 0)

  const noData = !demo && !isLoading && orders.length === 0

  return (
    <div className="h-full overflow-y-auto">
      <header className="flex flex-wrap items-center justify-between gap-3 border-b px-4 py-3">
        <div>
          <h1 className="text-xl font-black">Painel</h1>
          <p className="text-xs text-muted-foreground">{demo ? 'Dados de exemplo para apresentação. Nada é gravado.' : 'Resumo do negócio em tempo real.'}</p>
        </div>
        <div className="flex flex-wrap items-center gap-3">
          <label className="flex min-h-11 cursor-pointer items-center gap-2 text-sm font-medium md:min-h-0">
            <FlaskConical className="h-4 w-4" aria-hidden />
            Modo demonstração
            <Switch checked={demo} onCheckedChange={setDemo} aria-label="Modo demonstração" />
          </label>
          <Select aria-label="Período" className="w-44" value={String(period)} onChange={(e) => setPeriod(Number(e.target.value) as Period)}>
            <option value="7">Últimos 7 dias</option>
            <option value="30">Últimos 30 dias</option>
            <option value="90">Últimos 90 dias</option>
          </Select>
        </div>
      </header>

      {isLoading && !demo ? (
        <div className="grid gap-4 p-4 sm:grid-cols-2 lg:grid-cols-3">{[0, 1, 2, 3, 4, 5].map((i) => <Skeleton key={i} className="h-28" />)}</div>
      ) : noData ? (
        <EmptyState
          icon={BarChart3}
          title="O painel começa quando entrar o primeiro pedido"
          action={
            <div className="flex gap-2">
              <Button asChild><Link to="/kanban">Criar pedido</Link></Button>
              <Button variant="outline" onClick={() => setDemo(true)}>Ver com dados de exemplo</Button>
            </div>
          }
        >
          Faturamento, lucro, funil e origem dos clientes aparecem aqui assim que os pedidos forem criados e pagos.
        </EmptyState>
      ) : (
        <div className="space-y-4 p-4">
          <div className="grid grid-cols-2 gap-3 xl:grid-cols-3 2xl:grid-cols-6">
            <Tile label="Faturamento" value={formatBRL(model.cur.revenue)}><Delta now={model.cur.revenue} before={model.prev.revenue} /></Tile>
            <Tile label="Lucro líquido" value={formatBRL(model.cur.profit)}>
              <span className="text-xs text-muted-foreground tabular">{model.cur.revenue ? `${formatPct((model.cur.profit / model.cur.revenue) * 100, 1)} de margem` : '—'}</span>
            </Tile>
            <Tile label="Ticket médio" value={formatBRL(model.cur.ticket)}><Delta now={model.cur.ticket} before={model.prev.ticket} /></Tile>
            <Tile label="Pedidos pagos" value={formatNumber(model.cur.paid)}><Delta now={model.cur.paid} before={model.prev.paid} /></Tile>
            <Tile label="Conversão" value={formatPct(model.cur.conversion, 1)}>
              <span className="text-xs text-muted-foreground">dos pedidos criados no período</span>
            </Tile>
            <Tile label="Em andamento" value={formatNumber(model.open.length)}>
              <span className={cn('text-xs tabular', model.stalled.length ? 'font-semibold text-brand-red' : 'text-muted-foreground')}>
                {model.stalled.reduce((n, s) => n + s.Parados, 0)} parado(s)
              </span>
            </Tile>
          </div>

          {showAds && ads && (
            <section aria-label="Campanhas" className="rounded-md border bg-card p-4">
              <div className="mb-3 flex items-baseline justify-between gap-2">
                <h2 className="text-base font-black">Campanhas no período</h2>
                <Link to="/campanhas" className="text-sm font-semibold text-link underline">Ver detalhes</Link>
              </div>
              <div className="grid grid-cols-2 gap-3 md:grid-cols-5">
                {[
                  { l: 'Investimento', v: formatBRL(ads.spend), st: 'none' as const },
                  { l: 'Custo por conversa', v: ads.cpc === null ? '—' : formatBRL(ads.cpc), st: goalState('cost', ads.cpc, goals.max_cost_per_conversation) },
                  { l: 'Custo por venda', v: ads.cps === null ? '—' : formatBRL(ads.cps), st: goalState('cost', ads.cps, goals.max_cost_per_sale) },
                  { l: 'ROAS', v: ads.roas === null ? '—' : `${ads.roas.toFixed(1).replace('.', ',')}x`, st: goalState('roas', ads.roas, goals.min_roas) },
                  { l: 'Lucro após anúncio', v: formatBRL(ads.profitAfterAds), st: (ads.profitAfterAds >= 0 ? 'good' : 'bad') as 'good' | 'bad' },
                ].map((t) => (
                  <div key={t.l} className={cn('min-w-0 border-l-4 pl-3', t.st === 'good' ? 'border-brand-green' : t.st === 'bad' ? 'border-brand-red' : 'border-brand-cyan')}>
                    <p className="truncate text-[11px] font-medium uppercase tracking-[0.12em] text-muted-foreground">{t.l}</p>
                    <p className="truncate text-xl font-black tabular">{t.v}</p>
                  </div>
                ))}
              </div>
            </section>
          )}

          <div className="grid gap-4 xl:grid-cols-2">
            <ChartCard
              title="Faturamento e lucro líquido"
              subtitle={model.weekly ? 'Por semana, pedidos pagos' : 'Por dia, pedidos pagos'}
              table={{ head: ['Data', 'Faturamento', 'Lucro'], rows: model.series.map((d) => [d.label, formatBRL(d.Faturamento), formatBRL(d.Lucro)]) }}
            >
              <div role="img" aria-label="Gráfico de linhas com faturamento e lucro líquido no período" className="h-64">
                <ResponsiveContainer width="100%" height="100%">
                  <LineChart data={model.series} margin={{ top: 8, right: 12, left: 0, bottom: 0 }}>
                    <CartesianGrid stroke="#ececec" vertical={false} />
                    <XAxis dataKey="label" tick={axis} tickLine={false} axisLine={{ stroke: '#d4d4d4' }} minTickGap={24} />
                    <YAxis tick={axis} tickLine={false} axisLine={false} tickFormatter={formatBRLCompact} width={76} />
                    <Tooltip contentStyle={tooltipStyle} formatter={(v) => formatBRL(Number(v))} />
                    <Legend iconType="plainline" wrapperStyle={{ fontSize: 12 }} />
                    <Line type="monotone" dataKey="Faturamento" stroke={SERIES[0]} strokeWidth={2} dot={false} activeDot={{ r: 4, stroke: '#fff', strokeWidth: 2 }} />
                    <Line type="monotone" dataKey="Lucro" name="Lucro líquido" stroke={SERIES[1]} strokeWidth={2} dot={false} activeDot={{ r: 4, stroke: '#fff', strokeWidth: 2 }} />
                  </LineChart>
                </ResponsiveContainer>
              </div>
            </ChartCard>

            <ChartCard title="Funil de pedidos" subtitle="Quantos pedidos estão em cada etapa agora" table={{ head: ['Etapa', 'Pedidos'], rows: model.funnel.map((f) => [f.etapa, f.Pedidos]) }}>
              <div role="img" aria-label="Gráfico de barras com a quantidade de pedidos por etapa" className="h-64">
                <ResponsiveContainer width="100%" height="100%">
                  <BarChart data={model.funnel} layout="vertical" margin={{ top: 0, right: 32, left: 0, bottom: 0 }}>
                    <CartesianGrid stroke="#ececec" horizontal={false} />
                    <XAxis type="number" tick={axis} tickLine={false} axisLine={false} allowDecimals={false} />
                    <YAxis type="category" dataKey="etapa" tick={axis} tickLine={false} axisLine={false} width={150} />
                    <Tooltip contentStyle={tooltipStyle} cursor={{ fill: '#f5f5f5' }} />
                    <Bar dataKey="Pedidos" fill={SERIES[0]} radius={[0, 4, 4, 0]} barSize={14} label={{ position: 'right', fontSize: 12, fill: BRAND.ink }} />
                  </BarChart>
                </ResponsiveContainer>
              </div>
            </ChartCard>

            <ChartCard title="De onde vem o faturamento" subtitle="Pedidos pagos por origem, no período" table={{ head: ['Origem', 'Faturamento'], rows: model.origins.map((o) => [o.origem, formatBRL(o.Faturamento)]) }}>
              {model.origins.length === 0 ? (
                <p className="py-10 text-center text-sm text-muted-foreground">Sem pedidos pagos no período.</p>
              ) : (
                <div role="img" aria-label="Gráfico de barras com faturamento por origem" className="h-64">
                  <ResponsiveContainer width="100%" height="100%">
                    <BarChart data={model.origins} layout="vertical" margin={{ top: 0, right: 64, left: 0, bottom: 0 }}>
                      <CartesianGrid stroke="#ececec" horizontal={false} />
                      <XAxis type="number" tick={axis} tickLine={false} axisLine={false} tickFormatter={formatBRLCompact} />
                      <YAxis type="category" dataKey="origem" tick={axis} tickLine={false} axisLine={false} width={170} />
                      <Tooltip contentStyle={tooltipStyle} cursor={{ fill: '#f5f5f5' }} formatter={(v) => formatBRL(Number(v))} />
                      <Bar dataKey="Faturamento" fill={SERIES[1]} radius={[0, 4, 4, 0]} barSize={14} label={{ position: 'right', fontSize: 12, fill: BRAND.ink, formatter: (v: unknown) => formatBRLCompact(Number(v)) }} />
                    </BarChart>
                  </ResponsiveContainer>
                </div>
              )}
            </ChartCard>

            <ChartCard title="Novos contatos" subtitle={model.weekly ? 'Por semana' : 'Por dia'} table={{ head: ['Data', 'Contatos'], rows: model.series.map((d) => [d.label, d.Contatos]) }}>
              <div role="img" aria-label="Gráfico de barras com novos contatos no período" className="h-64">
                <ResponsiveContainer width="100%" height="100%">
                  <BarChart data={model.series} margin={{ top: 8, right: 12, left: 0, bottom: 0 }}>
                    <CartesianGrid stroke="#ececec" vertical={false} />
                    <XAxis dataKey="label" tick={axis} tickLine={false} axisLine={{ stroke: '#d4d4d4' }} minTickGap={24} />
                    <YAxis tick={axis} tickLine={false} axisLine={false} allowDecimals={false} width={32} />
                    <Tooltip contentStyle={tooltipStyle} cursor={{ fill: '#f5f5f5' }} />
                    <Bar dataKey="Contatos" fill={SERIES[2]} radius={[4, 4, 0, 0]} />
                  </BarChart>
                </ResponsiveContainer>
              </div>
            </ChartCard>
          </div>

          <div className="grid gap-4 lg:grid-cols-2">
            <section className="rounded-md border bg-card p-4">
              <h2 className="text-base font-black">Pedidos parados</h2>
              <p className="text-xs text-muted-foreground">Acima do tempo limite de cada etapa (ajuste em Configurações)</p>
              {model.stalled.length === 0 ? (
                <p className="mt-4 text-sm text-brand-green font-semibold">Nenhum pedido parado. Tudo andando.</p>
              ) : (
                <ul className="mt-3 space-y-2">
                  {model.stalled.map((s) => (
                    <li key={s.etapa} className="flex items-center justify-between rounded-md border border-l-4 border-l-brand-red px-3 py-2 text-sm">
                      <span className="font-semibold">{s.etapa}</span>
                      <span className="tabular">{s.Parados} pedido(s)</span>
                    </li>
                  ))}
                </ul>
              )}
            </section>

            <section className="rounded-md border bg-card p-4">
              <h2 className="text-base font-black">Base de contatos e promoções</h2>
              <p className="text-xs text-muted-foreground">Consentimento para receber promoções no WhatsApp</p>
              <div className="mt-3 grid grid-cols-3 gap-3 text-center">
                <div><p className="text-2xl font-black tabular text-brand-green">{formatNumber(model.consent.aceita)}</p><p className="text-xs text-muted-foreground">aceitam promoções</p></div>
                <div><p className="text-2xl font-black tabular">{formatNumber(model.consent.semRegistro)}</p><p className="text-xs text-muted-foreground">sem registro</p></div>
                <div><p className="text-2xl font-black tabular text-brand-red">{formatNumber(model.consent.parar)}</p><p className="text-xs text-muted-foreground">pediram para parar</p></div>
              </div>
              <div className="mt-4 flex h-3 overflow-hidden rounded-sm" role="img" aria-label="Proporção de contatos por consentimento">
                {[
                  [model.consent.aceita, BRAND.green],
                  [model.consent.semRegistro, BRAND.gray],
                  [model.consent.parar, BRAND.red],
                ].map(([n, c], i) => (
                  <span key={i} style={{ width: `${(Number(n) / Math.max(1, contacts.length)) * 100}%`, background: String(c) }} className={i ? 'ml-0.5' : ''} />
                ))}
              </div>
            </section>
          </div>
        </div>
      )}
    </div>
  )
}

export default function Dashboard() {
  return (
    <Tabs defaultValue="geral" className="flex h-full min-h-0 flex-col">
      <TabsList>
        <TabsTrigger value="geral">Visão geral</TabsTrigger>
        <TabsTrigger value="agente">Agente</TabsTrigger>
      </TabsList>
      <TabsContent value="geral" className="min-h-0 flex-1 overflow-auto"><VisaoGeral /></TabsContent>
      <TabsContent value="agente" className="min-h-0 flex-1 overflow-auto"><Suspense fallback={<Skeleton className="m-4 h-40" />}><AgentPanel /></Suspense></TabsContent>
    </Tabs>
  )
}
