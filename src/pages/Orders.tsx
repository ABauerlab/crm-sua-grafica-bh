import { Download, PackageCheck, Search, Truck } from 'lucide-react'
import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { SkuBadge } from '@/components/SkuBadge'
import { Button } from '@/components/ui/button'
import { ErrorState } from '@/components/ui/empty-state'
import { Input } from '@/components/ui/input'
import { Select } from '@/components/ui/select'
import { Skeleton } from '@/components/ui/skeleton'
import { useToast } from '@/components/ui/toast'
import { useAuth } from '@/auth/AuthProvider'
import { AVISO_LABEL, AVISO_STATUS, useDefinirSubestatus, useFornecedorLista, useMarcarEntregue, useMarcarFabrica, usePedidoAvisos, type PedidoAviso } from '@/hooks/etapa7'
import { useOrders } from '@/hooks/orders'
import { downloadCsv } from '@/lib/csv'
import { contactLabel } from '@/lib/format'
import { formatBRL } from '@/lib/money'
import { pedidoAtrasado, stageInfo, SUBESTATUS_LABEL, type OrderCard } from '@/lib/orders'
import { cn } from '@/lib/utils'

type Aba = 'arte' | 'producao' | 'prontos' | 'entregas' | 'atrasados' | 'hoje' | 'todos'
const ABAS: { v: Aba; label: string }[] = [
  { v: 'arte', label: 'Aguardando arte' },
  { v: 'producao', label: 'Em produção' },
  { v: 'prontos', label: 'Prontos para retirada' },
  { v: 'entregas', label: 'Entregas do dia' },
  { v: 'atrasados', label: 'Atrasados' },
  { v: 'hoje', label: 'Pagos hoje' },
  { v: 'todos', label: 'Todos' },
]

const hojeStr = () => new Date().toLocaleDateString('sv-SE')
const dia = (iso: string | null) => (iso ? new Date(iso).toLocaleDateString('sv-SE') : '')
const isPaid = (o: OrderCard) => o.payment_status === 'aprovado' || o.payment_manual
const emAndamento = (o: OrderCard) => ['pago', 'arte', 'prova', 'producao'].includes(o.stage)
const fmtData = (d: string | null) => (d ? d.split('-').reverse().slice(0, 2).join('/') : '-')
const pedidoNum = (o: OrderCard) => `SG-${String(o.number).padStart(4, '0')}`

function pertence(o: OrderCard, aba: Aba, hoje: string): boolean {
  switch (aba) {
    case 'arte': return isPaid(o) && ['pago', 'arte', 'prova'].includes(o.stage) && o.art_status !== 'aprovada'
    case 'producao': return o.stage === 'producao'
    case 'prontos': return o.stage === 'producao' && o.subestatus_pedido === 'pronto_retirada'
    case 'entregas': return o.stage === 'producao' && (o.subestatus_pedido === 'saiu_entrega' || (o.delivery_method === 'uber' && o.due_date === hoje))
    case 'atrasados': return pedidoAtrasado(o, hoje) // só em produção e fora do prazo útil
    case 'hoje': return isPaid(o) && dia(o.paid_at) === hoje
    default: return true
  }
}

function resumoItens(o: OrderCard) {
  if (!o.items.length) return o.title
  const a = `${o.items[0].qty}x ${o.items[0].description}`
  return o.items.length > 1 ? `${a} +${o.items.length - 1}` : a
}

function AvisoChip({ avisos }: { avisos: PedidoAviso[] | undefined }) {
  if (!avisos?.length) return null
  const ultimo = new Map<string, PedidoAviso>()
  for (const a of avisos) if (!ultimo.has(a.tipo)) ultimo.set(a.tipo, a)
  return (
    <span className="flex flex-wrap gap-1">
      {[...ultimo.values()].map((a) => (
        <span key={a.id} className={cn('rounded-sm px-1.5 py-0.5 text-[11px] font-bold', AVISO_STATUS[a.status].chip)} title={a.erro ?? undefined}>
          {AVISO_LABEL[a.tipo]}: {AVISO_STATUS[a.status].label}
        </span>
      ))}
    </span>
  )
}

function Resumo({ label, value, hint, alerta }: { label: string; value: string; hint?: string; alerta?: boolean }) {
  return (
    <div className={cn('min-w-0 border-l-4 pl-3', alerta ? 'border-brand-red' : 'border-brand-cyan')}>
      <p className="text-[11px] font-medium uppercase tracking-[0.12em] text-muted-foreground">{label}</p>
      <p className={cn('truncate text-xl font-black leading-tight tabular', alerta && 'text-brand-red')}>{value}</p>
      {hint && <p className="truncate text-xs text-muted-foreground">{hint}</p>}
    </div>
  )
}

function ListaFornecedor({ onClose }: { onClose: () => void }) {
  const toast = useToast()
  const { data, isLoading } = useFornecedorLista()
  const marcar = useMarcarFabrica()
  const texto = (data?.itens ?? []).map((i) => `${i.sku} x ${i.quantidade}`).join('\n')
  async function copiar() {
    try {
      await navigator.clipboard.writeText(texto)
      toast('ok', 'Lista copiada.')
    } catch {
      toast('error', 'Não foi possível copiar. Selecione o texto e copie à mão.')
    }
  }
  return (
    <section className="rounded-md border bg-card p-4" aria-label="Lista para o fornecedor">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <h2 className="font-black">Lista para o fornecedor</h2>
          <p className="text-xs text-muted-foreground">SKUs de todos os pedidos pagos ainda não enviados à fábrica. Uso interno.</p>
        </div>
        <Button variant="ghost" size="sm" onClick={onClose}>Fechar</Button>
      </div>
      {isLoading ? <Skeleton className="mt-3 h-24" /> : !data?.itens.length ? (
        <p className="mt-3 text-sm text-muted-foreground">Nenhum pedido pago esperando envio à fábrica.</p>
      ) : (
        <>
          <ul className="mt-3 divide-y text-sm">
            {data.itens.map((i) => (
              <li key={i.sku} className="flex flex-wrap items-center gap-2 py-1.5">
                <SkuBadge sku={i.sku === 'SEM SKU' ? null : i.sku} />
                <span className="font-black tabular">x {i.quantidade}</span>
                <span className="min-w-0 flex-1 truncate text-muted-foreground">{i.descricao}</span>
                <span className="text-xs text-muted-foreground">{i.pedidos.join(', ')}</span>
              </li>
            ))}
          </ul>
          <div className="mt-3 flex flex-wrap gap-2">
            <Button variant="outline" onClick={copiar}>Copiar lista</Button>
            <Button
              disabled={marcar.isPending}
              onClick={() => {
                if (!window.confirm(`Marcar ${data.pedidos.length} pedido(s) como enviados à fábrica?`)) return
                marcar.mutate(data.pedidos.map((p) => p.id), {
                  onSuccess: () => toast('ok', 'Pedidos marcados como enviados à fábrica.'),
                  onError: (e) => toast('error', (e as Error).message),
                })
              }}
            >
              Marcar como enviado à fábrica
            </Button>
          </div>
        </>
      )}
    </section>
  )
}

export default function Orders() {
  const toast = useToast()
  const { profile } = useAuth()
  const dono = profile?.role === 'admin'
  const { data: orders, isLoading, error, refetch } = useOrders()
  const { data: avisos } = usePedidoAvisos()
  const sub = useDefinirSubestatus()
  const entregue = useMarcarEntregue()
  const [aba, setAba] = useState<Aba>('producao')
  const [busca, setBusca] = useState('')
  const [etapa, setEtapa] = useState('')
  const [subf, setSubf] = useState('')
  const [pago, setPago] = useState('')
  const [entrega, setEntrega] = useState('')
  const [periodo, setPeriodo] = useState('')
  const [sel, setSel] = useState<Set<string>>(new Set())
  const [fornecedor, setFornecedor] = useState(false)
  const [trabalhando, setTrabalhando] = useState(false)
  const hoje = hojeStr()

  const base = useMemo(() => (orders ?? []).filter((o) => !o.teste), [orders])
  const contagem = useMemo(() => Object.fromEntries(ABAS.map((a) => [a.v, base.filter((o) => pertence(o, a.v, hoje)).length])) as Record<Aba, number>, [base, hoje])

  const resumo = useMemo(() => {
    const semana = Date.now() - 7 * 86_400_000
    const pagos = base.filter(isPaid)
    const pagosHoje = pagos.filter((o) => dia(o.paid_at) === hoje)
    const pagosSemana = pagos.filter((o) => o.paid_at && new Date(o.paid_at).getTime() >= semana)
    return {
      hojeQtd: pagosHoje.length,
      hojeValor: pagosHoje.reduce((n, o) => n + o.fin.total, 0),
      semQtd: pagosSemana.length,
      semValor: pagosSemana.reduce((n, o) => n + o.fin.total, 0),
      lucroSem: pagosSemana.reduce((n, o) => n + o.fin.net_profit, 0),
      produzir: base.filter((o) => emAndamento(o) && isPaid(o)).reduce((n, o) => n + o.items.reduce((m, i) => m + i.qty, 0), 0),
      atrasados: contagem.atrasados,
      prontos: contagem.prontos,
    }
  }, [base, contagem, hoje])

  const linhas = useMemo(() => {
    const q = busca.trim().toLowerCase()
    const limite = periodo ? Date.now() - Number(periodo) * 86_400_000 : 0
    return base
      .filter((o) => pertence(o, aba, hoje))
      .filter((o) => !etapa || o.stage === etapa)
      .filter((o) => !subf || (subf === 'nenhum' ? !o.subestatus_pedido : o.subestatus_pedido === subf))
      .filter((o) => !pago || (pago === 'sim' ? isPaid(o) : !isPaid(o)))
      .filter((o) => !entrega || (entrega === 'uber' ? o.delivery_method === 'uber' : o.delivery_method !== 'uber'))
      .filter((o) => !limite || new Date(o.created_at).getTime() >= limite)
      .filter((o) => !q || contactLabel(o.contact).toLowerCase().includes(q) || pedidoNum(o).toLowerCase().includes(q) || String(o.number) === q.replace(/\D/g, '') || o.items.some((i) => (i.code ?? '').toLowerCase().includes(q) || i.description.toLowerCase().includes(q)))
      .sort((a, b) => Number(b.urgente) - Number(a.urgente) || (a.due_date ?? '9999').localeCompare(b.due_date ?? '9999') || a.number - b.number)
  }, [base, aba, busca, etapa, subf, pago, entrega, periodo, hoje])

  const marcados = linhas.filter((o) => sel.has(o.id))
  const alternar = (id: string) => setSel((s) => { const n = new Set(s); if (n.has(id)) n.delete(id); else n.add(id); return n })

  async function lote(nome: string, fn: (o: OrderCard) => Promise<unknown>) {
    if (!marcados.length) return toast('error', 'Marque pelo menos um pedido.')
    if (!window.confirm(`${nome}: ${marcados.length} pedido(s)?`)) return
    setTrabalhando(true)
    const falhas: string[] = []
    for (const o of marcados) {
      try { await fn(o) } catch (e) { falhas.push(`${pedidoNum(o)}: ${(e as Error).message}`) }
    }
    setTrabalhando(false)
    setSel(new Set())
    if (falhas.length) toast('error', `${falhas.length} pedido(s) não mudaram. ${falhas.slice(0, 2).join(' | ')}`)
    else toast('ok', `${marcados.length} pedido(s) atualizados.`)
  }

  function exportar() {
    const rows = (marcados.length ? marcados : linhas).map((o) => [
      pedidoNum(o), contactLabel(o.contact), resumoItens(o), o.fin.total.toFixed(2).replace('.', ','), o.payment_method ?? '',
      dono ? o.fin.net_profit.toFixed(2).replace('.', ',') : '', stageInfo(o.stage).label, o.subestatus_pedido ? SUBESTATUS_LABEL[o.subestatus_pedido] : '',
      fmtData(o.due_date), o.delivery_method === 'uber' ? 'Entrega' : 'Retirada', o.origin_label ?? '', o.items.map((i) => i.code ?? '').filter(Boolean).join(' '),
    ])
    downloadCsv(`pedidos-${hoje}.csv`, ['Pedido', 'Cliente', 'Itens', 'Valor', 'Pagamento', dono ? 'Lucro líquido' : 'Lucro', 'Etapa', 'Subestatus', 'Previsão', 'Entrega', 'Origem', 'SKUs'], rows)
  }

  if (error) return <ErrorState message="Não foi possível carregar os pedidos." onRetry={() => refetch()} />

  return (
    <div className="flex h-full flex-col">
      <header className="flex flex-wrap items-center justify-between gap-2 border-b px-4 py-3">
        <h1 className="text-xl font-black">Pedidos</h1>
        <div className="flex flex-wrap gap-2">
          <Button variant="outline" onClick={() => setFornecedor((v) => !v)}><PackageCheck className="mr-1 h-4 w-4" aria-hidden /> Lista para o fornecedor</Button>
          <Button variant="outline" onClick={exportar}><Download className="mr-1 h-4 w-4" aria-hidden /> Exportar CSV</Button>
          <Button asChild variant="ghost"><Link to="/kanban">Ver como Kanban</Link></Button>
        </div>
      </header>

      <div className="grid grid-cols-2 gap-3 px-4 py-3 md:grid-cols-3 xl:grid-cols-6">
        <Resumo label="Pagos hoje" value={String(resumo.hojeQtd)} hint={formatBRL(resumo.hojeValor)} />
        <Resumo label="Pagos na semana" value={String(resumo.semQtd)} hint={formatBRL(resumo.semValor)} />
        {dono && <Resumo label="Lucro líquido (semana)" value={formatBRL(resumo.lucroSem)} />}
        <Resumo label="Itens a produzir" value={String(resumo.produzir)} hint="unidades em pedidos pagos" />
        <Resumo label="Atrasados" value={String(resumo.atrasados)} alerta={resumo.atrasados > 0} />
        <Resumo label="Prontos esperando retirada" value={String(resumo.prontos)} />
      </div>

      {fornecedor && <div className="px-4 pb-3"><ListaFornecedor onClose={() => setFornecedor(false)} /></div>}

      <nav className="flex gap-1 overflow-x-auto border-b px-2" aria-label="Visões dos pedidos">
        {ABAS.map((a) => (
          <button
            key={a.v}
            type="button"
            onClick={() => setAba(a.v)}
            aria-pressed={aba === a.v}
            className={cn('flex shrink-0 items-center gap-1.5 border-b-2 px-3 py-2.5 text-sm font-semibold', aba === a.v ? 'border-primary text-foreground' : 'border-transparent text-muted-foreground hover:text-foreground',
              a.v === 'atrasados' && contagem.atrasados > 0 && 'text-brand-red')}
          >
            {a.label}
            <span className={cn('rounded-sm px-1.5 text-xs tabular', a.v === 'atrasados' && contagem.atrasados > 0 ? 'bg-brand-red text-white' : 'bg-secondary')}>{contagem[a.v]}</span>
          </button>
        ))}
      </nav>

      <div className="grid gap-2 border-b px-4 py-3 sm:grid-cols-2 lg:grid-cols-6">
        <div className="relative lg:col-span-2">
          <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" aria-hidden />
          <Input value={busca} onChange={(e) => setBusca(e.target.value)} placeholder="Cliente, número ou SKU" aria-label="Buscar pedido" className="pl-9" />
        </div>
        <Select value={periodo} onChange={(e) => setPeriodo(e.target.value)} aria-label="Período">
          <option value="">Todo o período</option><option value="7">Últimos 7 dias</option><option value="30">Últimos 30 dias</option><option value="90">Últimos 90 dias</option>
        </Select>
        <Select value={etapa} onChange={(e) => setEtapa(e.target.value)} aria-label="Etapa do kanban">
          <option value="">Todas as etapas</option>
          {['novo', 'cotando', 'aguardando_pagamento', 'pago', 'arte', 'prova', 'producao', 'entregue', 'perdido'].map((s) => <option key={s} value={s}>{stageInfo(s as OrderCard['stage']).label}</option>)}
        </Select>
        <Select value={subf} onChange={(e) => setSubf(e.target.value)} aria-label="Subestatus">
          <option value="">Qualquer subestatus</option><option value="nenhum">Sem subestatus</option>
          {Object.entries(SUBESTATUS_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
        </Select>
        <div className="grid grid-cols-2 gap-2">
          <Select value={pago} onChange={(e) => setPago(e.target.value)} aria-label="Pagamento"><option value="">Pago ou não</option><option value="sim">Pago</option><option value="nao">Não pago</option></Select>
          <Select value={entrega} onChange={(e) => setEntrega(e.target.value)} aria-label="Retirada ou entrega"><option value="">Retirada/entrega</option><option value="retirada">Retirada</option><option value="uber">Entrega</option></Select>
        </div>
      </div>

      {marcados.length > 0 && (
        <div className="flex flex-wrap items-center gap-2 border-b bg-accent px-4 py-2 text-sm" role="region" aria-label="Ações em lote">
          <span className="font-bold">{marcados.length} marcado(s)</span>
          <Button size="sm" disabled={trabalhando} onClick={() => lote('Marcar como pronto para retirada', (o) => sub.mutateAsync({ order_id: o.id, sub: 'pronto_retirada' }))}><PackageCheck className="mr-1 h-4 w-4" aria-hidden /> Pronto</Button>
          <Button size="sm" disabled={trabalhando} onClick={() => lote('Marcar como saiu para entrega', (o) => sub.mutateAsync({ order_id: o.id, sub: 'saiu_entrega' }))}><Truck className="mr-1 h-4 w-4" aria-hidden /> Saiu para entrega</Button>
          <Button size="sm" disabled={trabalhando} onClick={() => lote('Marcar como entregue', (o) => entregue.mutateAsync(o.id))}>Entregue</Button>
          <Button size="sm" variant="outline" onClick={exportar}>Exportar marcados</Button>
          <Button size="sm" variant="ghost" onClick={() => setSel(new Set())}>Limpar</Button>
        </div>
      )}

      <div className="min-h-0 flex-1 overflow-auto">
        {isLoading ? (
          <div className="space-y-2 p-4">{[0, 1, 2, 3, 4].map((i) => <Skeleton key={i} className="h-14" />)}</div>
        ) : linhas.length === 0 ? (
          <p className="p-8 text-center text-sm text-muted-foreground">Nenhum pedido nesta visão.</p>
        ) : (
          <table className="w-full min-w-[1100px] text-sm">
            <thead className="sticky top-0 z-10 bg-background text-left text-xs uppercase tracking-wide text-muted-foreground">
              <tr className="border-b">
                <th className="w-8 px-3 py-2"><input type="checkbox" aria-label="Marcar todos" checked={marcados.length === linhas.length} onChange={(e) => setSel(e.target.checked ? new Set(linhas.map((o) => o.id)) : new Set())} /></th>
                <th className="px-2 py-2">Pedido</th><th className="px-2 py-2">Cliente</th><th className="px-2 py-2">Itens</th><th className="px-2 py-2 text-right">Valor</th>
                <th className="px-2 py-2">Pagamento</th>{dono && <th className="px-2 py-2 text-right">Lucro</th>}<th className="px-2 py-2">Etapa</th><th className="px-2 py-2">Subestatus</th>
                <th className="px-2 py-2">Previsão</th><th className="px-2 py-2">Entrega</th><th className="px-2 py-2">Origem</th><th className="px-2 py-2">SKUs</th>
              </tr>
            </thead>
            <tbody>
              {linhas.map((o) => {
                const atrasado = pertence(o, 'atrasados', hoje)
                return (
                  <tr key={o.id} className={cn('border-b align-top hover:bg-secondary/50', atrasado && 'bg-brand-red/5')}>
                    <td className="px-3 py-2"><input type="checkbox" aria-label={`Marcar ${pedidoNum(o)}`} checked={sel.has(o.id)} onChange={() => alternar(o.id)} /></td>
                    <td className="px-2 py-2 font-bold"><Link className="underline-offset-2 hover:underline" to={`/kanban?pedido=${o.id}`}>{pedidoNum(o)}</Link></td>
                    <td className="px-2 py-2">{contactLabel(o.contact)}</td>
                    <td className="max-w-[220px] px-2 py-2"><span className="line-clamp-2">{resumoItens(o)}</span></td>
                    <td className="px-2 py-2 text-right font-bold tabular">{formatBRL(o.fin.total)}</td>
                    <td className="px-2 py-2">{o.urgente && <span className="mr-1 rounded-sm bg-brand-red px-1 text-[10px] font-black text-white" title={o.urgente_motivo ?? 'Cliente com urgência'}>URGENTE</span>}{isPaid(o) ? <span className="text-brand-green">{o.payment_method ?? 'pago'}</span> : <span className="text-muted-foreground">pendente</span>}</td>
                    {dono && <td className={cn('px-2 py-2 text-right tabular', o.fin.net_profit < 0 && 'font-bold text-brand-red')}>{formatBRL(o.fin.net_profit)}</td>}
                    <td className="px-2 py-2"><span className={cn('rounded-sm px-1.5 py-0.5 text-[11px] font-bold', stageInfo(o.stage).chip)}>{stageInfo(o.stage).short}</span></td>
                    <td className="px-2 py-2"><div className="flex flex-col gap-1">{o.subestatus_pedido && <span className="text-xs font-semibold">{SUBESTATUS_LABEL[o.subestatus_pedido]}</span>}<AvisoChip avisos={avisos?.get(o.id)} /></div></td>
                    <td className={cn('px-2 py-2 tabular', atrasado && 'font-black text-brand-red')}>{fmtData(o.due_date)}{atrasado && ' · atrasado'}</td>
                    <td className="px-2 py-2">{o.delivery_method === 'uber' ? 'Entrega' : 'Retirada'}</td>
                    <td className="max-w-[140px] px-2 py-2"><span className="line-clamp-2 text-xs text-muted-foreground">{o.origin_label ?? '-'}</span></td>
                    <td className="px-2 py-2"><div className="flex flex-wrap gap-1">{o.items.slice(0, 3).map((i, n) => <SkuBadge key={`${i.code}-${n}`} sku={i.code} />)}</div></td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        )}
      </div>
    </div>
  )
}
