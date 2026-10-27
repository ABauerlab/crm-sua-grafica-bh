import { useMutation, useQueryClient } from '@tanstack/react-query'
import { Search } from 'lucide-react'
import { useMemo, useState, type FormEvent } from 'react'
import { useNavigate } from 'react-router-dom'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { useContacts } from '@/hooks/queries'
import { CONSENTS, contactLabel, formatPhone } from '@/lib/format'
import { supabase } from '@/lib/supabase'
import type { MarketingConsent } from '@/lib/types'

export default function Contacts() {
  const { data: contacts, isLoading, error } = useContacts()
  const qc = useQueryClient()
  const navigate = useNavigate()
  const [search, setSearch] = useState('')
  const [tag, setTag] = useState('')
  const [consent, setConsent] = useState<MarketingConsent | ''>('')
  const [newName, setNewName] = useState('')
  const [newPhone, setNewPhone] = useState('')
  const [formError, setFormError] = useState<string | null>(null)

  const allTags = useMemo(() => [...new Set((contacts ?? []).flatMap((c) => c.tags))].sort(), [contacts])
  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase()
    const digits = q.replace(/\D/g, '')
    return (contacts ?? []).filter(
      (c) =>
        (!tag || c.tags.includes(tag)) &&
        (!consent || c.marketing_consent === consent) &&
        (!q || (c.name ?? '').toLowerCase().includes(q) || (digits && c.wa_id.includes(digits))),
    )
  }, [contacts, search, tag, consent])

  // Abre (criando se preciso) a conversa do contato
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
      qc.invalidateQueries({ queryKey: ['contacts'] })
    },
    onError: (e: Error) => setFormError(e.message),
  })

  function onSubmit(e: FormEvent) {
    e.preventDefault()
    create.mutate()
  }

  return (
    <div className="flex h-full flex-col">
      <header className="space-y-3 border-b px-4 py-3">
        <h1 className="text-lg font-semibold">Contatos</h1>
        <div className="flex flex-wrap gap-2">
          <div className="relative min-w-52 flex-1">
            <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
            <Input className="pl-8" placeholder="Buscar por nome ou telefone" aria-label="Buscar contato" value={search} onChange={(e) => setSearch(e.target.value)} />
          </div>
          <Select className="w-44" aria-label="Filtrar por tag" value={tag} onChange={(e) => setTag(e.target.value)}>
            <option value="">Todas as tags</option>
            {allTags.map((t) => (
              <option key={t} value={t}>
                {t}
              </option>
            ))}
          </Select>
          <Select className="w-56" aria-label="Filtrar por consentimento" value={consent} onChange={(e) => setConsent(e.target.value as MarketingConsent | '')}>
            <option value="">Todos os consentimentos</option>
            {CONSENTS.map((c) => (
              <option key={c.value} value={c.value}>
                {c.label}
              </option>
            ))}
          </Select>
        </div>
        <form onSubmit={onSubmit} className="flex flex-wrap items-end gap-2">
          <div className="space-y-1">
            <Label htmlFor="n-name">Novo contato — nome</Label>
            <Input id="n-name" className="w-48" value={newName} onChange={(e) => setNewName(e.target.value)} />
          </div>
          <div className="space-y-1">
            <Label htmlFor="n-phone">Telefone</Label>
            <Input id="n-phone" className="w-48" inputMode="tel" placeholder="(31) 99999-0000" value={newPhone} onChange={(e) => setNewPhone(e.target.value)} />
          </div>
          <Button type="submit" variant="outline" disabled={create.isPending}>
            Adicionar
          </Button>
          {formError && <p role="alert" className="text-sm text-destructive">{formError}</p>}
        </form>
      </header>

      <div className="min-h-0 flex-1 overflow-y-auto">
        {isLoading && <p className="p-4 text-sm text-muted-foreground">Carregando…</p>}
        {error && <p className="p-4 text-sm text-destructive">Erro ao carregar contatos.</p>}
        {!isLoading && !filtered.length && <p className="p-4 text-sm text-muted-foreground">Nenhum contato encontrado.</p>}
        <ul className="divide-y">
          {filtered.map((c) => (
            <li key={c.id} className="flex items-center justify-between gap-3 px-4 py-3">
              <div className="min-w-0">
                <p className="truncate text-sm font-medium">{contactLabel(c)}</p>
                <p className="text-xs text-muted-foreground">{formatPhone(c.wa_id)}</p>
                {c.marketing_consent !== 'none' && (
                  <Badge className={c.marketing_consent === 'opted_in' ? 'mt-1 bg-emerald-100 text-emerald-800' : 'mt-1 bg-rose-100 text-rose-800'}>
                    {c.marketing_consent === 'opted_in' ? 'Aceita promoções' : 'Não quer promoções'}
                  </Badge>
                )}
                {c.tags.length > 0 && (
                  <div className="mt-1 flex flex-wrap gap-1">
                    {c.tags.map((t) => (
                      <Badge key={t} className="bg-secondary text-secondary-foreground">
                        {t}
                      </Badge>
                    ))}
                  </div>
                )}
              </div>
              <Button size="sm" variant="outline" disabled={openChat.isPending} onClick={() => openChat.mutate(c.id)}>
                Abrir conversa
              </Button>
            </li>
          ))}
        </ul>
      </div>
    </div>
  )
}
