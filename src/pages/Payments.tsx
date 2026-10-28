import { AlertTriangle, Copy, CreditCard, Download, RefreshCw } from 'lucide-react'
import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { EmptyState, ErrorState } from '@/components/ui/empty-state'
import { Select } from '@/components/ui/select'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { useToast } from '@/components/ui/toast'
import { ALERTA_LABEL, STATUS_LABEL, useAlertas, useCobrancas, useCriarLink, useMpStatus, useResolveAlerta, type Cobranca } from '@/hooks/payments'
import { Skeleton } from '@/components/ui/skeleton'
import { useOrders } from '@/hooks/orders'
import { contactLabel } from '@/lib/format'
import { downloadCsv } from '@/lib/csv'
import { formatBRL } from '@/lib/money'
import { PAYMENT_LABELS, type PaymentStatus } from '@/lib/orders'
import { cn } from '@/lib/utils'

const TONE: Record<PaymentStatus, string> = {
  pendente: 'bg-brand-yellow/30 text-ink',
  aprovado: 'bg-brand-green/10 text-brand-green',
  recusado: 'bg-brand-red/10 text-brand-red',
  expirado: 'bg-ink/10 text-ink',
  estornado: 'bg-brand-magenta/10 text-ink',
}

const dt = (iso: string | null) => (iso ? new Date(iso).toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' }) : '—')

function PedidosTab() {
  const { data: orders, isLoading, error, refetch } = useOrders()
  const [status, setStatus] = useState<PaymentStatus | ''>('')
  const [period, setPeriod] = useState<'all' | '7' | '30' | 'month'>('30')

  const rows = useMemo(() => {
    const now = new Date()
    const start = period === 'all' ? 0 : period === 'month' ? new Date(now.getFullYear(), now.getMonth(), 1).getTime() : now.getTime() - Number(period) * 86_400_000
    return (orders ?? []).filter((o) => (!status || o.payment_status === status) && new Date(o.paid_at ?? o.created_at).getTime() >= start)
  }, [orders, status, period])

  const received = rows.filter((o) => o.payment_status === 'aprovado' || o.payment_manual)
  const pending = rows.filter((o) => o.payment_status === 'pendente')
  const sum = (l: typeof rows) => l.reduce((n, o) => n + o.fin.total, 0)

  return (
    <div className="flex h-full flex-col">
      <header className="flex flex-wrap items-center justify-between gap-3 border-b px-4 py-3">
        <h1 className="text-xl font-black">Pagamentos</h1>
        <div className="flex flex-wrap items-center gap-2">
          <Select aria-label="Período" className="w-44" value={period} onChange={(e) => setPeriod(e.target.value as typeof period)}>
            <option value="7">Últimos 7 dias</option><option value="30">Últimos 30 dias</option><option value="month">Este mês</option><option value="all">Todo o período</option>
          </Select>
          <Select aria-label="Status" className="w-44" value={status} onChange={(e) => setStatus(e.target.value as PaymentStatus | '')}>
            <option value="">Todos os status</option>
            {(Object.keys(PAYMENT_LABELS) as PaymentStatus[]).map((s) => <option key={s} value={s}>{PAYMENT_LABELS[s]}</option>)}
          </Select>
          <Button variant="outline" size="sm" disabled={!rows.length} onClick={() => downloadCsv('pagamentos.csv', ['Pedido', 'Cliente', 'Status', 'Método', 'Valor', 'Confirmado em', 'ID externo'], rows.map((o) => [o.number, contactLabel(o.contact), PAYMENT_LABELS[o.payment_status], o.payment_method ?? '', o.fin.total, o.payment_confirmed_at ?? '', o.payment_external_id ?? '']))}>
            <Download className="h-4 w-4" /> Exportar CSV
          </Button>
        </div>
      </header>

      {error ? (
        <ErrorState message="Não foi possível carregar os pagamentos." onRetry={() => refetch()} />
      ) : isLoading ? (
        <div className="space-y-2 p-4">{[0, 1, 2].map((i) => <Skeleton key={i} className="h-12 w-full" />)}</div>
      ) : (
        <div className="min-h-0 flex-1 overflow-auto p-4">
          <div className="mb-4 grid grid-cols-2 gap-3 md:grid-cols-3">
            <div className="border-l-4 border-brand-green pl-3"><p className="text-[11px] uppercase tracking-[0.12em] text-muted-foreground">Recebido</p><p className="text-2xl font-black tabular">{formatBRL(sum(received))}</p><p className="text-xs text-muted-foreground">{received.length} pagamento(s)</p></div>
            <div className="border-l-4 border-brand-yellow pl-3"><p className="text-[11px] uppercase tracking-[0.12em] text-muted-foreground">A receber</p><p className="text-2xl font-black tabular">{formatBRL(sum(pending))}</p><p className="text-xs text-muted-foreground">{pending.length} pedido(s) pendente(s)</p></div>
            <div className="col-span-2 border-l-4 border-brand-cyan pl-3 md:col-span-1"><p className="text-[11px] uppercase tracking-[0.12em] text-muted-foreground">Lucro líquido recebido</p><p className="text-2xl font-black tabular">{formatBRL(received.reduce((n, o) => n + o.fin.net_profit, 0))}</p></div>
          </div>
          {rows.length === 0 ? (
            <EmptyState icon={CreditCard} title="Nenhum pagamento neste filtro">
              Os pagamentos aparecem aqui por pedido. O Mercado Pago confirma sozinho quando o cliente paga; você também pode confirmar manualmente no pedido.
            </EmptyState>
          ) : (
            <table className="w-full min-w-[720px] text-sm">
              <thead><tr className="border-b text-left text-[11px] uppercase tracking-wide text-muted-foreground"><th className="py-2 font-medium">Pedido</th><th className="py-2 font-medium">Cliente</th><th className="py-2 font-medium">Status</th><th className="py-2 font-medium">Método</th><th className="py-2 text-right font-medium">Valor</th><th className="py-2 pl-4 font-medium">Confirmado em</th></tr></thead>
              <tbody>
                {rows.map((o) => (
                  <tr key={o.id} className="border-b hover:bg-secondary/50">
                    <td className="py-2"><Link to={`/kanban?pedido=${o.id}`} className="font-bold text-link underline">#{o.number}</Link></td>
                    <td className="py-2">{contactLabel(o.contact)}</td>
                    <td className="py-2"><Badge className={cn(TONE[o.payment_status])}>{PAYMENT_LABELS[o.payment_status]}{o.payment_manual ? ' (manual)' : ''}</Badge></td>
                    <td className="py-2 capitalize">{o.payment_method ?? '—'}</td>
                    <td className="py-2 text-right font-bold tabular">{formatBRL(o.fin.total)}</td>
                    <td className="py-2 pl-4 tabular text-muted-foreground">{dt(o.payment_confirmed_at)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
      )}
    </div>
  )
}

const MODO_TONE = { teste: 'bg-brand-yellow text-ink', producao: 'bg-brand-green/10 text-brand-green', manual: 'bg-ink/10 text-ink' } as const
const MODO_LABEL = { teste: 'TESTE', producao: 'Produção', manual: 'Manual' } as const
const COBRANCA_TONE: Record<string, string> = {
  pendente: 'bg-brand-yellow/30 text-ink', em_analise: 'bg-brand-cyan/20 text-ink', aprovado: 'bg-brand-green/10 text-brand-green',
  recusado: 'bg-brand-red/10 text-brand-red', cancelado: 'bg-ink/10 text-ink', expirado: 'bg-ink/10 text-ink',
  estornado: 'bg-brand-magenta/10 text-ink', contestado: 'bg-brand-red/10 text-brand-red', invalidado: 'bg-ink/10 text-ink',
}

function CobrancasTab() {
  const toast = useToast()
  const { data, isLoading, error, refetch } = useCobrancas()
  const { data: orders } = useOrders()
  const criar = useCriarLink()
  const totals = useMemo(() => new Map((orders ?? []).map((o) => [o.id, o.fin.total])), [orders])
  const agora = Date.now()

  const estado = (c: Cobranca) => (c.status === 'pendente' && c.expira_em && new Date(c.expira_em).getTime() < agora ? 'expirado' : c.status)
  const desatualizado = (c: Cobranca) => c.eh_link && totals.has(c.order_id) && Math.round((totals.get(c.order_id) ?? 0) * 100) !== Math.round(c.valor * 100)

  if (error) return <ErrorState message="Não foi possível carregar as cobranças." onRetry={() => refetch()} />
  if (isLoading) return <div className="space-y-2 p-4">{[0, 1, 2].map((i) => <Skeleton key={i} className="h-12 w-full" />)}</div>
  if (!data?.length) return <EmptyState icon={CreditCard} title="Nenhuma cobrança ainda">Gere o link de pagamento na aba Pagamento de um pedido. As cobranças e as tentativas dos clientes aparecem aqui.</EmptyState>

  return (
    <div className="overflow-auto p-4">
      <table className="w-full min-w-[820px] text-sm">
        <thead><tr className="border-b text-left text-[11px] uppercase tracking-wide text-muted-foreground"><th className="py-2 font-medium">Pedido</th><th className="py-2 font-medium">Cliente</th><th className="py-2 text-right font-medium">Valor</th><th className="py-2 pl-4 font-medium">Status</th><th className="py-2 font-medium">Método</th><th className="py-2 font-medium">Data</th><th className="py-2 font-medium">Modo</th><th className="py-2 text-right font-medium">Ações</th></tr></thead>
        <tbody>
          {data.map((c) => {
            const st = estado(c)
            const stale = desatualizado(c)
            const usable = c.eh_link && c.link_ativo && c.link && st === 'pendente' && !stale
            return (
              <tr key={c.id} className="border-b align-top hover:bg-secondary/50">
                <td className="py-2">{c.order ? <Link to={`/kanban?pedido=${c.order_id}`} className="font-bold text-link underline">#{c.order.number}</Link> : '—'}{c.order?.teste && <Badge className="ml-1 bg-brand-yellow text-ink">teste</Badge>}</td>
                <td className="py-2">{c.order?.contact ? contactLabel(c.order.contact) : '—'}</td>
                <td className="py-2 text-right font-bold tabular">{formatBRL(c.valor)}</td>
                <td className="py-2 pl-4">
                  <Badge className={cn(COBRANCA_TONE[st])}>{STATUS_LABEL[st]}</Badge>
                  {c.divergencia && <p className="mt-1 text-xs text-brand-red">{ALERTA_LABEL[c.divergencia] ?? c.divergencia}</p>}
                  {stale && <p className="mt-1 text-xs text-brand-red">O valor do pedido mudou. Gere um novo link.</p>}
                </td>
                <td className="py-2 capitalize">{c.metodo ?? '—'}</td>
                <td className="py-2 tabular text-muted-foreground">{dt(c.aprovado_em ?? c.criado_em)}{c.eh_link && c.expira_em && st === 'pendente' ? <span className="block text-xs">vence {dt(c.expira_em)}</span> : null}</td>
                <td className="py-2"><Badge className={MODO_TONE[c.modo]}>{MODO_LABEL[c.modo]}</Badge></td>
                <td className="py-2 text-right">
                  {c.eh_link && (
                    <span className="flex justify-end gap-1">
                      <Button variant="outline" size="sm" disabled={!usable} onClick={async () => { await navigator.clipboard.writeText(c.link!); toast('ok', 'Link copiado.') }}><Copy className="h-4 w-4" /> Copiar link</Button>
                      {c.order_id && st !== 'aprovado' && (
                        <Button variant="outline" size="sm" disabled={criar.isPending} onClick={() => criar.mutate({ pedidoId: c.order_id, novo: true }, { onSuccess: () => toast('ok', 'Novo link gerado. O anterior foi invalidado.'), onError: (e) => toast('error', e.message) })}><RefreshCw className="h-4 w-4" /> Gerar novo link</Button>
                      )}
                    </span>
                  )}
                </td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </div>
  )
}

function AlertasTab() {
  const { data, isLoading, error, refetch } = useAlertas()
  const resolve = useResolveAlerta()
  const [todos, setTodos] = useState(false)
  const rows = (data ?? []).filter((a) => todos || !a.resolvido_em)
  if (error) return <ErrorState message="Não foi possível carregar os alertas." onRetry={() => refetch()} />
  if (isLoading) return <div className="space-y-2 p-4">{[0, 1].map((i) => <Skeleton key={i} className="h-16 w-full" />)}</div>
  return (
    <div className="space-y-3 p-4">
      <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={todos} onChange={(e) => setTodos(e.target.checked)} /> Mostrar também os resolvidos</label>
      {rows.length === 0 ? (
        <EmptyState icon={CreditCard} title="Nenhum alerta">Valor diferente, estorno, contestação, pagamento recusado e referência desconhecida aparecem aqui. Nenhum desses casos altera o pedido sozinho.</EmptyState>
      ) : (
        <ul className="space-y-2">
          {rows.map((a) => (
            <li key={a.id} className={cn('flex flex-wrap items-start justify-between gap-3 rounded-md border p-3', !a.resolvido_em && 'border-brand-red/40 bg-brand-red/5')}>
              <div className="min-w-0">
                <p className="flex items-center gap-2 text-sm font-bold"><AlertTriangle className="h-4 w-4 text-brand-red" aria-hidden /> {ALERTA_LABEL[a.tipo] ?? a.tipo}{a.order ? <Link to={`/kanban?pedido=${a.order_id}`} className="font-normal text-link underline">pedido #{a.order.number}</Link> : null}</p>
                <p className="mt-1 text-sm">{a.mensagem}</p>
                <p className="mt-1 text-xs text-muted-foreground">{dt(a.criado_em)}{a.mp_payment_id ? ` · pagamento ${a.mp_payment_id}` : ''}</p>
              </div>
              <Button variant="outline" size="sm" onClick={() => resolve.mutate({ id: a.id, resolvido: !a.resolvido_em })}>{a.resolvido_em ? 'Reabrir' : 'Marcar como resolvido'}</Button>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}

export default function Payments() {
  const { data: mp } = useMpStatus()
  const { data: alertas } = useAlertas()
  const abertos = (alertas ?? []).filter((a) => !a.resolvido_em).length
  return (
    <div className="flex h-full flex-col">
      {mp?.modo === 'teste' && (
        <div role="status" className="bg-brand-yellow px-4 py-2 text-sm font-black text-ink">
          MODO TESTE do Mercado Pago: os pagamentos são de mentira e só pedidos marcados como teste mudam de etapa.
        </div>
      )}
      {mp && !mp.pronto && (
        <div role="alert" className="bg-brand-red/10 px-4 py-2 text-sm text-brand-red">Mercado Pago ainda não configurado no servidor. Faltam: {mp.faltando.join(', ')}. Veja docs/pagamento-mercadopago.md.</div>
      )}
      <Tabs defaultValue="pedidos" className="flex min-h-0 flex-1 flex-col">
        <TabsList>
          <TabsTrigger value="pedidos">Pedidos</TabsTrigger>
          <TabsTrigger value="cobrancas">Cobranças</TabsTrigger>
          <TabsTrigger value="alertas">Alertas{abertos > 0 ? ` (${abertos})` : ''}</TabsTrigger>
        </TabsList>
        <TabsContent value="pedidos"><PedidosTab /></TabsContent>
        <TabsContent value="cobrancas"><CobrancasTab /></TabsContent>
        <TabsContent value="alertas"><AlertasTab /></TabsContent>
      </Tabs>
    </div>
  )
}
