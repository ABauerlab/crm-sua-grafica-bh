import { useMutation, useQueryClient } from '@tanstack/react-query'
import { X } from 'lucide-react'
import { useState, type KeyboardEvent } from 'react'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { Switch } from '@/components/ui/switch'
import { Textarea } from '@/components/ui/textarea'
import { useProfiles } from '@/hooks/queries'
import { STAGES, STATUSES, formatPhone } from '@/lib/format'
import { supabase } from '@/lib/supabase'
import type { ConversationStatus, ConversationWithContact, Stage } from '@/lib/types'

export function ContactPanel({ conversation }: { conversation: ConversationWithContact }) {
  const qc = useQueryClient()
  const { data: profiles } = useProfiles()
  const { contact } = conversation

  const [name, setName] = useState(contact.name ?? '')
  const [notes, setNotes] = useState(contact.notes ?? '')
  const [tags, setTags] = useState<string[]>(contact.tags)
  const [tagInput, setTagInput] = useState('')
  const [saved, setSaved] = useState(false)

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
    </div>
  )
}
