import { CreditCard, Download } from 'lucide-react'
import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { EmptyState, ErrorState } from '@/components/ui/empty-state'
import { Select } from '@/components/ui/select'
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

export default function Payments() {
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
              Os pagamentos aparecem aqui por pedido. A confirmação automática chega com a integração do Mercado Pago; até lá, confirme manualmente no pedido.
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
