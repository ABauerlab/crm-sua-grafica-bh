import { useMutation, useQueryClient } from '@tanstack/react-query'
import { Check, ListChecks, Plus, Trash2 } from 'lucide-react'
import { useMemo, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { EmptyState } from '@/components/ui/empty-state'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Modal } from '@/components/ui/sheet'
import { Select } from '@/components/ui/select'
import { Skeleton } from '@/components/ui/skeleton'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { useToast } from '@/components/ui/toast'
import { TemplatePicker } from '@/features/inbox/TemplatePicker'
import { useTasks } from '@/hooks/crm'
import { useOrders } from '@/hooks/orders'
import { useContacts } from '@/hooks/queries'
import { useSetting } from '@/hooks/settings'
import { invokeFunction } from '@/lib/api'
import { contactLabel } from '@/lib/format'
import { formatBRL } from '@/lib/money'
import { formatDuration, hoursInStage } from '@/lib/orders'
import { supabase } from '@/lib/supabase'
import type { Task } from '@/lib/types'
import { cn } from '@/lib/utils'

const PRIORITY: Record<Task['priority'], { label: string; chip: string }> = {
  alta: { label: 'Alta', chip: 'bg-brand-red/10 text-brand-red' },
  media: { label: 'Média', chip: 'bg-brand-yellow/30 text-ink' },
  baixa: { label: 'Baixa', chip: 'bg-ink/10 text-ink' },
}

type View = 'hoje' | 'atrasadas' | 'proximas' | 'concluidas'

const startOfToday = () => {
  const d = new Date()
  d.setHours(0, 0, 0, 0)
  return d.getTime()
}

export default function Tasks() {
  const qc = useQueryClient()
  const toast = useToast()
  const navigate = useNavigate()
  const { data: tasks, isLoading } = useTasks()
  const { data: orders } = useOrders()
  const { data: contacts } = useContacts()
  const { data: rep } = useSetting('repurchase')
  const [view, setView] = useState<View>('hoje')
  const [form, setForm] = useState<{ title: string; due: string; priority: Task['priority']; contactId: string } | null>(null)
  const [sendFor, setSendFor] = useState<{ contactId: string; name: string } | null>(null)
  const days = rep?.days ?? 45

  const refresh = () => qc.invalidateQueries({ queryKey: ['tasks'] })

  const create = useMutation({
    mutationFn: async (t: Partial<Task> & { title: string }) => {
      const { error } = await supabase.from('tasks').insert(t)
      if (error) throw new Error(error.message)
    },
    onSuccess: () => {
      refresh()
      toast('ok', 'Tarefa criada.')
    },
    onError: (e: Error) => toast('error', e.message),
  })

  const toggle = useMutation({
    mutationFn: async (t: Task) => {
      const { error } = await supabase.from('tasks').update({ done_at: t.done_at ? null : new Date().toISOString() }).eq('id', t.id)
      if (error) throw new Error(error.message)
    },
    onSuccess: refresh,
    onError: (e: Error) => toast('error', e.message),
  })

  const remove = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.from('tasks').delete().eq('id', id)
      if (error) throw new Error(error.message)
    },
    onSuccess: refresh,
  })

  const today0 = startOfToday()
  const today1 = today0 + 86_400_000
  const buckets = useMemo(() => {
    const all = tasks ?? []
    const open = all.filter((t) => !t.done_at)
    const due = (t: Task) => (t.due_at ? new Date(t.due_at).getTime() : null)
    return {
      hoje: open.filter((t) => due(t) !== null && due(t)! >= today0 && due(t)! < today1),
      atrasadas: open.filter((t) => due(t) !== null && due(t)! < today0),
      proximas: open.filter((t) => due(t) === null || due(t)! >= today1),
      concluidas: all.filter((t) => t.done_at).slice(0, 50),
    }
  }, [tasks, today0, today1])

  // Sugestões automáticas a partir do estado dos pedidos
  const suggestions = useMemo(() => {
    const open = new Set((tasks ?? []).filter((t) => !t.done_at && t.order_id).map((t) => `${t.kind}:${t.order_id}`))
    const out: { key: string; kind: NonNullable<Task['kind']>; title: string; detail: string; orderId: string; contactId: string; priority: Task['priority'] }[] = []
    for (const o of orders ?? []) {
      const name = contactLabel(o.contact)
      const h = hoursInStage(o)
      if (o.stage === 'aguardando_pagamento' && h >= 24) out.push({ key: `cobrar_pagamento:${o.id}`, kind: 'cobrar_pagamento', title: `Cobrar pagamento de ${name}`, detail: `Pedido #${o.number} (${formatBRL(o.fin.total)}) aguarda pagamento há ${formatDuration(h)}`, orderId: o.id, contactId: o.contact_id, priority: 'alta' })
      if (o.stage === 'prova' && h >= 24) out.push({ key: `aprovar_prova:${o.id}`, kind: 'aprovar_prova', title: `Pedir aprovação da prova de ${name}`, detail: `Pedido #${o.number} está em prova há ${formatDuration(h)}`, orderId: o.id, contactId: o.contact_id, priority: 'media' })
      if (o.stage === 'producao' && o.due_date && new Date(o.due_date + 'T12:00').getTime() - Date.now() < 2 * 86_400_000) out.push({ key: `avisar_entrega:${o.id}`, kind: 'avisar_entrega', title: `Avisar ${name} sobre a entrega`, detail: `Pedido #${o.number} com prazo em ${new Date(o.due_date + 'T12:00').toLocaleDateString('pt-BR')}`, orderId: o.id, contactId: o.contact_id, priority: 'media' })
    }
    return out.filter((s) => !open.has(s.key))
  }, [orders, tasks])

  // Recompra: última compra paga há `days` dias ou mais
  const repurchase = useMemo(() => {
    const last = new Map<string, { at: number; total: number; title: string }>()
    for (const o of orders ?? []) {
      if (!(o.payment_status === 'aprovado' || o.payment_manual) || !o.paid_at) continue
      const at = new Date(o.paid_at).getTime()
      const cur = last.get(o.contact_id)
      if (!cur || at > cur.at) last.set(o.contact_id, { at, total: o.fin.total, title: o.title })
    }
    const byId = new Map((contacts ?? []).map((c) => [c.id, c]))
    return [...last.entries()]
      .map(([contactId, v]) => ({ contact: byId.get(contactId), contactId, days: Math.floor((Date.now() - v.at) / 86_400_000), ...v }))
      .filter((r) => r.contact && r.days >= days)
      .sort((a, b) => b.days - a.days)
  }, [orders, contacts, days])

  const send = useMutation({
    mutationFn: async (input: { contactId: string; template: { name: string; language: string; variables: string[] } }) => {
      const { data: conv, error } = await supabase.from('conversations').select('id').eq('contact_id', input.contactId).maybeSingle()
      if (error) throw new Error(error.message)
      let id = conv?.id as string | undefined
      if (!id) {
        const { data, error: e2 } = await supabase.from('conversations').insert({ contact_id: input.contactId }).select('id').single()
        if (e2) throw new Error(e2.message)
        id = data.id as string
      }
      await invokeFunction('whatsapp-send', { conversation_id: id, template_name: input.template.name, language: input.template.language, variables: input.template.variables })
      return id
    },
    onSuccess: (id) => {
      setSendFor(null)
      toast('ok', 'Template enviado.')
      navigate(`/inbox/${id}`)
    },
    onError: (e: Error) => toast('error', e.message),
  })

  const list = buckets[view]
  const counts: Record<View, number> = { hoje: buckets.hoje.length, atrasadas: buckets.atrasadas.length, proximas: buckets.proximas.length, concluidas: buckets.concluidas.length }

  return (
    <div className="flex h-full flex-col">
      <header className="flex items-center justify-between gap-2 border-b px-4 py-3">
        <h1 className="text-xl font-black">Tarefas</h1>
        <Button size="sm" onClick={() => setForm({ title: '', due: '', priority: 'media', contactId: '' })}><Plus className="h-4 w-4" /> Nova tarefa</Button>
      </header>
      <Tabs defaultValue="tarefas" className="flex min-h-0 flex-1 flex-col">
        <TabsList>
          <TabsTrigger value="tarefas">Tarefas</TabsTrigger>
          <TabsTrigger value="sugestoes">Sugestões{suggestions.length ? ` (${suggestions.length})` : ''}</TabsTrigger>
          <TabsTrigger value="recompra">Recompra{repurchase.length ? ` (${repurchase.length})` : ''}</TabsTrigger>
        </TabsList>

        <TabsContent value="tarefas" className="space-y-3">
          <div className="flex flex-wrap gap-1" role="group" aria-label="Visão das tarefas">
            {(['hoje', 'atrasadas', 'proximas', 'concluidas'] as View[]).map((v) => (
              <button key={v} aria-pressed={view === v} onClick={() => setView(v)} className={cn('min-h-10 rounded-sm px-3 text-sm font-bold', view === v ? 'bg-ink text-white' : 'bg-secondary')}>
                {{ hoje: 'Hoje', atrasadas: 'Atrasadas', proximas: 'Próximas', concluidas: 'Concluídas' }[v]} <span className={cn('tabular', v === 'atrasadas' && counts[v] > 0 && view !== v && 'text-brand-red')}>({counts[v]})</span>
              </button>
            ))}
          </div>
          {isLoading ? (
            <Skeleton className="h-32 w-full" />
          ) : list.length === 0 ? (
            <EmptyState icon={ListChecks} title={view === 'atrasadas' ? 'Nada atrasado' : view === 'hoje' ? 'Nada para hoje' : 'Nenhuma tarefa aqui'}>
              {view === 'hoje' ? 'Veja a aba Sugestões para lembretes automáticos de cobrança, prova e entrega.' : 'Crie uma tarefa com o botão acima.'}
            </EmptyState>
          ) : (
            <ul className="space-y-2">
              {list.map((t) => (
                <li key={t.id} className="flex items-start gap-3 rounded-md border bg-card p-3">
                  <button
                    onClick={() => toggle.mutate(t)}
                    aria-label={t.done_at ? 'Reabrir tarefa' : 'Concluir tarefa'}
                    className={cn('mt-0.5 flex h-8 w-8 shrink-0 items-center justify-center rounded-md border-2', t.done_at ? 'border-brand-green bg-brand-green text-white' : 'border-input hover:bg-secondary')}
                  >
                    {t.done_at && <Check className="h-4 w-4" />}
                  </button>
                  <div className="min-w-0 flex-1">
                    <p className={cn('font-semibold', t.done_at && 'text-muted-foreground line-through')}>{t.title}</p>
                    <p className="flex flex-wrap items-center gap-x-2 text-xs text-muted-foreground">
                      {t.due_at && <span className={cn('tabular', !t.done_at && new Date(t.due_at).getTime() < today0 && 'font-bold text-brand-red')}>{new Date(t.due_at).toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' })}</span>}
                      {t.contact && <span>{contactLabel(t.contact)}</span>}
                      {t.order && <Link to={`/kanban?pedido=${t.order.id}`} className="font-semibold text-link underline">Pedido #{t.order.number}</Link>}
                    </p>
                  </div>
                  <Badge className={PRIORITY[t.priority].chip}>{PRIORITY[t.priority].label}</Badge>
                  <Button variant="ghost" size="icon" aria-label="Excluir tarefa" onClick={() => remove.mutate(t.id)}><Trash2 className="h-4 w-4" /></Button>
                </li>
              ))}
            </ul>
          )}
        </TabsContent>

        <TabsContent value="sugestoes" className="space-y-2">
          <p className="text-sm text-muted-foreground">Lembretes sugeridos pelo estado dos pedidos. Crie a tarefa para acompanhar ou ignore.</p>
          {suggestions.length === 0 ? (
            <EmptyState icon={ListChecks} title="Sem sugestões agora">Quando um pedido ficar parado esperando pagamento, prova ou entrega, o lembrete aparece aqui.</EmptyState>
          ) : (
            <ul className="space-y-2">
              {suggestions.map((s) => (
                <li key={s.key} className="flex flex-wrap items-center justify-between gap-2 rounded-md border border-l-4 border-l-brand-yellow bg-card p-3">
                  <div className="min-w-0"><p className="font-semibold">{s.title}</p><p className="text-xs text-muted-foreground">{s.detail}</p></div>
                  <Button size="sm" onClick={() => create.mutate({ title: s.title, kind: s.kind, order_id: s.orderId, contact_id: s.contactId, priority: s.priority, due_at: new Date().toISOString() })}>Criar tarefa</Button>
                </li>
              ))}
            </ul>
          )}
        </TabsContent>

        <TabsContent value="recompra" className="space-y-2">
          <p className="text-sm text-muted-foreground">Clientes que compraram há {days} dias ou mais (ajuste em Configurações). O envio usa um template aprovado e respeita o consentimento para promoções.</p>
          {repurchase.length === 0 ? (
            <EmptyState icon={ListChecks} title="Ninguém para recomprar ainda">Quando um cliente completar {days} dias desde a última compra paga, ele aparece aqui.</EmptyState>
          ) : (
            <ul className="space-y-2">
              {repurchase.map((r) => (
                <li key={r.contactId} className="flex flex-wrap items-center justify-between gap-2 rounded-md border bg-card p-3">
                  <div className="min-w-0">
                    <p className="font-semibold">{contactLabel(r.contact!)}</p>
                    <p className="text-xs text-muted-foreground tabular">Última compra há {r.days} dias · {r.title} · {formatBRL(r.total)}</p>
                  </div>
                  <Button size="sm" onClick={() => setSendFor({ contactId: r.contactId, name: contactLabel(r.contact!) })}>Enviar template de recompra</Button>
                </li>
              ))}
            </ul>
          )}
        </TabsContent>
      </Tabs>

      <Modal open={!!form} onOpenChange={(o) => !o && setForm(null)} title="Nova tarefa">
        {form && (
          <form
            className="space-y-3"
            onSubmit={(e) => {
              e.preventDefault()
              create.mutate(
                { title: form.title.trim(), due_at: form.due ? new Date(form.due).toISOString() : null, priority: form.priority, contact_id: form.contactId || null },
                { onSuccess: () => setForm(null) },
              )
            }}
          >
            <div className="space-y-1.5"><Label htmlFor="t-title">O que fazer</Label><Input id="t-title" required value={form.title} onChange={(e) => setForm({ ...form, title: e.target.value })} /></div>
            <div className="grid grid-cols-2 gap-2">
              <div className="space-y-1.5"><Label htmlFor="t-due">Quando</Label><Input id="t-due" type="datetime-local" value={form.due} onChange={(e) => setForm({ ...form, due: e.target.value })} /></div>
              <div className="space-y-1.5">
                <Label htmlFor="t-pri">Prioridade</Label>
                <Select id="t-pri" value={form.priority} onChange={(e) => setForm({ ...form, priority: e.target.value as Task['priority'] })}>
                  <option value="alta">Alta</option><option value="media">Média</option><option value="baixa">Baixa</option>
                </Select>
              </div>
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="t-contact">Contato (opcional)</Label>
              <Select id="t-contact" value={form.contactId} onChange={(e) => setForm({ ...form, contactId: e.target.value })}>
                <option value="">Sem contato</option>
                {(contacts ?? []).map((c) => <option key={c.id} value={c.id}>{contactLabel(c)}</option>)}
              </Select>
            </div>
            <div className="flex justify-end gap-2"><Button type="button" variant="outline" onClick={() => setForm(null)}>Cancelar</Button><Button type="submit" disabled={create.isPending}>Criar tarefa</Button></div>
          </form>
        )}
      </Modal>

      <Modal open={!!sendFor} onOpenChange={(o) => !o && setSendFor(null)} title={`Recompra para ${sendFor?.name ?? ''}`} description="Escolha o template aprovado e preencha as variáveis.">
        {sendFor && <TemplatePicker sending={send.isPending} onSend={(t) => send.mutate({ contactId: sendFor.contactId, template: t })} />}
      </Modal>
    </div>
  )
}
