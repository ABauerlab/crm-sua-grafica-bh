import { useMutation, useQueryClient } from '@tanstack/react-query'
import { AlertTriangle, Check, Copy, ExternalLink, FileUp, MessageSquare, Plus, Send, Trash2 } from 'lucide-react'
import { useEffect, useMemo, useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Modal, Sheet } from '@/components/ui/sheet'
import { Select } from '@/components/ui/select'
import { Skeleton } from '@/components/ui/skeleton'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { Switch } from '@/components/ui/switch'
import { Textarea } from '@/components/ui/textarea'
import { useToast } from '@/components/ui/toast'
import {
  useAddOrderEvent,
  useInvalidateOrders,
  useMoveOrder,
  useOrderEvents,
  useOrderFiles,
  useOrderItems,
  useOrders,
  useSettings,
  useUpdateOrder,
} from '@/hooks/orders'
import { resumoConferencia, useConferir, useConfirmarManual, useCriarLink, useMpStatus } from '@/hooks/payments'
import { invokeFunction } from '@/lib/api'
import { contactLabel, formatPhone } from '@/lib/format'
import { formatBRL, formatPct, parseMoney } from '@/lib/money'
import {
  ART_LABELS,
  blockReason,
  formatDuration,
  hoursInStage,
  ORDER_STAGES,
  PAYMENT_LABELS,
  stageInfo,
  type ArtStatus,
  type OrderCard,
  type OrderItem,
  type OrderStage,
  type PaymentStatus,
} from '@/lib/orders'
import { ProductPicker } from '@/features/catalog/KitsTab'
import { DEFAULT_PRICING, previewNetProfit, priceAlerts, unitFloor, type PriceAlert } from '@/lib/pricing'
import { supabase } from '@/lib/supabase'
import { cn } from '@/lib/utils'

const dt = (iso: string | null) => (iso ? new Date(iso).toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' }) : '—')

function Field({ label, children, hint }: { label: string; children: React.ReactNode; hint?: string }) {
  return (
    <div className="space-y-1.5">
      <Label>{label}</Label>
      {children}
      {hint && <p className="text-xs text-muted-foreground">{hint}</p>}
    </div>
  )
}

function Money({ label, value, strong, negative }: { label: string; value: number; strong?: boolean; negative?: boolean }) {
  return (
    <div className="flex items-baseline justify-between gap-3 py-1.5">
      <dt className="text-sm text-muted-foreground">{label}</dt>
      <dd className={cn('tabular', strong ? 'text-lg font-black' : 'text-sm font-semibold', negative && 'text-brand-red')}>{formatBRL(value)}</dd>
    </div>
  )
}

/** Pede justificativa quando algum limite de preço foi ultrapassado. */
function OverrideModal({ alerts, onCancel, onConfirm }: { alerts: PriceAlert[]; onCancel: () => void; onConfirm: (reason: string) => void }) {
  const [reason, setReason] = useState('')
  return (
    <Modal open onOpenChange={(o) => !o && onCancel()} title="Preço fora dos limites" description="Confirme só se for intencional. A justificativa fica registrada no histórico do pedido.">
      <ul className="mb-3 space-y-2" role="alert">
        {alerts.map((a) => (
          <li key={a.code + a.message} className="flex gap-2 rounded-md border border-brand-red/40 bg-brand-red/5 p-2.5 text-sm">
            <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-brand-red" aria-hidden />
            {a.message}
          </li>
        ))}
      </ul>
      <Label htmlFor="reason">Justificativa (obrigatória)</Label>
      <Textarea id="reason" rows={3} value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Ex.: cliente recorrente, fechou 2.000 unidades" />
      <div className="mt-4 flex justify-end gap-2">
        <Button variant="outline" onClick={onCancel}>Voltar e corrigir</Button>
        <Button variant="destructive" disabled={reason.trim().length < 5} onClick={() => onConfirm(reason.trim())}>
          Confirmar mesmo assim
        </Button>
      </div>
    </Modal>
  )
}

/* ---------- Resumo ---------- */
function SummaryTab({ order }: { order: OrderCard }) {
  const toast = useToast()
  const update = useUpdateOrder()
  const move = useMoveOrder()
  const [notes, setNotes] = useState(order.notes ?? '')
  const [title, setTitle] = useState(order.title)
  const info = stageInfo(order.stage)
  const hours = hoursInStage(order)
  return (
    <div className="space-y-5">
      <div className="flex flex-wrap items-center gap-2">
        <Badge className={cn('px-2 py-1 text-xs', info.chip)}>{info.label}</Badge>
        <span className="text-xs text-muted-foreground">há {formatDuration(hours)} nesta etapa</span>
        <span className="text-xs text-muted-foreground">· criado em {dt(order.created_at)}</span>
      </div>

      <div className="rounded-md border p-3">
        <p className="font-bold">{contactLabel(order.contact)}</p>
        <p className="text-sm text-muted-foreground">{formatPhone(order.contact.wa_id)}</p>
        <p className="mt-1 text-sm">{order.origin_label ? `Veio do anúncio: ${order.origin_label}` : 'Origem: orgânico'}</p>
        {order.origin_url && (
          <a href={order.origin_url} target="_blank" rel="noreferrer" className="inline-flex items-center gap-1 text-xs font-semibold text-link underline">
            Ver anúncio <ExternalLink className="h-3 w-3" />
          </a>
        )}
        {order.conversation && (
          <div className="mt-3">
            <Button asChild variant="outline" size="sm">
              <Link to={`/inbox/${order.conversation.id}`}><MessageSquare className="h-4 w-4" /> Abrir conversa</Link>
            </Button>
          </div>
        )}
      </div>

      <Field label="Etapa">
        <Select
          value={order.stage}
          onChange={(e) => {
            const to = e.target.value as OrderStage
            const reason = blockReason(order, to)
            if (reason) return toast('error', reason)
            move.mutate({ order, to }, { onError: (err) => toast('error', err.message) })
          }}
        >
          {ORDER_STAGES.map((s) => <option key={s.value} value={s.value}>{s.label}</option>)}
        </Select>
      </Field>

      <Field label="Título do pedido">
        <Input value={title} onChange={(e) => setTitle(e.target.value)} onBlur={() => title.trim() && title !== order.title && update.mutate({ id: order.id, patch: { title: title.trim() } })} />
      </Field>

      <dl className="rounded-md border px-3 py-1 divide-y">
        <Money label="Total do pedido" value={order.fin.total} strong />
        <Money label="Custo" value={order.fin.cost} />
        <Money label={`Impostos (${order.tax_pct}%)`} value={order.fin.tax} />
        <Money label={`Taxa de pagamento (${order.payment_fee_pct}%)`} value={order.fin.fee} />
        <Money label={`Lucro líquido (${formatPct(order.fin.margin_pct, 1)})`} value={order.fin.net_profit} strong negative={order.fin.net_profit < 0} />
      </dl>

      <Field label="Notas">
        <Textarea rows={4} value={notes} onChange={(e) => setNotes(e.target.value)} onBlur={() => notes !== (order.notes ?? '') && update.mutate({ id: order.id, patch: { notes: notes.trim() || null } })} placeholder="Observações internas do pedido" />
      </Field>
    </div>
  )
}

/* ---------- Itens ---------- */
function ItemsTab({ order }: { order: OrderCard }) {
  const toast = useToast()
  const invalidate = useInvalidateOrders()
  const update = useUpdateOrder()
  const addEvent = useAddOrderEvent()
  const { data: items, isLoading } = useOrderItems(order.id)
  const { data: settings } = useSettings()
  const rules = settings?.pricing ?? DEFAULT_PRICING
  const [draft, setDraft] = useState({ code: '', description: '', qty: '1', cost: '', price: '', lead: '' })
  const [discount, setDiscount] = useState(String(order.discount_pct))
  const [tax, setTax] = useState(String(order.tax_pct))
  const [fee, setFee] = useState(String(order.payment_fee_pct))
  const [pending, setPending] = useState<{ alerts: PriceAlert[]; run: (reason?: string) => Promise<void> } | null>(null)

  const fmt = formatBRL

  /** Roda a ação; se algum limite for ultrapassado, pede justificativa antes. */
  function guarded(next: { items: OrderItem[]; discountPct: number; taxPct: number; feePct: number }, run: () => Promise<void>, onlyIfWorse = true) {
    const net = previewNetProfit(next.items, next.discountPct, next.taxPct, next.feePct)
    const alerts = priceAlerts({ items: next.items, discountPct: next.discountPct, netProfit: net }, rules, fmt)
    if (alerts.length === 0 || !onlyIfWorse) return run()
    setPending({
      alerts,
      run: async (reason) => {
        await run()
        const msg = `Preço fora dos limites. Justificativa: ${reason}. (${alerts.map((a) => a.message).join(' ')})`
        await update.mutateAsync({ id: order.id, patch: { price_override_reason: reason } })
        await addEvent.mutateAsync({ orderId: order.id, kind: 'price', message: msg })
      },
    })
  }

  const saveItem = useMutation({
    mutationFn: async (it: Partial<OrderItem> & { id?: string }) => {
      const row = { order_id: order.id, code: it.code || null, description: it.description!, qty: it.qty!, unit_cost: it.unit_cost!, unit_price: it.unit_price!, lead_days: it.lead_days ?? null }
      const { error } = it.id ? await supabase.from('order_items').update(row).eq('id', it.id) : await supabase.from('order_items').insert(row)
      if (error) throw new Error(error.message)
    },
    onSettled: () => invalidate(order.id),
    onError: (e: Error) => toast('error', e.message),
  })

  const removeItem = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.from('order_items').delete().eq('id', id)
      if (error) throw new Error(error.message)
    },
    onSettled: () => invalidate(order.id),
    onError: (e: Error) => toast('error', e.message),
  })

  function addItem() {
    const it = { description: draft.description.trim(), qty: Math.max(1, Math.floor(Number(draft.qty) || 1)), unit_cost: parseMoney(draft.cost), unit_price: parseMoney(draft.price), lead_days: draft.lead.trim() ? Math.max(0, Math.round(Number(draft.lead) || 0)) : null }
    if (!it.description) return toast('error', 'Informe a descrição do item.')
    const next = [...(items ?? []), { ...it, id: 'novo', order_id: order.id, code: draft.code || null }]
    guarded({ items: next, discountPct: order.discount_pct, taxPct: order.tax_pct, feePct: order.payment_fee_pct }, async () => {
      await saveItem.mutateAsync({ ...it, code: draft.code })
      setDraft({ code: '', description: '', qty: '1', cost: '', price: '', lead: '' })
    })
  }

  function saveParams() {
    const d = Math.min(100, Math.max(0, Number(discount) || 0))
    const t = Math.max(0, Number(tax) || 0)
    const f = Math.max(0, Number(fee) || 0)
    guarded({ items: items ?? [], discountPct: d, taxPct: t, feePct: f }, async () => {
      await update.mutateAsync({ id: order.id, patch: { discount_pct: d, tax_pct: t, payment_fee_pct: f } })
      toast('ok', 'Desconto e percentuais salvos.')
    })
  }

  const belowFloor = (it: { unit_cost: number; unit_price: number }) => it.unit_cost > 0 && it.unit_price < unitFloor(it.unit_cost, rules)
  const current = priceAlerts({ items: items ?? [], discountPct: order.discount_pct, netProfit: order.fin.net_profit }, rules, fmt)

  return (
    <div className="space-y-5">
      {current.length > 0 && (
        <ul className="space-y-2" role="alert">
          {current.map((a) => (
            <li key={a.message} className="flex gap-2 rounded-md border border-brand-red/40 bg-brand-red/5 p-2.5 text-sm">
              <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-brand-red" aria-hidden /> {a.message}
            </li>
          ))}
          {order.price_override_reason && <li className="text-xs text-muted-foreground">Justificativa registrada: {order.price_override_reason}</li>}
        </ul>
      )}

      <p className="text-xs text-muted-foreground">
        Regras: piso = custo x {rules.floor_multiplier} · desconto máximo sem consulta {rules.max_discount_pct}% · lucro líquido mínimo {fmt(rules.min_net_profit)}. Altere em Configurações.
      </p>

      {isLoading ? (
        <Skeleton className="h-24 w-full" />
      ) : (
        <ul className="space-y-2">
          {(items ?? []).map((it) => (
            <ItemRow key={it.id} item={it} below={belowFloor(it)} floor={unitFloor(it.unit_cost, rules)} onRemove={() => removeItem.mutate(it.id)}
              onSave={(patch) => {
                const nextItems = (items ?? []).map((x) => (x.id === it.id ? { ...x, ...patch } : x))
                guarded({ items: nextItems, discountPct: order.discount_pct, taxPct: order.tax_pct, feePct: order.payment_fee_pct }, async () => { await saveItem.mutateAsync({ ...it, ...patch }) })
              }}
            />
          ))}
          {(items ?? []).length === 0 && <li className="rounded-md border border-dashed p-4 text-center text-sm text-muted-foreground">Nenhum item ainda. Adicione o primeiro abaixo.</li>}
        </ul>
      )}

      <fieldset className="space-y-2 rounded-md border bg-secondary/40 p-3">
        <legend className="px-1 text-xs font-bold uppercase tracking-wide">Adicionar item</legend>
        <ProductPicker onPick={(p) => setDraft({ code: p.code, description: p.description, qty: String(p.qty ?? 1), cost: String(p.cost), price: String(p.suggested_price), lead: p.lead_days === null ? '' : String(p.lead_days) })} />
        <div className="grid grid-cols-2 gap-2 sm:grid-cols-6">
          <Input aria-label="Código" placeholder="Código" className="sm:col-span-1" value={draft.code} onChange={(e) => setDraft({ ...draft, code: e.target.value })} />
          <Input aria-label="Descrição" placeholder="Descrição do produto" className="col-span-2 sm:col-span-3" value={draft.description} onChange={(e) => setDraft({ ...draft, description: e.target.value })} />
          <Input aria-label="Quantidade" type="number" min="1" inputMode="numeric" placeholder="Qtd" value={draft.qty} onChange={(e) => setDraft({ ...draft, qty: e.target.value })} />
          <Input aria-label="Prazo do fornecedor em dias" type="number" min="0" inputMode="numeric" placeholder="Prazo (dias)" value={draft.lead} onChange={(e) => setDraft({ ...draft, lead: e.target.value })} />
          <Input aria-label="Custo unitário" inputMode="decimal" placeholder="Custo un. (R$)" className="sm:col-span-2" value={draft.cost} onChange={(e) => setDraft({ ...draft, cost: e.target.value })} />
          <Input aria-label="Preço unitário" inputMode="decimal" placeholder="Preço un. (R$)" className="sm:col-span-2" value={draft.price} onChange={(e) => setDraft({ ...draft, price: e.target.value })} />
          <Button className="col-span-2 sm:col-span-2" onClick={addItem} disabled={saveItem.isPending}><Plus className="h-4 w-4" /> Adicionar</Button>
        </div>
      </fieldset>

      <fieldset className="space-y-2 rounded-md border p-3">
        <legend className="px-1 text-xs font-bold uppercase tracking-wide">Desconto, impostos e taxa</legend>
        <div className="grid grid-cols-3 gap-2">
          <Field label="Desconto (%)"><Input type="number" step="0.5" min="0" max="100" inputMode="decimal" value={discount} onChange={(e) => setDiscount(e.target.value)} /></Field>
          <Field label="Impostos (%)"><Input type="number" step="0.1" min="0" inputMode="decimal" value={tax} onChange={(e) => setTax(e.target.value)} /></Field>
          <Field label="Taxa pgto (%)"><Input type="number" step="0.1" min="0" inputMode="decimal" value={fee} onChange={(e) => setFee(e.target.value)} /></Field>
        </div>
        <Button variant="outline" size="sm" onClick={saveParams}>Salvar percentuais</Button>
      </fieldset>

      <dl className="rounded-md border px-3 py-1 divide-y">
        {order.lead_days != null && <div className="flex justify-between py-2 text-sm"><dt className="text-muted-foreground">Prazo do fornecedor</dt><dd className="font-semibold tabular">{order.lead_days} dia(s)</dd></div>}
        <Money label="Subtotal" value={order.fin.gross} />
        <Money label="Total com desconto" value={order.fin.total} strong />
        <Money label="Custo total" value={order.fin.cost} />
        <Money label={`Impostos estimados (${order.tax_pct}%)`} value={order.fin.tax} />
        <Money label={`Taxa de pagamento (${order.payment_fee_pct}%)`} value={order.fin.fee} />
        <Money label={`Lucro líquido (${formatPct(order.fin.margin_pct, 1)})`} value={order.fin.net_profit} strong negative={order.fin.net_profit < 0} />
      </dl>

      {pending && (
        <OverrideModal
          alerts={pending.alerts}
          onCancel={() => setPending(null)}
          onConfirm={async (reason) => {
            const p = pending
            setPending(null)
            await p.run(reason)
          }}
        />
      )}
    </div>
  )
}

function ItemRow({ item, below, floor, onSave, onRemove }: { item: OrderItem; below: boolean; floor: number; onSave: (p: Partial<OrderItem>) => void; onRemove: () => void }) {
  const [v, setV] = useState({ description: item.description, qty: String(item.qty), cost: String(item.unit_cost), price: String(item.unit_price) })
  const dirty = v.description !== item.description || Number(v.qty) !== item.qty || parseMoney(v.cost) !== item.unit_cost || parseMoney(v.price) !== item.unit_price
  return (
    <li className={cn('rounded-md border p-2.5', below && 'border-brand-red')}>
      <div className="grid grid-cols-6 gap-2">
        <label className="col-span-4 space-y-1 text-xs font-medium text-muted-foreground">
          Descrição
          <Input className="text-foreground" value={v.description} onChange={(e) => setV({ ...v, description: e.target.value })} />
        </label>
        <label className="col-span-2 space-y-1 text-xs font-medium text-muted-foreground">
          Quantidade
          <Input type="number" min="1" className="text-foreground" value={v.qty} onChange={(e) => setV({ ...v, qty: e.target.value })} />
        </label>
        <label className="col-span-3 space-y-1 text-xs font-medium text-muted-foreground">
          Custo unitário (R$)
          <Input inputMode="decimal" className="text-foreground" value={v.cost} onChange={(e) => setV({ ...v, cost: e.target.value })} />
        </label>
        <label className="col-span-3 space-y-1 text-xs font-medium text-muted-foreground">
          Preço unitário (R$)
          <Input inputMode="decimal" className={cn('text-foreground', below && 'border-brand-red')} value={v.price} onChange={(e) => setV({ ...v, price: e.target.value })} />
        </label>
      </div>
      <div className="mt-2 flex items-center justify-between gap-2 text-xs">
        <span className={cn('tabular', below ? 'font-bold text-brand-red' : 'text-muted-foreground')}>
          {below ? `Abaixo do piso de ${formatBRL(floor)}. ` : `Piso ${formatBRL(floor)}. `}
          Linha: {formatBRL(item.qty * item.unit_price)}{item.lead_days != null ? ` · prazo ${item.lead_days} d` : ''}
        </span>
        <span className="flex gap-1">
          {dirty && (
            <Button size="sm" onClick={() => onSave({ description: v.description.trim(), qty: Math.max(1, Math.floor(Number(v.qty) || 1)), unit_cost: parseMoney(v.cost), unit_price: parseMoney(v.price) })}>
              <Check className="h-4 w-4" /> Salvar
            </Button>
          )}
          <Button size="sm" variant="ghost" onClick={onRemove} aria-label="Remover item"><Trash2 className="h-4 w-4" /></Button>
        </span>
      </div>
    </li>
  )
}

/* ---------- Pagamento ---------- */
function PaymentTab({ order }: { order: OrderCard }) {
  const toast = useToast()
  const update = useUpdateOrder()
  const [link, setLink] = useState(order.payment_link ?? '')
  const [method, setMethod] = useState(order.payment_method ?? '')
  const [confirm, setConfirm] = useState(false)
  const [horas, setHoras] = useState('48')
  const criar = useCriarLink()
  const confirmar = useConfirmarManual()
  const conferir = useConferir()
  const { data: mp } = useMpStatus()
  const gerar = (novo: boolean) =>
    criar.mutate(
      { pedidoId: order.id, novo, horas: Number(horas) !== 48 ? Number(horas) : undefined },
      {
        onSuccess: (r) => {
          setLink(r.link)
          if (r.aviso) toast('error', r.aviso)
          else toast('ok', r.reutilizado ? 'Este pedido já tinha um link válido com o mesmo valor, então foi mantido. Para mudar a validade, use "Gerar novo link".' : 'Link do Mercado Pago gerado.')
        },
        onError: (e) => toast('error', e.message),
      },
    )

  const send = useMutation({
    mutationFn: () => invokeFunction('whatsapp-send', { conversation_id: order.conversation_id, text: `Segue o link para pagamento do seu pedido (${formatBRL(order.fin.total)}): ${link}` }),
    onSuccess: () => toast('ok', 'Link enviado ao cliente pelo WhatsApp.'),
    onError: (e: Error) => toast('error', e.message),
  })

  const tone: Record<PaymentStatus, string> = {
    pendente: 'bg-brand-yellow/30 text-ink',
    aprovado: 'bg-brand-green/10 text-brand-green',
    recusado: 'bg-brand-red/10 text-brand-red',
    expirado: 'bg-ink/10 text-ink',
    estornado: 'bg-brand-magenta/10 text-ink',
  }

  return (
    <div className="space-y-5">
      <div className="flex flex-wrap items-center gap-3 rounded-md border p-3">
        <Badge className={cn('px-2 py-1 text-xs', tone[order.payment_status])}>{PAYMENT_LABELS[order.payment_status]}</Badge>
        <span className="text-lg font-black tabular">{formatBRL(order.fin.total)}</span>
        {order.payment_manual && <Badge className="bg-ink/10 text-ink">Confirmado manualmente</Badge>}
      </div>

      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="Status do pagamento" hint="O Mercado Pago atualiza este campo sozinho quando o cliente paga.">
          <Select
            value={order.payment_status}
            onChange={(e) => {
              const s = e.target.value as PaymentStatus
              if (s === 'aprovado') return setConfirm(true)
              update.mutate({ id: order.id, patch: { payment_status: s } })
            }}
          >
            {(Object.keys(PAYMENT_LABELS) as PaymentStatus[]).map((s) => <option key={s} value={s}>{PAYMENT_LABELS[s]}</option>)}
          </Select>
        </Field>
        <Field label="Método">
          <Select value={method} onChange={(e) => { setMethod(e.target.value); update.mutate({ id: order.id, patch: { payment_method: e.target.value || null } }) }}>
            <option value="">Não definido</option>
            <option value="pix">Pix</option>
            <option value="cartao">Cartão</option>
            <option value="manual">Manual / dinheiro</option>
          </Select>
        </Field>
        <Field label="ID do pagamento"><Input value={order.payment_external_id ?? ''} readOnly placeholder="Preenchido pelo Mercado Pago" /></Field>
        <Field label="Confirmado em"><Input value={dt(order.payment_confirmed_at)} readOnly /></Field>
      </div>

      <fieldset className="space-y-3 rounded-md border p-3">
        <legend className="px-1 text-xs font-bold uppercase tracking-wide">Mercado Pago</legend>
        {mp?.modo === 'teste' && <p className="rounded-sm bg-brand-yellow/40 px-2 py-1 text-xs font-bold">MODO TESTE: nenhum pedido real é alterado.</p>}
        {mp && !mp.pronto && <p className="text-xs text-brand-red" role="alert">Mercado Pago ainda não configurado no servidor. Faltam: {mp.faltando.join(', ')}.</p>}
        <div className="flex flex-wrap items-end gap-2">
          <Field label="Validade (horas)"><Input type="number" min="0.1" max="168" step="any" className="w-28" value={horas} onChange={(e) => setHoras(e.target.value)} /></Field>
          <Button onClick={() => gerar(false)} disabled={criar.isPending || order.payment_status === 'aprovado' || !mp?.pronto}>
            {criar.isPending ? 'Gerando…' : order.payment_link ? 'Pegar link atual' : 'Gerar link de pagamento'}
          </Button>
          {order.payment_link && <Button variant="outline" onClick={() => gerar(true)} disabled={criar.isPending || order.payment_status === 'aprovado' || !mp?.pronto}>Gerar novo link</Button>}
        </div>
        <Button variant="outline" size="sm" disabled={conferir.isPending || !mp?.pronto || order.payment_status === 'aprovado'} onClick={() => conferir.mutate(order.id, { onSuccess: (r) => toast('ok', resumoConferencia(r)), onError: (e) => toast('error', e.message) })}>
          {conferir.isPending ? 'Conferindo…' : 'Conferir pagamento agora'}
        </Button>
        <label className="flex items-center gap-2 text-sm">
          <Switch checked={order.teste} onCheckedChange={(v) => update.mutate({ id: order.id, patch: { teste: v } })} aria-label="Pedido de teste" />
          Pedido de teste (só ele muda de etapa em modo teste)
        </label>
      </fieldset>

      <Field label="Link de pagamento">
        <div className="flex gap-2">
          <Input value={link} onChange={(e) => setLink(e.target.value)} onBlur={() => link !== (order.payment_link ?? '') && update.mutate({ id: order.id, patch: { payment_link: link.trim() || null } })} placeholder="https://..." />
          <Button variant="outline" size="icon" aria-label="Copiar link" disabled={!link} onClick={async () => { await navigator.clipboard.writeText(link); toast('ok', 'Link copiado.') }}><Copy className="h-4 w-4" /></Button>
        </div>
      </Field>
      <Button variant="outline" disabled={!link || !order.conversation_id || send.isPending} onClick={() => send.mutate()}>
        <Send className="h-4 w-4" /> {send.isPending ? 'Enviando…' : 'Reenviar link ao cliente'}
      </Button>

      <Modal open={confirm} onOpenChange={setConfirm} title="Confirmar pagamento manualmente?" description="Use só se você já recebeu o valor. Fica registrado no histórico.">
        <div className="flex justify-end gap-2">
          <Button variant="outline" onClick={() => setConfirm(false)}>Cancelar</Button>
          <Button onClick={() => { confirmar.mutate(order.id, { onError: (e) => toast('error', e.message) }); setConfirm(false) }}>Sim, já recebi</Button>
        </div>
      </Modal>
    </div>
  )
}

/* ---------- Arte e prova ---------- */
const CHECKLIST = [
  ['alta_resolucao', 'Arquivo em alta resolução (300 dpi)'],
  ['medidas', 'Medidas e sangria conferidas'],
  ['cores', 'Cores e modo CMYK conferidos'],
  ['textos', 'Textos revisados e aprovados pelo cliente'],
  ['acabamento', 'Quantidade, papel e acabamento conferidos'],
] as const

function ArtTab({ order }: { order: OrderCard }) {
  const toast = useToast()
  const update = useUpdateOrder()
  const invalidate = useInvalidateOrders()
  const { data: files } = useOrderFiles(order.id)
  const input = useRef<HTMLInputElement>(null)
  const [kind, setKind] = useState<'arte' | 'prova'>('arte')

  const upload = useMutation({
    mutationFn: async (file: File) => {
      const safe = file.name.replace(/[^\w.-]+/g, '_')
      const path = `${order.id}/${Date.now()}-${safe}`
      const { error: upErr } = await supabase.storage.from('order-files').upload(path, file, { contentType: file.type || undefined })
      if (upErr) throw new Error(upErr.message)
      const version = (files ?? []).filter((f) => f.kind === kind).length + 1
      const { error } = await supabase.from('order_files').insert({ order_id: order.id, kind, version, path, filename: file.name, status: kind === 'prova' ? 'enviada' : null })
      if (error) throw new Error(error.message)
    },
    onSuccess: () => toast('ok', 'Arquivo enviado.'),
    onError: (e: Error) => toast('error', e.message),
    onSettled: () => invalidate(order.id),
  })

  async function openFile(path: string) {
    const { data, error } = await supabase.storage.from('order-files').createSignedUrl(path, 300)
    if (error || !data) return toast('error', 'Não foi possível abrir o arquivo.')
    window.open(data.signedUrl, '_blank', 'noopener')
  }

  const setFileStatus = useMutation({
    mutationFn: async ({ id, status }: { id: string; status: 'enviada' | 'aprovada' | 'ajuste' }) => {
      const { error } = await supabase.from('order_files').update({ status }).eq('id', id)
      if (error) throw new Error(error.message)
    },
    onSettled: () => invalidate(order.id),
  })

  const checked = order.art_checklist ?? {}
  const allChecked = CHECKLIST.every(([k]) => checked[k])
  const ready = allChecked && order.art_status === 'aprovada'

  return (
    <div className="space-y-5">
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="Quem faz a arte">
          <Select value={order.art_mode ?? ''} onChange={(e) => update.mutate({ id: order.id, patch: { art_mode: (e.target.value || null) as OrderCard['art_mode'] } })}>
            <option value="">Não definido</option>
            <option value="cliente">Cliente envia a arte</option>
            <option value="criamos">Nós criamos a arte</option>
          </Select>
        </Field>
        <Field label="Status da arte">
          <Select value={order.art_status} onChange={(e) => update.mutate({ id: order.id, patch: { art_status: e.target.value as ArtStatus } })}>
            {(Object.keys(ART_LABELS) as ArtStatus[]).map((s) => <option key={s} value={s}>{ART_LABELS[s]}</option>)}
          </Select>
        </Field>
      </div>

      <div className="rounded-md border p-3">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <div>
            <p className="text-sm font-bold">Aprovação do cliente</p>
            <p className="text-xs text-muted-foreground">{order.art_approved_at ? `Aprovada em ${dt(order.art_approved_at)}` : 'Ainda não aprovada'}</p>
          </div>
          <Button size="sm" disabled={order.art_status === 'aprovada'} onClick={() => update.mutate({ id: order.id, patch: { art_status: 'aprovada' } }, { onSuccess: () => toast('ok', 'Aprovação registrada.') })}>
            <Check className="h-4 w-4" /> Registrar aprovação
          </Button>
        </div>
      </div>

      <section>
        <div className="mb-2 flex flex-wrap items-center justify-between gap-2">
          <h3 className="text-sm font-bold">Arquivos e versões da prova</h3>
          <div className="flex items-center gap-2">
            <Select aria-label="Tipo de arquivo" className="w-32" value={kind} onChange={(e) => setKind(e.target.value as 'arte' | 'prova')}>
              <option value="arte">Arte</option>
              <option value="prova">Prova</option>
            </Select>
            <input ref={input} type="file" className="sr-only" aria-label="Escolher arquivo" onChange={(e) => { const f = e.target.files?.[0]; if (f) upload.mutate(f); e.target.value = '' }} />
            <Button size="sm" variant="outline" onClick={() => input.current?.click()} disabled={upload.isPending}><FileUp className="h-4 w-4" /> {upload.isPending ? 'Enviando…' : 'Enviar'}</Button>
          </div>
        </div>
        <ul className="space-y-2">
          {(files ?? []).map((f) => (
            <li key={f.id} className="flex flex-wrap items-center justify-between gap-2 rounded-md border p-2.5 text-sm">
              <button onClick={() => openFile(f.path)} className="min-w-0 truncate text-left font-semibold text-link underline">
                {f.kind === 'prova' ? `Prova v${f.version}` : `Arte v${f.version}`} · {f.filename}
              </button>
              <span className="flex items-center gap-2">
                <span className="text-xs text-muted-foreground">{dt(f.created_at)}</span>
                {f.kind === 'prova' && (
                  <Select aria-label="Status da prova" className="h-9 w-40 md:h-8" value={f.status ?? 'enviada'} onChange={(e) => setFileStatus.mutate({ id: f.id, status: e.target.value as 'enviada' | 'aprovada' | 'ajuste' })}>
                    <option value="enviada">Enviada ao cliente</option>
                    <option value="aprovada">Aprovada</option>
                    <option value="ajuste">Ajuste solicitado</option>
                  </Select>
                )}
              </span>
            </li>
          ))}
          {(files ?? []).length === 0 && <li className="rounded-md border border-dashed p-4 text-center text-sm text-muted-foreground">Nenhum arquivo enviado ainda.</li>}
        </ul>
      </section>

      <fieldset className="rounded-md border p-3">
        <legend className="px-1 text-xs font-bold uppercase tracking-wide">Conferência antes de enviar ao fornecedor</legend>
        <ul className="space-y-1">
          {CHECKLIST.map(([k, label]) => (
            <li key={k}>
              <label className="flex min-h-11 cursor-pointer items-center gap-2 text-sm md:min-h-8">
                <input type="checkbox" className="h-5 w-5 accent-[var(--brand-blue)] md:h-4 md:w-4" checked={!!checked[k]} onChange={(e) => update.mutate({ id: order.id, patch: { art_checklist: { ...checked, [k]: e.target.checked } } })} />
                {label}
              </label>
            </li>
          ))}
        </ul>
        <p className={cn('mt-2 text-sm font-semibold', ready ? 'text-brand-green' : 'text-muted-foreground')}>
          {ready ? 'Tudo conferido. Pode enviar ao fornecedor.' : 'Complete a conferência e a aprovação da arte para liberar o envio ao fornecedor.'}
        </p>
      </fieldset>
    </div>
  )
}

/* ---------- Entrega ---------- */
function DeliveryTab({ order }: { order: OrderCard }) {
  const toast = useToast()
  const update = useUpdateOrder()
  const [f, setF] = useState({
    supplier: order.supplier_order_no ?? '',
    due: order.due_date ?? '',
    method: order.delivery_method ?? '',
    address: order.delivery_address ?? '',
    fee: order.delivery_fee != null ? String(order.delivery_fee) : '',
    tracking: order.delivery_tracking ?? '',
  })
  return (
    <form
      className="space-y-4"
      onSubmit={(e) => {
        e.preventDefault()
        update.mutate(
          {
            id: order.id,
            patch: {
              supplier_order_no: f.supplier.trim() || null,
              due_date: f.due || null,
              due_date_manual: !!f.due && f.due !== (order.due_date ?? '') ? true : f.due ? order.due_date_manual : false,
              delivery_method: (f.method || null) as OrderCard['delivery_method'],
              delivery_address: f.address.trim() || null,
              delivery_fee: f.fee ? parseMoney(f.fee) : null,
              delivery_tracking: f.tracking.trim() || null,
            },
          },
          { onSuccess: () => toast('ok', 'Entrega salva.'), onError: (err) => toast('error', err.message) },
        )
      }}
    >
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="Nº do pedido no fornecedor"><Input value={f.supplier} onChange={(e) => setF({ ...f, supplier: e.target.value })} /></Field>
        <Field label="Prazo previsto">
          <Input type="date" value={f.due} onChange={(e) => setF({ ...f, due: e.target.value })} />
          <p className="mt-1 text-xs text-muted-foreground">
            {order.due_date_manual
              ? 'Data ajustada à mão. Apague o campo e salve para voltar ao cálculo automático.'
              : order.lead_days != null
                ? `Automático: ${order.lead_days} dia(s) úteis do fornecedor a partir do pagamento confirmado, mais a margem, sem fins de semana e feriados.`
                : 'Calculado sozinho quando o pagamento for confirmado e algum item tiver prazo.'}
          </p>
        </Field>
        <Field label="Forma de entrega">
          <Select value={f.method} onChange={(e) => setF({ ...f, method: e.target.value })}>
            <option value="">Não definida</option>
            <option value="retirada">Retirada no escritório (Praça Sete)</option>
            <option value="uber">Uber Entrega (frete por conta do cliente)</option>
          </Select>
        </Field>
        <Field label="Frete pago pelo cliente (R$)"><Input inputMode="decimal" value={f.fee} onChange={(e) => setF({ ...f, fee: e.target.value })} disabled={f.method !== 'uber'} /></Field>
      </div>
      {f.method === 'uber' && <Field label="Endereço de entrega"><Textarea rows={2} value={f.address} onChange={(e) => setF({ ...f, address: e.target.value })} /></Field>}
      <Field label="Código ou link de rastreio"><Input value={f.tracking} onChange={(e) => setF({ ...f, tracking: e.target.value })} placeholder="https://..." /></Field>
      <p className="text-sm text-muted-foreground">Entregue em: <strong>{dt(order.delivered_at)}</strong> (preenchido ao mover o pedido para Entregue)</p>
      <Button type="submit" disabled={update.isPending}>{update.isPending ? 'Salvando…' : 'Salvar entrega'}</Button>
    </form>
  )
}

/* ---------- Histórico ---------- */
function HistoryTab({ order }: { order: OrderCard }) {
  const { data: events, isLoading } = useOrderEvents(order.id)
  const KIND: Record<string, string> = { create: 'Criação', stage: 'Etapa', payment: 'Pagamento', note: 'Nota', price: 'Preço', art: 'Arte', delivery: 'Entrega' }
  if (isLoading) return <Skeleton className="h-32 w-full" />
  return (
    <ol className="relative space-y-4 border-l-2 border-brand-cyan/50 pl-4">
      {(events ?? []).map((e) => (
        <li key={e.id} className="relative">
          <span className="absolute -left-[22px] top-1 h-3 w-3 rounded-full border-2 border-background bg-brand-cyan" aria-hidden />
          <p className="text-xs text-muted-foreground tabular">{dt(e.created_at)} · {KIND[e.kind] ?? e.kind}</p>
          <p className="text-sm">
            {e.kind === 'stage' && e.to_stage ? `${e.from_stage ? stageInfo(e.from_stage).label : '—'} → ${stageInfo(e.to_stage).label}` : e.message}
          </p>
        </li>
      ))}
      {(events ?? []).length === 0 && <li className="text-sm text-muted-foreground">Sem eventos.</li>}
    </ol>
  )
}

/* ---------- Gaveta ---------- */
export default function OrderDrawer({ orderId, onClose }: { orderId: string; onClose: () => void }) {
  const { data: orders } = useOrders()
  const qc = useQueryClient()
  const order = useMemo(() => orders?.find((o) => o.id === orderId), [orders, orderId])
  useEffect(() => {
    qc.invalidateQueries({ queryKey: ['order-events', orderId] })
  }, [orderId, qc])

  return (
    <Sheet
      open
      onOpenChange={(o) => !o && onClose()}
      title={order ? `Pedido #${order.number} · ${contactLabel(order.contact)}` : 'Pedido'}
      description={order ? `${formatBRL(order.fin.total)} · lucro líquido ${formatBRL(order.fin.net_profit)}` : undefined}
    >
      {!order ? (
        <div className="space-y-3 p-4"><Skeleton className="h-8 w-1/2" /><Skeleton className="h-48 w-full" /></div>
      ) : (
        <Tabs defaultValue="resumo" className="flex min-h-0 flex-1 flex-col">
          <TabsList>
            <TabsTrigger value="resumo">Resumo</TabsTrigger>
            <TabsTrigger value="itens">Itens</TabsTrigger>
            <TabsTrigger value="pagamento">Pagamento</TabsTrigger>
            <TabsTrigger value="arte">Arte e prova</TabsTrigger>
            <TabsTrigger value="entrega">Entrega</TabsTrigger>
            <TabsTrigger value="historico">Histórico</TabsTrigger>
          </TabsList>
          <TabsContent value="resumo"><SummaryTab key={order.id} order={order} /></TabsContent>
          <TabsContent value="itens"><ItemsTab key={order.id} order={order} /></TabsContent>
          <TabsContent value="pagamento"><PaymentTab key={order.id} order={order} /></TabsContent>
          <TabsContent value="arte"><ArtTab key={order.id} order={order} /></TabsContent>
          <TabsContent value="entrega"><DeliveryTab key={order.id} order={order} /></TabsContent>
          <TabsContent value="historico"><HistoryTab order={order} /></TabsContent>
        </Tabs>
      )}
    </Sheet>
  )
}
