import { useMutation, useQueryClient } from '@tanstack/react-query'
import { Download, Search, Users } from 'lucide-react'
import { useMemo, useState, type FormEvent } from 'react'
import { useNavigate } from 'react-router-dom'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { EmptyState, ErrorState } from '@/components/ui/empty-state'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { Sheet } from '@/components/ui/sheet'
import { Skeleton } from '@/components/ui/skeleton'
import { ContactProfile, contactTag, daysSince } from '@/features/contacts/ContactProfile'
import { useContactStats } from '@/hooks/crm'
import { CONSENTS, contactLabel, formatPhone } from '@/lib/format'
import { formatBRL } from '@/lib/money'
import { supabase } from '@/lib/supabase'
import type { MarketingConsent } from '@/lib/types'
import { useToast } from '@/components/ui/toast'
import { useContacts, useConversations } from '@/hooks/queries'
import { downloadCsv } from '@/lib/csv'

export default function Contacts() {
  const { data: contacts, isLoading, error, refetch } = useContacts()
  const { data: convs } = useConversations()
  const { data: stats } = useContactStats()
  const qc = useQueryClient()
  const navigate = useNavigate()
  const toast = useToast()
  const [search, setSearch] = useState('')
  const [tag, setTag] = useState('')
  const [consent, setConsent] = useState<MarketingConsent | ''>('')
  const [origin, setOrigin] = useState('')
  const [segment, setSegment] = useState('')
  const [kind, setKind] = useState<'' | 'recorrente' | 'frio'>('')
  const [openId, setOpenId] = useState<string | null>(null)
  const [newName, setNewName] = useState('')
  const [newPhone, setNewPhone] = useState('')
  const [formError, setFormError] = useState<string | null>(null)

  const lastContact = useMemo(() => new Map((convs ?? []).map((c) => [c.contact_id, c.last_message_at])), [convs])
  const allTags = useMemo(() => [...new Set((contacts ?? []).flatMap((c) => c.tags))].sort(), [contacts])
  const origins = useMemo(() => [...new Set((contacts ?? []).map((c) => c.first_referral?.headline).filter(Boolean) as string[])].sort(), [contacts])

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase()
    const digits = q.replace(/\D/g, '')
    return (contacts ?? []).filter((c) => {
      if (tag && !c.tags.includes(tag)) return false
      if (consent && c.marketing_consent !== consent) return false
      if (segment && c.segment !== segment) return false
      if (origin === '__organico' ? !!c.first_referral : origin ? c.first_referral?.headline !== origin : false) return false
      if (kind && contactTag(stats?.get(c.id), lastContact.get(c.id)) !== kind) return false
      if (!q) return true
      return (c.name ?? '').toLowerCase().includes(q) || (c.company ?? '').toLowerCase().includes(q) || !!(digits && c.wa_id.includes(digits))
    })
  }, [contacts, search, tag, consent, segment, origin, kind, stats, lastContact])

  const openChat = useMutation({
    mutationFn: async (contactId: string) => {
      const { data: existing, error } = await supabase.from('conversations').select('id').eq('contact_id', contactId).maybeSingle()
      if (error) throw error
      if (existing) return existing.id as string
      const { data, error: insErr } = await supabase.from('conversations').insert({ contact_id: contactId }).select('id').single()
      if (insErr) throw insErr
      return data.id as string
    },
    onSuccess: (id) => {
      qc.invalidateQueries({ queryKey: ['conversations'] })
      navigate(`/inbox/${id}`)
    },
    onError: () => toast('error', 'Não foi possível abrir a conversa.'),
  })

  const create = useMutation({
    mutationFn: async () => {
      const wa_id = newPhone.replace(/\D/g, '')
      if (wa_id.length < 10) throw new Error('Informe o telefone com DDD (e DDI 55, se for do Brasil).')
      const { error } = await supabase.from('contacts').insert({ wa_id: wa_id.length <= 11 ? `55${wa_id}` : wa_id, name: newName.trim() || null })
      if (error) throw new Error(error.code === '23505' ? 'Já existe um contato com esse telefone.' : 'Não foi possível criar o contato.')
    },
    onSuccess: () => {
      setNewName('')
      setNewPhone('')
      setFormError(null)
      toast('ok', 'Contato criado.')
      qc.invalidateQueries({ queryKey: ['contacts'] })
    },
    onError: (e: Error) => setFormError(e.message),
  })

  function onSubmit(e: FormEvent) {
    e.preventDefault()
    create.mutate()
  }

  function exportCsv() {
    downloadCsv(
      'contatos.csv',
      ['Nome', 'Telefone', 'Empresa', 'Segmento', 'E-mail', 'Origem', 'Consentimento', 'Etiquetas', 'Pedidos', 'Valor gasto'],
      filtered.map((c) => [
        c.name ?? '',
        c.wa_id,
        c.company ?? '',
        c.segment ?? '',
        c.email ?? '',
        c.first_referral?.headline ?? 'Orgânico',
        CONSENTS.find((x) => x.value === c.marketing_consent)?.label ?? '',
        c.tags.join('; '),
        stats?.get(c.id)?.orders_count ?? 0,
        stats?.get(c.id)?.ltv ?? 0,
      ]),
    )
  }

  const open = (contacts ?? []).find((c) => c.id === openId)

  return (
    <div className="flex h-full flex-col">
      <header className="space-y-3 border-b px-4 py-3">
        <div className="flex items-center justify-between gap-2">
          <h1 className="text-xl font-black">Contatos</h1>
          <Button variant="outline" size="sm" onClick={exportCsv} disabled={!filtered.length}>
            <Download className="h-4 w-4" /> Exportar CSV
          </Button>
        </div>
        <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-6">
          <div className="relative lg:col-span-2">
            <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" aria-hidden />
            <Input className="pl-9" placeholder="Buscar por nome, empresa ou telefone" aria-label="Buscar contato" value={search} onChange={(e) => setSearch(e.target.value)} />
          </div>
          <Select aria-label="Origem" value={origin} onChange={(e) => setOrigin(e.target.value)}>
            <option value="">Todas as origens</option>
            <option value="__organico">Orgânico</option>
            {origins.map((o) => <option key={o} value={o}>Anúncio: {o}</option>)}
          </Select>
          <Select aria-label="Segmento" value={segment} onChange={(e) => setSegment(e.target.value)}>
            <option value="">Todos os segmentos</option>
            <option value="barbearia">Barbearia</option>
            <option value="delivery">Delivery</option>
            <option value="loja">Loja</option>
            <option value="outro">Outro</option>
          </Select>
          <Select aria-label="Tipo de cliente" value={kind} onChange={(e) => setKind(e.target.value as '' | 'recorrente' | 'frio')}>
            <option value="">Todos os perfis</option>
            <option value="recorrente">Clientes recorrentes</option>
            <option value="frio">Leads frios</option>
          </Select>
          <Select aria-label="Consentimento" value={consent} onChange={(e) => setConsent(e.target.value as MarketingConsent | '')}>
            <option value="">Todos os consentimentos</option>
            {CONSENTS.map((c) => <option key={c.value} value={c.value}>{c.label}</option>)}
          </Select>
          <Select aria-label="Etiqueta" value={tag} onChange={(e) => setTag(e.target.value)}>
            <option value="">Todas as etiquetas</option>
            {allTags.map((t) => <option key={t} value={t}>{t}</option>)}
          </Select>
        </div>
        <form onSubmit={onSubmit} className="flex flex-wrap items-end gap-2">
          <div className="space-y-1"><Label htmlFor="n-name">Novo contato: nome</Label><Input id="n-name" className="w-48" value={newName} onChange={(e) => setNewName(e.target.value)} /></div>
          <div className="space-y-1"><Label htmlFor="n-phone">Telefone</Label><Input id="n-phone" className="w-48" inputMode="tel" placeholder="(31) 99999-0000" value={newPhone} onChange={(e) => setNewPhone(e.target.value)} /></div>
          <Button type="submit" variant="outline" disabled={create.isPending}>Adicionar</Button>
          {formError && <p role="alert" className="text-sm text-destructive">{formError}</p>}
        </form>
      </header>

      <div className="min-h-0 flex-1 overflow-y-auto">
        {error && <ErrorState message="Não foi possível carregar os contatos." onRetry={() => refetch()} />}
        {isLoading && <div className="space-y-2 p-4">{[0, 1, 2, 3].map((i) => <Skeleton key={i} className="h-14 w-full" />)}</div>}
        {!isLoading && !error && !filtered.length && (
          <EmptyState icon={Users} title={contacts?.length ? 'Nenhum contato com esses filtros' : 'Nenhum contato ainda'}>
            {contacts?.length ? 'Limpe algum filtro para ver mais contatos.' : 'Os contatos aparecem sozinhos quando alguém escreve no WhatsApp. Você também pode adicionar um acima.'}
          </EmptyState>
        )}
        <ul className="divide-y">
          {filtered.map((c) => {
            const s = stats?.get(c.id)
            const k = contactTag(s, lastContact.get(c.id))
            const d = daysSince(s?.last_order_at)
            return (
              <li key={c.id} className="flex flex-wrap items-center justify-between gap-3 px-4 py-3">
                <button onClick={() => setOpenId(c.id)} className="min-w-0 flex-1 text-left">
                  <p className="flex flex-wrap items-center gap-1.5 text-sm font-bold">
                    <span className="truncate">{contactLabel(c)}</span>
                    {k === 'recorrente' && <Badge className="bg-brand-green/10 text-brand-green">Recorrente</Badge>}
                    {k === 'frio' && <Badge className="bg-brand-blue/10 text-brand-blue">Lead frio</Badge>}
                    {c.marketing_consent === 'opted_in' && <Badge className="bg-brand-green/10 text-brand-green">Aceita promoções</Badge>}
                    {c.marketing_consent === 'opted_out' && <Badge className="bg-brand-red/10 text-brand-red">Não quer promoções</Badge>}
                  </p>
                  <p className="text-xs text-muted-foreground">
                    {formatPhone(c.wa_id)}
                    {c.company ? ` · ${c.company}` : ''}
                    {c.first_referral?.headline ? ` · Anúncio: ${c.first_referral.headline}` : ' · Orgânico'}
                  </p>
                  {(s?.orders_count ?? 0) > 0 && (
                    <p className="text-xs tabular">
                      {s!.orders_count} pedido(s) · {formatBRL(s!.ltv)} gasto{d !== null ? ` · última compra há ${d} d` : ''}
                    </p>
                  )}
                </button>
                <Button size="sm" variant="outline" disabled={openChat.isPending} onClick={() => openChat.mutate(c.id)}>
                  Abrir conversa
                </Button>
              </li>
            )
          })}
        </ul>
      </div>

      {open && (
        <Sheet open onOpenChange={(o) => !o && setOpenId(null)} title={contactLabel(open)} description="Perfil do contato">
          <div className="min-h-0 flex-1 overflow-y-auto p-4">
            <ContactProfile key={open.id} contact={open} lastContactAt={lastContact.get(open.id)} />
          </div>
        </Sheet>
      )}
    </div>
  )
}
