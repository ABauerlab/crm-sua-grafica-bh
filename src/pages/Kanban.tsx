import {
  DndContext,
  DragOverlay,
  KeyboardSensor,
  MouseSensor,
  TouchSensor,
  useDroppable,
  useSensor,
  useSensors,
  type DragEndEvent,
  type DragStartEvent,
} from '@dnd-kit/core'
import { Filter, Plus, Save, Trash2 } from 'lucide-react'
import { lazy, Suspense, useEffect, useMemo, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { Button } from '@/components/ui/button'
import { ErrorState } from '@/components/ui/empty-state'
import { Input } from '@/components/ui/input'
import { Modal } from '@/components/ui/sheet'
import { Select } from '@/components/ui/select'
import { Skeleton } from '@/components/ui/skeleton'
import { Textarea } from '@/components/ui/textarea'
import { useToast } from '@/components/ui/toast'
import { MetodoPagamentoField, type MetodoEscolhido } from '@/features/orders/MetodoPagamentoField'
import { OrderCardView, type CardActions } from '@/features/orders/OrderCardView'
import { PerdidosColumn } from '@/features/orders/PerdidosColumn'
import { PerderPedido } from '@/features/orders/PerderPedido'
import { countStalled, EMPTY_FILTERS, PRESET_VIEWS, useFilteredOrders, useSavedViews, type OrderFilters } from '@/features/orders/useOrderFilters'
import { useAddOrderEvent, useCreateOrder, useMoveOrder, useOrders, useSettings } from '@/hooks/orders'
import { useConfirmarManual } from '@/hooks/payments'
import { useContacts } from '@/hooks/queries'
import { contactLabel } from '@/lib/format'
import { formatBRL, formatPct } from '@/lib/money'
import { DEFAULT_KANBAN, isStalled, metodoValido, ORDER_STAGES, type OrderCard, type OrderStage } from '@/lib/orders'
import { cn } from '@/lib/utils'

const OrderDrawer = lazy(() => import('@/features/orders/OrderDrawer'))
const PAGE = 50

function Column({
  stage,
  orders,
  actions,
  settings,
}: {
  stage: (typeof ORDER_STAGES)[number]
  orders: OrderCard[]
  actions: CardActions
  settings: typeof DEFAULT_KANBAN
}) {
  const { setNodeRef, isOver } = useDroppable({ id: stage.value })
  const [limit, setLimit] = useState(PAGE)
  const total = orders.reduce((n, o) => n + o.fin.total, 0)
  return (
    <section
      ref={setNodeRef}
      id={`col-${stage.value}`}
      aria-label={stage.label}
      className={cn('flex w-72 shrink-0 flex-col rounded-md border bg-secondary/50', isOver && 'border-primary bg-accent')}
    >
      <div className={cn('h-1 rounded-t-md', stage.bar)} />
      <header className="px-3 py-2">
        <div className="flex items-center justify-between gap-2">
          <h2 className="text-sm font-black uppercase tracking-wide">{stage.label}</h2>
          <span className="rounded-sm bg-background px-1.5 py-0.5 text-xs font-bold tabular">{orders.length}</span>
        </div>
        <p className="text-xs text-muted-foreground tabular">{formatBRL(total)}</p>
      </header>
      <div className="flex min-h-24 flex-1 flex-col gap-2 overflow-y-auto px-2 pb-2">
        {orders.slice(0, limit).map((o) => (
          <OrderCardView key={o.id} order={o} settings={settings} actions={actions} stalled={isStalled(o, settings)} />
        ))}
        {orders.length > limit && (
          <Button variant="ghost" size="sm" onClick={() => setLimit((l) => l + PAGE)}>
            Mostrar mais {Math.min(PAGE, orders.length - limit)}
          </Button>
        )}
        {orders.length === 0 && <p className="px-1 py-6 text-center text-xs text-muted-foreground">Nenhum pedido nesta etapa</p>}
      </div>
    </section>
  )
}

function Kpi({ label, value, hint }: { label: string; value: string; hint?: string }) {
  return (
    <div className="min-w-0 border-l-4 border-brand-cyan pl-3">
      <p className="text-[11px] font-medium uppercase tracking-[0.12em] text-muted-foreground">{label}</p>
      <p className="truncate text-xl font-black leading-tight tabular">{value}</p>
      {hint && <p className="truncate text-xs text-muted-foreground">{hint}</p>}
    </div>
  )
}

export default function Kanban() {
  const toast = useToast()
  const [params, setParams] = useSearchParams()
  const { data: orders, isLoading, error, refetch } = useOrders()
  const { data: appSettings } = useSettings()
  const settings = appSettings?.kanban ?? DEFAULT_KANBAN
  const move = useMoveOrder()
  const addEvent = useAddOrderEvent()
  const create = useCreateOrder()
  const confirmarManual = useConfirmarManual()
  const [payMetodo, setPayMetodo] = useState<MetodoEscolhido>({ metodo: '', parcelas: 1 })
  const { data: contacts } = useContacts()
  const saved = useSavedViews()

  const [filters, setFilters] = useState<OrderFilters>({ ...EMPTY_FILTERS, q: params.get('q') ?? '' })
  const [showFilters, setShowFilters] = useState(false)
  const [activeId, setActiveId] = useState<string | null>(null)
  const [mobileStage, setMobileStage] = useState<OrderStage>('novo')
  const [payConfirm, setPayConfirm] = useState<{ order: OrderCard; then?: OrderStage } | null>(null)
  useEffect(() => {
    if (payConfirm) setPayMetodo({ metodo: metodoValido(payConfirm.order.payment_method) ? payConfirm.order.payment_method! : '', parcelas: payConfirm.order.parcelas ?? 1 })
  }, [payConfirm])
  const [note, setNote] = useState<{ order: OrderCard; text: string } | null>(null)
  const [perda, setPerda] = useState<OrderCard | null>(null)
  const [newOrder, setNewOrder] = useState<{ contactId: string; title: string; metodo: string; parcelas: number } | null>(null)
  const [viewName, setViewName] = useState('')
  const openId = params.get('pedido')

  const filtered = useFilteredOrders(orders, filters)
  const byStage = useMemo(() => {
    const map = new Map<OrderStage, OrderCard[]>(ORDER_STAGES.map((s) => [s.value, []]))
    for (const o of filtered) map.get(o.stage)?.push(o)
    // urgentes na frente (só ordena a fila, não muda prazo)
    for (const lista of map.values()) lista.sort((a, b) => Number(b.urgente) - Number(a.urgente))
    return map
  }, [filtered])

  const origins = useMemo(() => [...new Set((orders ?? []).map((o) => o.origin_label).filter(Boolean) as string[])].sort(), [orders])
  const paid = filtered.filter((o) => o.payment_status === 'aprovado' || o.payment_manual)
  const revenue = paid.reduce((n, o) => n + o.fin.total, 0)
  const profit = paid.reduce((n, o) => n + o.fin.net_profit, 0)
  const stalledCount = countStalled(filtered, settings)

  const sensors = useSensors(
    useSensor(MouseSensor, { activationConstraint: { distance: 6 } }),
    useSensor(TouchSensor, { activationConstraint: { delay: 200, tolerance: 6 } }),
    useSensor(KeyboardSensor),
  )

  function doMove(order: OrderCard, to: OrderStage) {
    if (order.stage === to) return
    // Perdido exige motivo: abre a pergunta em vez de mover direto
    if (to === 'perdido') return setPerda(order)
    move.mutate(
      { order, to },
      {
        onError: (e) => {
          // Bloqueio por falta de pagamento: oferece confirmar manualmente
          if (to === 'pago' && order.payment_status !== 'aprovado') setPayConfirm({ order, then: to })
          else toast('error', e.message)
        },
      },
    )
  }

  const actions: CardActions = {
    open: (o) => setParams((p) => { p.set('pedido', o.id); return p }, { replace: true }),
    move: doMove,
    markPaid: (o) => setPayConfirm({ order: o }),
    addNote: (o) => setNote({ order: o, text: '' }),
    copyPaymentLink: async (o) => {
      if (!o.payment_link) return toast('error', 'Este pedido ainda não tem link de pagamento.')
      await navigator.clipboard.writeText(o.payment_link)
      toast('ok', 'Link de pagamento copiado.')
    },
  }

  function onDragStart(e: DragStartEvent) {
    setActiveId(String(e.active.id))
  }
  function onDragEnd(e: DragEndEvent) {
    setActiveId(null)
    const order = orders?.find((o) => o.id === e.active.id)
    const to = e.over?.id as OrderStage | undefined
    if (order && to && to !== order.stage) doMove(order, to)
  }

  async function confirmPaid() {
    if (!payConfirm) return
    if (!payMetodo.metodo) return toast('error', 'Escolha o método de pagamento.')
    const { order, then } = payConfirm
    try {
      await confirmarManual.mutateAsync({ orderId: order.id, metodo: payMetodo.metodo, parcelas: payMetodo.parcelas })
    } catch (e) {
      return toast('error', (e as Error).message)
    }
    setPayConfirm(null)
    toast('ok', 'Pagamento confirmado manualmente.')
    if (then) move.mutate({ order: { ...order, payment_status: 'aprovado', payment_manual: true }, to: then }, { onError: (e) => toast('error', e.message) })
  }

  const active = orders?.find((o) => o.id === activeId)
  const set = <K extends keyof OrderFilters>(k: K, v: OrderFilters[K]) => setFilters((f) => ({ ...f, [k]: v }))
  const hasFilters = JSON.stringify(filters) !== JSON.stringify(EMPTY_FILTERS)

  return (
    <div className="flex h-full flex-col">
      <PerderPedido order={perda} onClose={() => setPerda(null)} />
      <header className="space-y-3 border-b px-4 py-3">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <h1 className="text-xl font-black">Pedidos</h1>
          <div className="flex items-center gap-2">
            <Button variant="outline" size="sm" onClick={() => setShowFilters((v) => !v)} aria-expanded={showFilters}>
              <Filter className="h-4 w-4" /> Filtros{hasFilters ? ' (ativos)' : ''}
            </Button>
            <Button size="sm" onClick={() => setNewOrder({ contactId: '', title: '', metodo: '', parcelas: 1 })}>
              <Plus className="h-4 w-4" /> Novo pedido
            </Button>
          </div>
        </div>

        <div className="grid grid-cols-2 gap-x-4 gap-y-3 md:grid-cols-5">
          <Kpi label="Faturamento" value={formatBRL(revenue)} hint={`${paid.length} pedido(s) pago(s)`} />
          <Kpi label="Lucro líquido" value={formatBRL(profit)} hint={revenue > 0 ? `${formatPct((profit / revenue) * 100)} de margem` : undefined} />
          <Kpi label="Ticket médio" value={formatBRL(paid.length ? revenue / paid.length : 0)} />
          <Kpi label="Conversão" value={formatPct(filtered.length ? (paid.length / filtered.length) * 100 : 0, 1)} hint={`${paid.length} de ${filtered.length} pedidos`} />
          <Kpi label="Parados" value={String(stalledCount)} hint="acima do limite da etapa" />
        </div>

        <nav aria-label="Etapas do pedido" className="flex gap-1.5 overflow-x-auto rounded-md border bg-card p-1.5">
          {ORDER_STAGES.map((st) => (
            <button
              key={st.value}
              onClick={() => {
                setMobileStage(st.value)
                document.getElementById(`col-${st.value}`)?.scrollIntoView({ behavior: 'smooth', inline: 'start', block: 'nearest' })
              }}
              className={cn('flex min-h-11 shrink-0 flex-1 items-center justify-center gap-1.5 rounded-md px-3 text-xs font-bold md:min-h-9', st.chip, mobileStage === st.value && 'ring-2 ring-ring')}
            >
              {st.short}
              <span className="rounded-sm bg-background/80 px-1.5 tabular">{byStage.get(st.value)?.length ?? 0}</span>
            </button>
          ))}
        </nav>

        {showFilters && (
          <div className="space-y-3 rounded-md border bg-secondary/40 p-3">
            <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-4">
              <Input aria-label="Buscar" placeholder="Buscar cliente, produto ou nº" value={filters.q} onChange={(e) => set('q', e.target.value)} />
              <Select aria-label="Período" value={filters.period} onChange={(e) => set('period', e.target.value as OrderFilters['period'])}>
                <option value="all">Todo o período</option>
                <option value="7d">Últimos 7 dias</option>
                <option value="30d">Últimos 30 dias</option>
                <option value="month">Este mês</option>
              </Select>
              <Select aria-label="Origem" value={filters.origin} onChange={(e) => set('origin', e.target.value)}>
                <option value="">Todas as origens</option>
                <option value="__organico">Orgânico</option>
                {origins.map((o) => (
                  <option key={o} value={o}>
                    Anúncio: {o}
                  </option>
                ))}
              </Select>
              <Input aria-label="Produto ou kit" placeholder="Produto ou kit" value={filters.product} onChange={(e) => set('product', e.target.value)} />
              <Input aria-label="Valor mínimo" type="number" inputMode="decimal" min="0" placeholder="Valor mínimo (R$)" value={filters.minValue} onChange={(e) => set('minValue', e.target.value)} />
              <Input aria-label="Valor máximo" type="number" inputMode="decimal" min="0" placeholder="Valor máximo (R$)" value={filters.maxValue} onChange={(e) => set('maxValue', e.target.value)} />
              <Select aria-label="Quem atende" value={filters.attendant} onChange={(e) => set('attendant', e.target.value as OrderFilters['attendant'])}>
                <option value="">IA e humano</option>
                <option value="ia">Somente IA</option>
                <option value="humano">Somente humano</option>
              </Select>
              <Select aria-label="Parado há" value={filters.stalledHours} onChange={(e) => set('stalledHours', e.target.value)}>
                <option value="">Qualquer tempo na etapa</option>
                <option value="4">Parado há 4 h ou mais</option>
                <option value="24">Parado há 24 h ou mais</option>
                <option value="72">Parado há 72 h ou mais</option>
              </Select>
            </div>
            <div className="flex flex-wrap items-center gap-3">
              <label className="flex min-h-11 items-center gap-2 text-sm md:min-h-0">
                <input type="checkbox" className="h-5 w-5 accent-[var(--brand-blue)] md:h-4 md:w-4" checked={filters.unread} onChange={(e) => set('unread', e.target.checked)} />
                Só com mensagem não lida
              </label>
              <Button variant="ghost" size="sm" onClick={() => setFilters(EMPTY_FILTERS)}>Limpar filtros</Button>
            </div>
            <div className="flex flex-wrap items-center gap-2 border-t pt-3">
              <span className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">Visões</span>
              {[...PRESET_VIEWS, ...saved.views].map((v) => (
                <span key={v.name} className="inline-flex items-center">
                  <button onClick={() => setFilters(v.filters)} className="min-h-9 rounded-md border bg-background px-2.5 text-xs font-semibold hover:bg-secondary">
                    {v.name}
                  </button>
                  {saved.views.some((s) => s.name === v.name) && (
                    <button onClick={() => saved.remove(v.name)} aria-label={`Excluir visão ${v.name}`} className="ml-0.5 flex h-9 w-9 items-center justify-center text-muted-foreground hover:text-brand-red">
                      <Trash2 className="h-3.5 w-3.5" />
                    </button>
                  )}
                </span>
              ))}
              <form
                className="ml-auto flex items-center gap-1"
                onSubmit={(e) => {
                  e.preventDefault()
                  if (viewName.trim()) {
                    saved.save(viewName.trim(), filters)
                    setViewName('')
                    toast('ok', 'Visão salva neste navegador.')
                  }
                }}
              >
                <Input aria-label="Nome da visão" placeholder="Nome da visão" className="w-40" value={viewName} onChange={(e) => setViewName(e.target.value)} />
                <Button type="submit" variant="outline" size="sm"><Save className="h-4 w-4" /> Salvar</Button>
              </form>
            </div>
          </div>
        )}
      </header>

      {error ? (
        <ErrorState message="Não foi possível carregar os pedidos." onRetry={() => refetch()} />
      ) : isLoading ? (
        <div className="flex gap-3 overflow-hidden p-4">
          {[0, 1, 2, 3].map((i) => <Skeleton key={i} className="h-64 w-72 shrink-0" />)}
        </div>
      ) : (
        <>
          {(orders?.length ?? 0) === 0 && (
            <div className="mx-4 mt-3 flex flex-wrap items-center justify-between gap-2 rounded-md border border-brand-cyan/40 bg-brand-cyan/10 px-3 py-2 text-sm">
              <p><strong>Nenhum pedido ainda.</strong> Cada pedido nasce de uma conversa e anda por estas etapas até a entrega.</p>
              <Button size="sm" onClick={() => setNewOrder({ contactId: '', title: '', metodo: '', parcelas: 1 })}><Plus className="h-4 w-4" /> Criar primeiro pedido</Button>
            </div>
          )}
          {/* Desktop e tablet: quadro com arrastar e soltar */}
          <DndContext sensors={sensors} onDragStart={onDragStart} onDragEnd={onDragEnd} onDragCancel={() => setActiveId(null)}>
            <div className="hidden min-h-0 flex-1 gap-3 overflow-x-auto p-4 md:flex">
              {ORDER_STAGES.map((s) => (
                <Column key={s.value} stage={s} orders={byStage.get(s.value) ?? []} actions={actions} settings={settings} />
              ))}
              <PerdidosColumn />
            </div>
            <DragOverlay>{active ? <OrderCardView order={active} settings={settings} actions={actions} stalled={isStalled(active, settings)} dragging draggable={false} /> : null}</DragOverlay>
          </DndContext>

          {/* Celular: lista por etapa com seletor */}
          <div className="min-h-0 flex-1 overflow-y-auto p-4 md:hidden">
            <Select aria-label="Etapa" value={mobileStage} onChange={(e) => setMobileStage(e.target.value as OrderStage)}>
              {ORDER_STAGES.map((s) => (
                <option key={s.value} value={s.value}>
                  {s.label} ({byStage.get(s.value)?.length ?? 0})
                </option>
              ))}
            </Select>
            <div className="mt-3 space-y-2">
              {(byStage.get(mobileStage) ?? []).slice(0, PAGE).map((o) => (
                <OrderCardView key={o.id} order={o} settings={settings} actions={actions} stalled={isStalled(o, settings)} draggable={false} />
              ))}
              {(byStage.get(mobileStage) ?? []).length === 0 && <p className="py-8 text-center text-sm text-muted-foreground">Nenhum pedido nesta etapa.</p>}
            </div>
            <PerdidosColumn mobile />
          </div>
        </>
      )}

      <Modal
        open={!!payConfirm}
        onOpenChange={(o) => !o && setPayConfirm(null)}
        title="Confirmar pagamento manualmente?"
        description="Use só se você já recebeu o valor e o Mercado Pago ainda não confirmou. Escolha como o cliente pagou: a taxa é calculada só desse método. Fica registrado no histórico."
      >
        <div className="mb-4"><MetodoPagamentoField value={payMetodo} onChange={setPayMetodo} /></div>
        <div className="flex justify-end gap-2">
          <Button variant="outline" onClick={() => setPayConfirm(null)}>Cancelar</Button>
          <Button onClick={confirmPaid} disabled={confirmarManual.isPending || !payMetodo.metodo}>Sim, já recebi</Button>
        </div>
      </Modal>

      <Modal open={!!note} onOpenChange={(o) => !o && setNote(null)} title="Adicionar nota">
        <Textarea aria-label="Nota" rows={4} value={note?.text ?? ''} onChange={(e) => setNote((n) => n && { ...n, text: e.target.value })} placeholder="Ex.: cliente pediu para retirar sexta" />
        <div className="mt-3 flex justify-end gap-2">
          <Button variant="outline" onClick={() => setNote(null)}>Cancelar</Button>
          <Button
            disabled={!note?.text.trim() || addEvent.isPending}
            onClick={() =>
              note &&
              addEvent.mutate(
                { orderId: note.order.id, kind: 'note', message: note.text.trim() },
                { onSuccess: () => { setNote(null); toast('ok', 'Nota adicionada.') }, onError: (e) => toast('error', e.message) },
              )
            }
          >
            Salvar nota
          </Button>
        </div>
      </Modal>

      <Modal open={!!newOrder} onOpenChange={(o) => !o && setNewOrder(null)} title="Novo pedido" description="Escolha o contato. A origem do anúncio é copiada automaticamente quando existir.">
        <div className="space-y-3">
          <Select aria-label="Contato" value={newOrder?.contactId ?? ''} onChange={(e) => setNewOrder((n) => n && { ...n, contactId: e.target.value })}>
            <option value="">Selecione o contato</option>
            {(contacts ?? []).map((c) => (
              <option key={c.id} value={c.id}>
                {contactLabel(c)}
              </option>
            ))}
          </Select>
          <Input aria-label="Título do pedido" placeholder="Ex.: 500 cartões de visita" value={newOrder?.title ?? ''} onChange={(e) => setNewOrder((n) => n && { ...n, title: e.target.value })} />
          <MetodoPagamentoField label="Como o cliente vai pagar" value={{ metodo: newOrder?.metodo ?? '', parcelas: newOrder?.parcelas ?? 1 }} onChange={(m) => setNewOrder((n) => n && { ...n, ...m })} />
        </div>
        <div className="mt-4 flex justify-end gap-2">
          <Button variant="outline" onClick={() => setNewOrder(null)}>Cancelar</Button>
          <Button
            disabled={!newOrder?.contactId || !newOrder.metodo || create.isPending}
            onClick={() =>
              newOrder &&
              create.mutate(newOrder, {
                onSuccess: (id) => {
                  setNewOrder(null)
                  setParams((p) => { p.set('pedido', id); return p }, { replace: true })
                },
                onError: (e) => toast('error', e.message),
              })
            }
          >
            Criar pedido
          </Button>
        </div>
      </Modal>

      {openId && (
        <Suspense fallback={null}>
          <OrderDrawer orderId={openId} onClose={() => setParams((p) => { p.delete('pedido'); return p }, { replace: true })} />
        </Suspense>
      )}
    </div>
  )
}
