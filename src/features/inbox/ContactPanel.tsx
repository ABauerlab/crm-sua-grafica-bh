import { useMutation, useQueryClient } from '@tanstack/react-query'
import { X } from 'lucide-react'
import { useState, type KeyboardEvent } from 'react'
import { useNavigate } from 'react-router-dom'
import { useAuth } from '@/auth/AuthProvider'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { Switch } from '@/components/ui/switch'
import { Textarea } from '@/components/ui/textarea'
import { useProfiles } from '@/hooks/queries'
import { CONSENTS, CONSENT_SOURCES, STAGES, STATUSES, formatPhone } from '@/lib/format'
import { supabase } from '@/lib/supabase'
import type { ConsentSource, ConversationStatus, ConversationWithContact, MarketingConsent, Stage } from '@/lib/types'

export function ContactPanel({ conversation }: { conversation: ConversationWithContact }) {
  const qc = useQueryClient()
  const navigate = useNavigate()
  const { profile } = useAuth()
  const { data: profiles } = useProfiles()
  const { contact } = conversation

  const [name, setName] = useState(contact.name ?? '')
  const [notes, setNotes] = useState(contact.notes ?? '')
  const [tags, setTags] = useState<string[]>(contact.tags)
  const [tagInput, setTagInput] = useState('')
  const [saved, setSaved] = useState(false)
  const [consent, setConsent] = useState<MarketingConsent>(contact.marketing_consent)
  const [consentSource, setConsentSource] = useState<ConsentSource>(contact.marketing_consent_source ?? 'manual')

  const refresh = () => qc.invalidateQueries({ queryKey: ['conversations'] })

  const saveContact = useMutation({
    mutationFn: async () => {
      const { error } = await supabase
        .from('contacts')
        .update({ name: name.trim() || null, notes: notes.trim() || null, tags })
        .eq('id', contact.id)
      if (error) throw error
    },
    onSuccess: () => {
      setSaved(true)
      refresh()
      qc.invalidateQueries({ queryKey: ['contacts'] })
    },
  })

  const deleteContact = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.from('contacts').delete().eq('id', contact.id)
      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['conversations'] })
      qc.invalidateQueries({ queryKey: ['contacts'] })
      navigate('/inbox')
    },
  })

  function onDelete() {
    const who = contact.name || formatPhone(contact.wa_id)
    if (window.confirm(`Excluir ${who} e todas as conversas dele? Isso não pode ser desfeito.`)) deleteContact.mutate()
  }

  const consentChanged = consent !== contact.marketing_consent || (consent === 'opted_in' && consentSource !== contact.marketing_consent_source)
  const saveConsent = useMutation({
    mutationFn: async () => {
      const { error } = await supabase
        .from('contacts')
        .update({
          marketing_consent: consent,
          marketing_consent_at: consent === 'none' ? null : new Date().toISOString(),
          marketing_consent_source: consent === 'opted_in' ? consentSource : consent === 'opted_out' ? 'manual' : null,
        })
        .eq('id', contact.id)
      if (error) throw error
    },
    onSuccess: () => {
      refresh()
      qc.invalidateQueries({ queryKey: ['contacts'] })
    },
  })

  const updateConversation = useMutation({
    mutationFn: async (patch: Partial<{ stage: Stage; status: ConversationStatus; assigned_to: string | null; ai_handled: boolean }>) => {
      const { error } = await supabase.from('conversations').update(patch).eq('id', conversation.id)
      if (error) throw error
    },
    onSuccess: refresh,
  })

  function addTag() {
    const t = tagInput.trim().toLowerCase()
    if (t && !tags.includes(t)) setTags([...tags, t])
    setTagInput('')
    setSaved(false)
  }

  function onTagKey(e: KeyboardEvent<HTMLInputElement>) {
    if (e.key === 'Enter' || e.key === ',') {
      e.preventDefault()
      addTag()
    }
  }

  return (
    <div className="h-full space-y-5 overflow-y-auto p-4">
      <div>
        <p className="text-sm font-semibold">Contato</p>
        <p className="text-xs text-muted-foreground">{formatPhone(contact.wa_id)}</p>
      </div>

      <div className="space-y-1.5">
        <Label htmlFor="c-name">Nome</Label>
        <Input
          id="c-name"
          value={name}
          onChange={(e) => {
            setName(e.target.value)
            setSaved(false)
          }}
        />
      </div>

      <div className="space-y-1.5">
        <Label htmlFor="c-notes">Notas</Label>
        <Textarea
          id="c-notes"
          rows={4}
          value={notes}
          onChange={(e) => {
            setNotes(e.target.value)
            setSaved(false)
          }}
          placeholder="Ex.: prefere arte pronta, retira na loja"
        />
      </div>

      <div className="space-y-1.5">
        <Label htmlFor="c-tags">Tags</Label>
        <div className="flex flex-wrap gap-1">
          {tags.map((t) => (
            <Badge key={t} className="gap-1 bg-secondary text-secondary-foreground">
              {t}
              <button
                aria-label={`Remover tag ${t}`}
                onClick={() => {
                  setTags(tags.filter((x) => x !== t))
                  setSaved(false)
                }}
              >
                <X className="h-3 w-3" />
              </button>
            </Badge>
          ))}
        </div>
        <Input id="c-tags" value={tagInput} onChange={(e) => setTagInput(e.target.value)} onKeyDown={onTagKey} onBlur={addTag} placeholder="Digite e tecle Enter" />
      </div>

      <div className="flex items-center gap-2">
        <Button size="sm" onClick={() => saveContact.mutate()} disabled={saveContact.isPending}>
          {saveContact.isPending ? 'Salvando…' : 'Salvar contato'}
        </Button>
        {saved && <span className="text-xs text-primary">Salvo</span>}
        {saveContact.isError && <span className="text-xs text-destructive">Erro ao salvar</span>}
      </div>

      <hr />

      <div className="space-y-1.5">
        <Label htmlFor="c-consent">Consentimento para promoções</Label>
        <Select id="c-consent" value={consent} onChange={(e) => setConsent(e.target.value as MarketingConsent)}>
          {CONSENTS.map((c) => (
            <option key={c.value} value={c.value}>
              {c.label}
            </option>
          ))}
        </Select>
        {consent === 'opted_in' && (
          <>
            <Label htmlFor="c-consent-src">Como o cliente autorizou</Label>
            <Select id="c-consent-src" value={consentSource} onChange={(e) => setConsentSource(e.target.value as ConsentSource)}>
              {CONSENT_SOURCES.map((c) => (
                <option key={c.value} value={c.value}>
                  {c.label}
                </option>
              ))}
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
        <div className="flex items-center gap-2">
          <Button size="sm" variant="outline" onClick={() => saveConsent.mutate()} disabled={!consentChanged || saveConsent.isPending}>
            {saveConsent.isPending ? 'Salvando…' : 'Salvar consentimento'}
          </Button>
          {saveConsent.isError && <span className="text-xs text-destructive">Erro ao salvar</span>}
        </div>
      </div>

      <hr />

      <div className="space-y-1.5">
        <Label htmlFor="c-stage">Etapa do funil</Label>
        <Select id="c-stage" value={conversation.stage} onChange={(e) => updateConversation.mutate({ stage: e.target.value as Stage })}>
          {STAGES.map((s) => (
            <option key={s.value} value={s.value}>
              {s.label}
            </option>
          ))}
        </Select>
      </div>

      <div className="space-y-1.5">
        <Label htmlFor="c-status">Situação</Label>
        <Select id="c-status" value={conversation.status} onChange={(e) => updateConversation.mutate({ status: e.target.value as ConversationStatus })}>
          {STATUSES.map((s) => (
            <option key={s.value} value={s.value}>
              {s.label}
            </option>
          ))}
        </Select>
      </div>

      <div className="space-y-1.5">
        <Label htmlFor="c-agent">Atendente responsável</Label>
        <Select id="c-agent" value={conversation.assigned_to ?? ''} onChange={(e) => updateConversation.mutate({ assigned_to: e.target.value || null })}>
          <option value="">Sem responsável</option>
          {profiles?.map((p) => (
            <option key={p.id} value={p.id}>
              {p.name}
            </option>
          ))}
        </Select>
      </div>

      <div className="flex items-center justify-between gap-3">
        <Label htmlFor="c-ai" className="text-sm text-foreground">
          Atendimento por IA
        </Label>
        <Switch id="c-ai" checked={conversation.ai_handled} onCheckedChange={(v) => updateConversation.mutate({ ai_handled: v })} />
      </div>
      {updateConversation.isError && <p className="text-xs text-destructive">Não foi possível salvar a alteração.</p>}

      {profile?.role === 'admin' && (
        <>
          <hr />
          <div className="space-y-1.5">
            <p className="text-xs text-muted-foreground">
              Pedido de exclusão de dados (LGPD): apaga o contato, as conversas e as mensagens. Se ele tinha pedido para parar as promoções, só o telefone fica
              guardado para respeitar esse pedido.
            </p>
            <Button size="sm" variant="outline" className="text-destructive" onClick={onDelete} disabled={deleteContact.isPending}>
              {deleteContact.isPending ? 'Excluindo…' : 'Excluir contato e dados'}
            </Button>
            {deleteContact.isError && <p className="text-xs text-destructive">Não foi possível excluir.</p>}
          </div>
        </>
      )}
    </div>
  )
}
