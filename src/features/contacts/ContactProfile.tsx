import { useMutation, useQueryClient } from '@tanstack/react-query'
import { X } from 'lucide-react'
import { useState, type KeyboardEvent } from 'react'
import { Link } from 'react-router-dom'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { Textarea } from '@/components/ui/textarea'
import { useToast } from '@/components/ui/toast'
import { useOrders } from '@/hooks/orders'
import { useContactStats } from '@/hooks/crm'
import { useSetting } from '@/hooks/settings'
import { CONSENTS, CONSENT_SOURCES, contactLabel, formatPhone } from '@/lib/format'
import { formatBRL } from '@/lib/money'
import { stageInfo } from '@/lib/orders'
import { supabase } from '@/lib/supabase'
import type { ConsentSource, Contact, MarketingConsent } from '@/lib/types'
import { cn } from '@/lib/utils'

const SEGMENTS = [
  { value: 'barbearia', label: 'Barbearia' },
  { value: 'delivery', label: 'Delivery' },
  { value: 'loja', label: 'Loja' },
  { value: 'outro', label: 'Outro' },
] as const

export function daysSince(iso: string | null | undefined, now = Date.now()): number | null {
  return iso ? Math.floor((now - new Date(iso).getTime()) / 86_400_000) : null
}

/** "Cliente recorrente" (2+ compras) ou "lead frio" (sem compra e sem contato há 14+ dias). */
export function contactTag(stats: { paid_orders: number } | undefined, lastContactAt: string | null | undefined): 'recorrente' | 'frio' | null {
  if ((stats?.paid_orders ?? 0) >= 2) return 'recorrente'
  if ((stats?.paid_orders ?? 0) === 0 && (daysSince(lastContactAt) ?? 0) >= 14) return 'frio'
  return null
}

export function ContactProfile({ contact, lastContactAt }: { contact: Contact; lastContactAt?: string | null }) {
  const qc = useQueryClient()
  const toast = useToast()
  const { data: stats } = useContactStats()
  const { data: orders } = useOrders()
  const { data: repurchase } = useSetting('repurchase')
  const s = stats?.get(contact.id)
  const mine = (orders ?? []).filter((o) => o.contact_id === contact.id)

  const [f, setF] = useState({
    name: contact.name ?? '',
    email: contact.email ?? '',
    document: contact.document ?? '',
    company: contact.company ?? '',
    segment: contact.segment ?? '',
    address: contact.address ?? '',
    notes: contact.notes ?? '',
  })
  const [tags, setTags] = useState<string[]>(contact.tags)
  const [tagInput, setTagInput] = useState('')
  const [consent, setConsent] = useState<MarketingConsent>(contact.marketing_consent)
  const [source, setSource] = useState<ConsentSource>(contact.marketing_consent_source ?? 'manual')

  const refresh = () => {
    qc.invalidateQueries({ queryKey: ['conversations'] })
    qc.invalidateQueries({ queryKey: ['contacts'] })
    qc.invalidateQueries({ queryKey: ['contact-stats'] })
  }

  const save = useMutation({
    mutationFn: async () => {
      const { error } = await supabase
        .from('contacts')
        .update({
          name: f.name.trim() || null,
          email: f.email.trim() || null,
          document: f.document.trim() || null,
          company: f.company.trim() || null,
          segment: f.segment || null,
          address: f.address.trim() || null,
          notes: f.notes.trim() || null,
          tags,
        })
        .eq('id', contact.id)
      if (error) throw new Error(error.message)
    },
    onSuccess: () => {
      toast('ok', 'Contato salvo.')
      refresh()
    },
    onError: (e: Error) => toast('error', e.message),
  })

  const consentChanged = consent !== contact.marketing_consent || (consent === 'opted_in' && source !== contact.marketing_consent_source)
  const saveConsent = useMutation({
    mutationFn: async () => {
      const { error } = await supabase
        .from('contacts')
        .update({
          marketing_consent: consent,
          marketing_consent_at: consent === 'none' ? null : new Date().toISOString(),
          marketing_consent_source: consent === 'opted_in' ? source : consent === 'opted_out' ? 'manual' : null,
        })
        .eq('id', contact.id)
      if (error) throw new Error(error.message)
    },
    onSuccess: () => {
      toast('ok', 'Consentimento salvo.')
      refresh()
    },
    onError: (e: Error) => toast('error', e.message),
  })

  function addTag() {
    const t = tagInput.trim().toLowerCase()
    if (t && !tags.includes(t)) setTags([...tags, t])
    setTagInput('')
  }
  function onTagKey(e: KeyboardEvent<HTMLInputElement>) {
    if (e.key === 'Enter' || e.key === ',') {
      e.preventDefault()
      addTag()
    }
  }

  const tag = contactTag(s, lastContactAt)
  const sinceOrder = daysSince(s?.last_order_at)
  const ref = contact.first_referral
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value })

  return (
    <div className="space-y-5">
      <div>
        <div className="flex flex-wrap items-center gap-2">
          <p className="text-base font-black">{contactLabel(contact)}</p>
          {tag === 'recorrente' && <Badge className="bg-brand-green/10 text-brand-green">Cliente recorrente</Badge>}
          {tag === 'frio' && <Badge className="bg-brand-blue/10 text-brand-blue">Lead frio</Badge>}
        </div>
        <p className="text-xs text-muted-foreground">{formatPhone(contact.wa_id)}</p>
      </div>

      <dl className="grid grid-cols-2 gap-3 rounded-md border p-3 text-sm">
        <div><dt className="text-[11px] uppercase tracking-wide text-muted-foreground">Pedidos</dt><dd className="font-black tabular">{s?.orders_count ?? 0}</dd></div>
        <div><dt className="text-[11px] uppercase tracking-wide text-muted-foreground">Valor gasto (LTV)</dt><dd className="font-black tabular">{formatBRL(s?.ltv ?? 0)}</dd></div>
        <div><dt className="text-[11px] uppercase tracking-wide text-muted-foreground">Lucro gerado</dt><dd className="font-black tabular">{formatBRL(s?.profit ?? 0)}</dd></div>
        <div>
          <dt className="text-[11px] uppercase tracking-wide text-muted-foreground">Última compra</dt>
          <dd className="font-black tabular">{sinceOrder === null ? '—' : sinceOrder === 0 ? 'hoje' : `há ${sinceOrder} d`}</dd>
        </div>
      </dl>
      {sinceOrder !== null && sinceOrder >= (repurchase?.days ?? 45) && (
        <p className="rounded-md border border-brand-yellow bg-brand-yellow/20 p-2.5 text-sm">Última compra há {sinceOrder} dias. Boa hora para oferecer recompra.</p>
      )}

      <section className="rounded-md border p-3 text-sm">
        <h3 className="mb-1 text-xs font-bold uppercase tracking-wide">Origem</h3>
        {ref ? (
          <ul className="space-y-0.5">
            <li>Anúncio: <strong>{ref.headline || 'sem título'}</strong></li>
            {ref.source_id && <li className="text-xs text-muted-foreground">ID do anúncio {ref.source_id}</li>}
            {ref.media_type && <li className="text-xs text-muted-foreground">Mídia: {ref.media_type}</li>}
            {ref.source_url && <li><a className="text-xs font-semibold text-link underline" href={ref.source_url} target="_blank" rel="noreferrer">Ver anúncio</a></li>}
            {contact.first_referral_at && <li className="text-xs text-muted-foreground">Primeiro contato em {new Date(contact.first_referral_at).toLocaleDateString('pt-BR')}</li>}
          </ul>
        ) : (
          <p className="text-muted-foreground">Orgânico (sem anúncio de origem registrado).</p>
        )}
      </section>

      <div className="grid gap-3">
        <div className="space-y-1.5"><Label htmlFor="p-name">Nome</Label><Input id="p-name" value={f.name} onChange={set('name')} /></div>
        <div className="space-y-1.5"><Label htmlFor="p-company">Empresa</Label><Input id="p-company" value={f.company} onChange={set('company')} /></div>
        <div className="space-y-1.5">
          <Label htmlFor="p-seg">Segmento</Label>
          <Select id="p-seg" value={f.segment} onChange={set('segment')}>
            <option value="">Não informado</option>
            {SEGMENTS.map((x) => <option key={x.value} value={x.value}>{x.label}</option>)}
          </Select>
        </div>
        <div className="space-y-1.5"><Label htmlFor="p-email">E-mail</Label><Input id="p-email" type="email" value={f.email} onChange={set('email')} /></div>
        <div className="space-y-1.5"><Label htmlFor="p-doc">CPF ou CNPJ (opcional)</Label><Input id="p-doc" inputMode="numeric" value={f.document} onChange={set('document')} /></div>
        <div className="space-y-1.5"><Label htmlFor="p-addr">Endereço</Label><Textarea id="p-addr" rows={2} value={f.address} onChange={set('address')} /></div>
        <div className="space-y-1.5"><Label htmlFor="p-notes">Notas</Label><Textarea id="p-notes" rows={3} value={f.notes} onChange={set('notes')} placeholder="Ex.: prefere arte pronta, retira na loja" /></div>
        <div className="space-y-1.5">
          <Label htmlFor="p-tags">Etiquetas</Label>
          <div className="flex flex-wrap gap-1">
            {tags.map((t) => (
              <Badge key={t} className="gap-1 bg-secondary text-secondary-foreground">
                {t}
                <button aria-label={`Remover etiqueta ${t}`} onClick={() => setTags(tags.filter((x) => x !== t))}><X className="h-3 w-3" /></button>
              </Badge>
            ))}
          </div>
          <Input id="p-tags" value={tagInput} onChange={(e) => setTagInput(e.target.value)} onKeyDown={onTagKey} onBlur={addTag} placeholder="Digite e tecle Enter" />
        </div>
        <Button onClick={() => save.mutate()} disabled={save.isPending}>{save.isPending ? 'Salvando…' : 'Salvar contato'}</Button>
      </div>

      <section className="space-y-2 border-t pt-4">
        <Label htmlFor="c-consent">Consentimento para promoções</Label>
        <Select id="c-consent" value={consent} onChange={(e) => setConsent(e.target.value as MarketingConsent)}>
          {CONSENTS.map((c) => <option key={c.value} value={c.value}>{c.label}</option>)}
        </Select>
        {consent === 'opted_in' && (
          <>
            <Label htmlFor="c-consent-src">Como o cliente autorizou</Label>
            <Select id="c-consent-src" value={source} onChange={(e) => setSource(e.target.value as ConsentSource)}>
              {CONSENT_SOURCES.map((c) => <option key={c.value} value={c.value}>{c.label}</option>)}
            </Select>
          </>
        )}
        {contact.marketing_consent !== 'none' && contact.marketing_consent_at && (
          <p className="text-xs text-muted-foreground">
            Registrado em {new Date(contact.marketing_consent_at).toLocaleDateString('pt-BR')}
            {contact.marketing_consent_source && ` (${CONSENT_SOURCES.find((c) => c.value === contact.marketing_consent_source)?.label.toLowerCase()})`}
          </p>
        )}
        <p className="text-xs text-muted-foreground">Quando o cliente responde PARAR no WhatsApp, o sistema marca &quot;Pediu para não receber&quot; sozinho.</p>
        <Button size="sm" variant="outline" onClick={() => saveConsent.mutate()} disabled={!consentChanged || saveConsent.isPending}>
          {saveConsent.isPending ? 'Salvando…' : 'Salvar consentimento'}
        </Button>
      </section>

      <section className="border-t pt-4">
        <h3 className="mb-2 text-xs font-bold uppercase tracking-wide">Pedidos</h3>
        {mine.length === 0 ? (
          <p className="text-sm text-muted-foreground">Nenhum pedido ainda.</p>
        ) : (
          <ul className="space-y-1.5">
            {mine.map((o) => (
              <li key={o.id}>
                <Link to={`/kanban?pedido=${o.id}`} className="flex min-h-11 items-center justify-between gap-2 rounded-md border px-3 py-2 text-sm hover:bg-secondary md:min-h-9">
                  <span className="min-w-0 truncate"><strong>#{o.number}</strong> {o.title}</span>
                  <span className="flex shrink-0 items-center gap-2">
                    <span className="tabular font-semibold">{formatBRL(o.fin.total)}</span>
                    <Badge className={cn(stageInfo(o.stage).chip)}>{stageInfo(o.stage).label}</Badge>
                  </span>
                </Link>
              </li>
            ))}
          </ul>
        )}
      </section>
    </div>
  )
}
