import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import { lazy, Suspense } from 'react'
import { Download, Plus, Trash2 } from 'lucide-react'
import { useQuery } from '@tanstack/react-query'
import { useQuickReplies } from '@/hooks/crm'
import { DEFAULTS, useSaveSetting, useSetting, type AgentSettings, type CampaignGoals, type CompanySettings } from '@/hooks/settings'
import { downloadCsv } from '@/lib/csv'
import type { AgentLog } from '@/lib/types'
import { Textarea } from '@/components/ui/textarea'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Skeleton } from '@/components/ui/skeleton'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { useToast } from '@/components/ui/toast'
import { useSettings } from '@/hooks/orders'
import { ORDER_STAGES, type OrderStage } from '@/lib/orders'
import { type PricingRules } from '@/lib/pricing'
import { supabase } from '@/lib/supabase'

import AgentTemplatesStatus from '@/features/agent/AgentTemplatesStatus'
const KnowledgeTab = lazy(() => import('@/features/agent/KnowledgeTab'))

const TemplatesPanel = lazy(() => import('@/pages/Templates'))

function NumberField({ id, label, hint, value, onChange, step = '0.1' }: { id: string; label: string; hint: string; value: number; onChange: (v: number) => void; step?: string }) {
  return (
    <div className="space-y-1.5">
      <Label htmlFor={id}>{label}</Label>
      <Input id={id} type="number" inputMode="decimal" step={step} min="0" value={Number.isFinite(value) ? value : ''} onChange={(e) => onChange(Number(e.target.value))} className="tabular" />
      <p className="text-xs text-muted-foreground">{hint}</p>
    </div>
  )
}

function PricingTab() {
  const toast = useToast()
  const qc = useQueryClient()
  const { data, isLoading } = useSettings()
  const [rules, setRules] = useState<PricingRules | null>(null)

  useEffect(() => {
    if (data && !rules) setRules(data.pricing)
  }, [data, rules])

  const save = useMutation({
    mutationFn: async (r: PricingRules) => {
      const { error } = await supabase.from('app_settings').upsert({ key: 'pricing', value: r, updated_at: new Date().toISOString() })
      if (error) throw new Error(error.message)
    },
    onSuccess: () => {
      toast('ok', 'Parâmetros de preço salvos.')
      qc.invalidateQueries({ queryKey: ['settings'] })
    },
    onError: (e: Error) => toast('error', `Não foi possível salvar: ${e.message}`),
  })

  if (isLoading || !rules) return <Skeleton className="h-64 w-full max-w-xl" />
  const set = (k: keyof PricingRules) => (v: number) => setRules({ ...rules, [k]: v })
  return (
    <form
      className="max-w-xl space-y-5"
      onSubmit={(e) => {
        e.preventDefault()
        save.mutate(rules)
      }}
    >
      <p className="text-sm text-muted-foreground">Estes limites protegem o preço nos pedidos. Itens abaixo do piso, descontos acima do máximo ou lucro abaixo do mínimo pedem confirmação com justificativa.</p>
      <div className="grid gap-4 sm:grid-cols-2">
        <NumberField id="floor" label="Piso (multiplicador do custo)" hint="Preço mínimo por unidade = custo x este valor. Padrão 1,5." value={rules.floor_multiplier} onChange={set('floor_multiplier')} step="0.05" />
        <NumberField id="maxd" label="Desconto máximo sem consulta (%)" hint="Padrão 10%." value={rules.max_discount_pct} onChange={set('max_discount_pct')} />
        <NumberField id="minp" label="Lucro líquido mínimo por pedido (R$)" hint="Padrão R$ 60." value={rules.min_net_profit} onChange={set('min_net_profit')} step="1" />
        <NumberField id="tax" label="Impostos estimados (%)" hint="Usado em novos pedidos. Padrão 6%." value={rules.tax_pct} onChange={set('tax_pct')} />
        <NumberField id="fee" label="Taxa de pagamento (%)" hint="Usado em novos pedidos. Padrão 1,5%." value={rules.payment_fee_pct} onChange={set('payment_fee_pct')} />
      </div>
      <Button type="submit" disabled={save.isPending}>{save.isPending ? 'Salvando…' : 'Salvar parâmetros'}</Button>
    </form>
  )
}

function KanbanTab() {
  const toast = useToast()
  const qc = useQueryClient()
  const { data, isLoading } = useSettings()
  const [hours, setHours] = useState<Record<OrderStage, number> | null>(null)
  useEffect(() => {
    if (data && !hours) setHours(data.kanban.stage_limit_hours)
  }, [data, hours])

  const save = useMutation({
    mutationFn: async (h: Record<OrderStage, number>) => {
      const { error } = await supabase.from('app_settings').upsert({ key: 'kanban', value: { stage_limit_hours: h }, updated_at: new Date().toISOString() })
      if (error) throw new Error(error.message)
    },
    onSuccess: () => {
      toast('ok', 'Limites do kanban salvos.')
      qc.invalidateQueries({ queryKey: ['settings'] })
    },
    onError: (e: Error) => toast('error', `Não foi possível salvar: ${e.message}`),
  })

  if (isLoading || !hours) return <Skeleton className="h-64 w-full max-w-xl" />
  return (
    <form
      className="max-w-xl space-y-5"
      onSubmit={(e) => {
        e.preventDefault()
        save.mutate(hours)
      }}
    >
      <p className="text-sm text-muted-foreground">Tempo máximo (em horas) que um pedido pode ficar em cada etapa antes de ganhar alerta no cartão. Use 0 para não alertar.</p>
      <div className="grid gap-4 sm:grid-cols-3">
        {ORDER_STAGES.map((s) => (
          <NumberField key={s.value} id={`h-${s.value}`} label={s.label} hint="horas" step="1" value={hours[s.value]} onChange={(v) => setHours({ ...hours, [s.value]: v })} />
        ))}
      </div>
      <Button type="submit" disabled={save.isPending}>{save.isPending ? 'Salvando…' : 'Salvar limites'}</Button>
    </form>
  )
}

function CompanyTab() {
  const toast = useToast()
  const { data } = useSetting('company')
  const save = useSaveSetting('company')
  const [v, setV] = useState<CompanySettings | null>(null)
  useEffect(() => {
    if (data && !v) setV(data)
  }, [data, v])
  if (!v) return <Skeleton className="h-64 w-full max-w-xl" />
  const f = (k: keyof CompanySettings, label: string) => (
    <div className="space-y-1.5" key={k}>
      <Label htmlFor={`co-${k}`}>{label}</Label>
      <Input id={`co-${k}`} value={v[k]} onChange={(e) => setV({ ...v, [k]: e.target.value })} />
    </div>
  )
  return (
    <form className="max-w-xl space-y-4" onSubmit={(e) => { e.preventDefault(); save.mutate(v, { onSuccess: () => toast('ok', 'Dados da empresa salvos.'), onError: (er) => toast('error', er.message) }) }}>
      <div className="grid gap-4 sm:grid-cols-2">
        {f('name', 'Nome fantasia')}{f('legal_name', 'Razão social')}{f('cnpj', 'CNPJ')}{f('phone', 'Telefone')}{f('email', 'E-mail')}{f('hours', 'Horário de atendimento')}
      </div>
      {f('address', 'Endereço')}
      <p className="text-xs text-muted-foreground">Estes dados servem de base para documentos e para o agente de IA. A logo oficial fica em <code>public/brand</code>.</p>
      <Button type="submit" disabled={save.isPending}>Salvar dados da empresa</Button>
    </form>
  )
}

function QuickRepliesTab() {
  const toast = useToast()
  const qc = useQueryClient()
  const { data } = useQuickReplies()
  const [f, setF] = useState({ shortcut: '', title: '', body: '' })
  const add = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.from('quick_replies').insert({ shortcut: f.shortcut.trim().toLowerCase().replace(/^\//, ''), title: f.title.trim(), body: f.body.trim() })
      if (error) throw new Error(error.code === '23505' ? 'Já existe uma resposta com esse atalho.' : error.message)
    },
    onSuccess: () => { setF({ shortcut: '', title: '', body: '' }); qc.invalidateQueries({ queryKey: ['quick-replies'] }); toast('ok', 'Resposta rápida criada.') },
    onError: (e: Error) => toast('error', e.message),
  })
  const del = useMutation({
    mutationFn: async (id: string) => { const { error } = await supabase.from('quick_replies').delete().eq('id', id); if (error) throw new Error(error.message) },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['quick-replies'] }),
  })
  return (
    <div className="max-w-2xl space-y-5">
      <p className="text-sm text-muted-foreground">No chat, digite <strong>/</strong> e o atalho para inserir a resposta. Ex.: <code>/prazo</code>.</p>
      <form className="space-y-3 rounded-md border p-3" onSubmit={(e) => { e.preventDefault(); add.mutate() }}>
        <div className="grid gap-3 sm:grid-cols-3">
          <div className="space-y-1.5"><Label htmlFor="qr-s">Atalho</Label><Input id="qr-s" required pattern="[a-zA-Z0-9_\-]+" placeholder="prazo" value={f.shortcut} onChange={(e) => setF({ ...f, shortcut: e.target.value })} /></div>
          <div className="space-y-1.5 sm:col-span-2"><Label htmlFor="qr-t">Título</Label><Input id="qr-t" required value={f.title} onChange={(e) => setF({ ...f, title: e.target.value })} /></div>
        </div>
        <div className="space-y-1.5"><Label htmlFor="qr-b">Mensagem</Label><Textarea id="qr-b" required rows={3} value={f.body} onChange={(e) => setF({ ...f, body: e.target.value })} /></div>
        <Button type="submit" disabled={add.isPending}><Plus className="h-4 w-4" /> Adicionar</Button>
      </form>
      <ul className="divide-y rounded-md border">
        {(data ?? []).map((q) => (
          <li key={q.id} className="flex items-start justify-between gap-2 p-3 text-sm">
            <div className="min-w-0"><p><code className="rounded-sm bg-secondary px-1 text-xs font-bold">/{q.shortcut}</code> <strong>{q.title}</strong></p><p className="mt-0.5 whitespace-pre-wrap text-muted-foreground">{q.body}</p></div>
            <Button variant="ghost" size="icon" aria-label="Excluir resposta rápida" onClick={() => del.mutate(q.id)}><Trash2 className="h-4 w-4" /></Button>
          </li>
        ))}
        {(data ?? []).length === 0 && <li className="p-4 text-sm text-muted-foreground">Nenhuma resposta rápida ainda.</li>}
      </ul>
    </div>
  )
}

function LabelsTab() {
  const toast = useToast()
  const { data } = useSetting('labels')
  const save = useSaveSetting('labels')
  const [input, setInput] = useState('')
  const labels = data ?? DEFAULTS.labels
  const commit = (next: string[]) => save.mutate(next, { onError: (e) => toast('error', e.message) })
  return (
    <div className="max-w-xl space-y-4">
      <p className="text-sm text-muted-foreground">Etiquetas que você marca nas conversas (dúvida, orçamento, reclamação...).</p>
      <ul className="flex flex-wrap gap-2">
        {labels.map((l) => (
          <li key={l} className="flex items-center gap-1 rounded-sm border bg-brand-cyan/15 px-2 py-1 text-sm font-semibold">
            {l}
            <button aria-label={`Remover etiqueta ${l}`} onClick={() => commit(labels.filter((x) => x !== l))} className="flex h-6 w-6 items-center justify-center rounded-sm hover:bg-secondary"><Trash2 className="h-3.5 w-3.5" /></button>
          </li>
        ))}
      </ul>
      <form className="flex gap-2" onSubmit={(e) => { e.preventDefault(); const t = input.trim().toLowerCase(); if (t && !labels.includes(t)) commit([...labels, t]); setInput('') }}>
        <Input aria-label="Nova etiqueta" placeholder="Nova etiqueta" value={input} onChange={(e) => setInput(e.target.value)} />
        <Button type="submit">Adicionar</Button>
      </form>
    </div>
  )
}

function HolidaysTab() {
  const toast = useToast()
  const qc = useQueryClient()
  const [form, setForm] = useState({ day: '', name: '', scope: 'gráfica' })
  const [extra, setExtra] = useState<string | null>(null)
  const { data: holidays } = useQuery({
    queryKey: ['holidays'],
    queryFn: async () => {
      const { data, error } = await supabase.from('holidays').select('*').gte('day', new Date(Date.now() - 30 * 86_400_000).toISOString().slice(0, 10)).order('day')
      if (error) throw error
      return data as { day: string; name: string; scope: string }[]
    },
  })
  const { data: deadline } = useQuery({
    queryKey: ['setting', 'deadline'],
    queryFn: async () => {
      const { data, error } = await supabase.from('app_settings').select('value').eq('key', 'deadline').maybeSingle()
      if (error) throw error
      return Number((data?.value as { extra_days?: number } | null)?.extra_days ?? 1)
    },
  })
  const refresh = () => qc.invalidateQueries({ queryKey: ['holidays'] })
  const add = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.from('holidays').upsert({ day: form.day, name: form.name.trim(), scope: form.scope })
      if (error) throw new Error(error.message)
    },
    onSuccess: () => { setForm({ day: '', name: '', scope: 'gráfica' }); refresh() },
    onError: (e: Error) => toast('error', e.message),
  })
  const remove = useMutation({
    mutationFn: async (day: string) => {
      const { error } = await supabase.from('holidays').delete().eq('day', day)
      if (error) throw new Error(error.message)
    },
    onSuccess: refresh,
    onError: (e: Error) => toast('error', e.message),
  })
  const saveExtra = useMutation({
    mutationFn: async (n: number) => {
      const { error } = await supabase.from('app_settings').upsert({ key: 'deadline', value: { extra_days: n } })
      if (error) throw new Error(error.message)
    },
    onSuccess: () => { toast('ok', 'Margem salva.'); qc.invalidateQueries({ queryKey: ['setting', 'deadline'] }) },
    onError: (e: Error) => toast('error', e.message),
  })
  return (
    <div className="max-w-xl space-y-5">
      <p className="text-sm text-muted-foreground">O prazo do pedido conta a partir do pagamento confirmado, em dias úteis (sem sábado, domingo e os dias abaixo). Inclua aqui recessos e feriados da gráfica.</p>
      <div className="flex items-end gap-2">
        <div className="space-y-1.5">
          <Label htmlFor="extra-days">Dias extras de margem</Label>
          <Input id="extra-days" type="number" min="0" className="w-28" value={extra ?? String(deadline ?? 1)} onChange={(e) => setExtra(e.target.value)} />
        </div>
        <Button variant="outline" onClick={() => saveExtra.mutate(Math.max(0, Math.round(Number(extra ?? deadline ?? 1) || 0)))}>Salvar</Button>
      </div>
      <form className="grid grid-cols-2 gap-2 sm:grid-cols-[9rem_1fr_auto]" onSubmit={(e) => { e.preventDefault(); if (form.day && form.name.trim()) add.mutate() }}>
        <Input aria-label="Data" type="date" value={form.day} onChange={(e) => setForm({ ...form, day: e.target.value })} />
        <Input aria-label="Nome do feriado ou recesso" placeholder="Nome (ex.: recesso de fim de ano)" className="col-span-2 sm:col-span-1" value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} />
        <Button type="submit" disabled={add.isPending}>Adicionar</Button>
      </form>
      <ul className="divide-y rounded-md border">
        {(holidays ?? []).map((h) => (
          <li key={h.day} className="flex items-center justify-between gap-2 px-3 py-1.5 text-sm">
            <span><span className="tabular font-semibold">{new Date(h.day + 'T12:00').toLocaleDateString('pt-BR', { weekday: 'short', day: '2-digit', month: '2-digit', year: 'numeric' })}</span> · {h.name}</span>
            <button aria-label={`Remover ${h.name}`} onClick={() => remove.mutate(h.day)} className="flex h-8 w-8 items-center justify-center rounded-sm hover:bg-secondary"><Trash2 className="h-4 w-4" /></button>
          </li>
        ))}
      </ul>
    </div>
  )
}

function GoalsTab() {
  const toast = useToast()
  const goals = useSetting('campaign_goals')
  const rep = useSetting('repurchase')
  const saveGoals = useSaveSetting('campaign_goals')
  const saveRep = useSaveSetting('repurchase')
  const [g, setG] = useState<CampaignGoals | null>(null)
  const [days, setDays] = useState<number | null>(null)
  useEffect(() => { if (goals.data && !g) setG(goals.data) }, [goals.data, g])
  useEffect(() => { if (rep.data && days === null) setDays(rep.data.days) }, [rep.data, days])
  if (!g || days === null) return <Skeleton className="h-48 w-full max-w-xl" />
  return (
    <form className="max-w-xl space-y-5" onSubmit={(e) => { e.preventDefault(); saveGoals.mutate(g); saveRep.mutate({ days }, { onSuccess: () => toast('ok', 'Metas salvas.'), onError: (er) => toast('error', er.message) }) }}>
      <p className="text-sm text-muted-foreground">Resultados dentro da meta ficam verdes e fora da meta ficam vermelhos em Campanhas.</p>
      <div className="grid gap-4 sm:grid-cols-3">
        <NumberField id="g1" label="Custo máx. por conversa (R$)" hint="Padrão R$ 6" value={g.max_cost_per_conversation} onChange={(v) => setG({ ...g, max_cost_per_conversation: v })} />
        <NumberField id="g2" label="Custo máx. por venda (R$)" hint="Padrão R$ 60" value={g.max_cost_per_sale} onChange={(v) => setG({ ...g, max_cost_per_sale: v })} />
        <NumberField id="g3" label="ROAS mínimo (x)" hint="Padrão 4x" value={g.min_roas} onChange={(v) => setG({ ...g, min_roas: v })} />
      </div>
      <NumberField id="g4" label="Recompra após (dias)" hint="Clientes aparecem em Tarefas > Recompra depois deste prazo. Padrão 45." value={days} step="1" onChange={setDays} />
      <Button type="submit">Salvar metas</Button>
    </form>
  )
}

function AgentTab() {
  const toast = useToast()
  const { data } = useSetting('agent')
  const save = useSaveSetting('agent')
  const [v, setV] = useState<AgentSettings | null>(null)
  useEffect(() => { if (data && !v) setV(data) }, [data, v])
  const logs = useQuery({
    queryKey: ['agent-logs'],
    refetchInterval: 30_000,
    queryFn: async () => {
      const { data, error } = await supabase.from('agent_logs').select('*').order('created_at', { ascending: false }).limit(100)
      if (error) throw error
      return data as AgentLog[]
    },
  })
  if (!v) return <Skeleton className="h-64 w-full max-w-xl" />
  const DAYS = ['Dom', 'Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb']
  return (
    <div className="max-w-3xl space-y-6">
      <form className="space-y-4" onSubmit={(e) => { e.preventDefault(); save.mutate(v, { onSuccess: () => toast('ok', 'Configuração do agente salva.'), onError: (er) => toast('error', er.message) }) }}>
        <p className="text-sm text-muted-foreground">O agente de IA ainda não está conectado. Esta tela guarda as regras que ele vai ler. Para pausar ou ligar tudo na hora, use o botão no topo do sistema.</p>
        <div className="grid gap-4 sm:grid-cols-2">
          <div className="space-y-1.5"><Label htmlFor="ag-s">Começa às</Label><Input id="ag-s" type="time" value={v.hours.start} onChange={(e) => setV({ ...v, hours: { ...v.hours, start: e.target.value } })} /></div>
          <div className="space-y-1.5"><Label htmlFor="ag-e">Termina às</Label><Input id="ag-e" type="time" value={v.hours.end} onChange={(e) => setV({ ...v, hours: { ...v.hours, end: e.target.value } })} /></div>
        </div>
        <fieldset className="flex flex-wrap gap-1" aria-label="Dias de atendimento">
          {DAYS.map((d, i) => (
            <button type="button" key={d} aria-pressed={v.hours.days.includes(i)} onClick={() => setV({ ...v, hours: { ...v.hours, days: v.hours.days.includes(i) ? v.hours.days.filter((x) => x !== i) : [...v.hours.days, i].sort() } })} className={`min-h-10 min-w-12 rounded-sm text-sm font-bold ${v.hours.days.includes(i) ? 'bg-ink text-white' : 'bg-secondary'}`}>{d}</button>
          ))}
        </fieldset>
        <div className="space-y-1.5"><Label htmlFor="ag-m">Mensagem ao transferir para uma pessoa</Label><Textarea id="ag-m" rows={2} value={v.handoff_message} onChange={(e) => setV({ ...v, handoff_message: e.target.value })} /></div>
        <Button type="submit" disabled={save.isPending}>Salvar configuração</Button>
      </form>

      <section>
        <h3 className="mb-2 text-base font-black">Log do agente</h3>
        {logs.isLoading ? <Skeleton className="h-24 w-full" /> : (logs.data ?? []).length === 0 ? (
          <p className="rounded-md border border-dashed p-4 text-sm text-muted-foreground">Nenhuma ação registrada ainda. Cada ação da IA, de você ao assumir uma conversa e do sistema aparece aqui.</p>
        ) : (
          <div className="overflow-x-auto rounded-md border">
            <table className="w-full min-w-[560px] text-sm">
              <thead><tr className="border-b text-left text-[11px] uppercase tracking-wide text-muted-foreground"><th className="px-3 py-2 font-medium">Quando</th><th className="py-2 font-medium">Quem</th><th className="py-2 font-medium">Ação</th><th className="px-3 py-2 font-medium">Resultado</th></tr></thead>
              <tbody>
                {logs.data!.map((l) => (
                  <tr key={l.id} className="border-b last:border-0">
                    <td className="px-3 py-1.5 tabular text-xs">{new Date(l.created_at).toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' })}</td>
                    <td className="py-1.5 font-semibold">{{ ia: 'IA', humano: 'Você', sistema: 'Sistema' }[l.actor]}</td>
                    <td className="py-1.5">{l.action.replace(/_/g, ' ')}</td>
                    <td className="px-3 py-1.5 text-muted-foreground">{l.result ?? '—'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </div>
  )
}

function WhatsAppTab() {
  const last = useQuery({
    queryKey: ['wa-last-event'],
    queryFn: async () => {
      const [inb, out] = await Promise.all([
        supabase.from('messages').select('created_at').eq('direction', 'in').order('created_at', { ascending: false }).limit(1),
        supabase.from('messages').select('created_at, status').eq('direction', 'out').order('created_at', { ascending: false }).limit(1),
      ])
      return { inbound: (inb.data?.[0]?.created_at as string | undefined) ?? null, outbound: (out.data?.[0]?.created_at as string | undefined) ?? null }
    },
  })
  const fmt = (iso: string | null | undefined) => (iso ? new Date(iso).toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' }) : 'nenhum ainda')
  return (
    <div className="max-w-3xl space-y-4 text-sm">
      <dl className="max-w-xl space-y-2 rounded-md border p-3">
        <div className="flex justify-between gap-3"><dt className="text-muted-foreground">Última mensagem recebida (webhook)</dt><dd className="font-semibold tabular">{fmt(last.data?.inbound)}</dd></div>
        <div className="flex justify-between gap-3"><dt className="text-muted-foreground">Última mensagem enviada</dt><dd className="font-semibold tabular">{fmt(last.data?.outbound)}</dd></div>
      </dl>
      <AgentTemplatesStatus />
      <p className="text-muted-foreground">Os templates abaixo vêm da Meta. Clique em <strong>Sincronizar</strong> para atualizar a lista e o status de aprovação.</p>
      <div className="overflow-hidden rounded-md border">
      <Suspense fallback={<Skeleton className="h-48 w-full" />}>
        <div className="h-[34rem]"><TemplatesPanel /></div>
      </Suspense>
      </div>
    </div>
  )
}

function DataTab() {
  const toast = useToast()
  async function exportOrders() {
    const { data, error } = await supabase.from('orders').select('*, contact:contacts(name,wa_id)').order('created_at', { ascending: false }).limit(10000)
    if (error) return toast('error', error.message)
    const { data: fins } = await supabase.from('order_financials').select('*').limit(10000)
    const fin = new Map((fins ?? []).map((f) => [f.order_id as string, f]))
    downloadCsv('pedidos.csv', ['Nº', 'Cliente', 'Telefone', 'Título', 'Etapa', 'Pagamento', 'Total', 'Custo', 'Lucro líquido', 'Origem', 'Criado em'],
      (data as Record<string, any>[]).map((o) => [o.number, o.contact?.name ?? '', o.contact?.wa_id ?? '', o.title, o.stage, o.payment_status, fin.get(o.id)?.total ?? 0, fin.get(o.id)?.cost ?? 0, fin.get(o.id)?.net_profit ?? 0, o.origin_label ?? 'Orgânico', o.created_at]))
  }
  async function exportContacts() {
    const { data, error } = await supabase.from('contacts').select('*').limit(20000)
    if (error) return toast('error', error.message)
    downloadCsv('contatos-completo.csv', ['Nome', 'Telefone', 'Empresa', 'Segmento', 'E-mail', 'CPF/CNPJ', 'Endereço', 'Consentimento', 'Data do consentimento', 'Origem', 'Criado em'],
      (data as Record<string, any>[]).map((c) => [c.name ?? '', c.wa_id, c.company ?? '', c.segment ?? '', c.email ?? '', c.document ?? '', c.address ?? '', c.marketing_consent, c.marketing_consent_at ?? '', c.first_referral?.headline ?? 'Orgânico', c.created_at]))
  }
  async function exportMessages() {
    const { data, error } = await supabase.from('messages').select('created_at,direction,type,body,status, conversation:conversations(contact:contacts(wa_id))').order('created_at').limit(50000)
    if (error) return toast('error', error.message)
    downloadCsv('mensagens.csv', ['Data', 'Telefone', 'Direção', 'Tipo', 'Texto', 'Status'], (data as Record<string, any>[]).map((m) => [m.created_at, m.conversation?.contact?.wa_id ?? '', m.direction === 'in' ? 'Recebida' : 'Enviada', m.type, m.body ?? '', m.status ?? '']))
  }
  return (
    <div className="max-w-xl space-y-4 text-sm">
      <p className="text-muted-foreground">Baixe seus dados em planilha (CSV, abre no Excel). Faça isso de tempos em tempos como cópia de segurança.</p>
      <div className="flex flex-wrap gap-2">
        <Button variant="outline" onClick={exportOrders}><Download className="h-4 w-4" /> Pedidos</Button>
        <Button variant="outline" onClick={exportContacts}><Download className="h-4 w-4" /> Contatos</Button>
        <Button variant="outline" onClick={exportMessages}><Download className="h-4 w-4" /> Mensagens</Button>
      </div>
      <p className="rounded-md border border-brand-yellow bg-brand-yellow/20 p-3">
        <strong>Backup do banco:</strong> o Supabase faz cópias automáticas diárias nos planos pagos (Pro). No plano gratuito, use as exportações acima e confira em Supabase &gt; Database &gt; Backups.
      </p>
    </div>
  )
}

export default function Settings() {
  return (
    <div className="flex h-full flex-col">
      <header className="border-b px-4 py-3">
        <h1 className="text-xl font-black">Configurações</h1>
      </header>
      <Tabs defaultValue="empresa" className="flex min-h-0 flex-1 flex-col">
        <TabsList>
          <TabsTrigger value="empresa">Empresa</TabsTrigger>
          <TabsTrigger value="precos">Preços</TabsTrigger>
          <TabsTrigger value="kanban">Kanban</TabsTrigger>
          <TabsTrigger value="respostas">Respostas rápidas</TabsTrigger>
          <TabsTrigger value="etiquetas">Etiquetas</TabsTrigger>
          <TabsTrigger value="prazos">Prazos e feriados</TabsTrigger>
          <TabsTrigger value="metas">Metas</TabsTrigger>
          <TabsTrigger value="whatsapp">WhatsApp e templates</TabsTrigger>
          <TabsTrigger value="agente">Agente de IA</TabsTrigger>
          <TabsTrigger value="conhecimento">Conhecimento</TabsTrigger>
          <TabsTrigger value="dados">Dados</TabsTrigger>
        </TabsList>
        <TabsContent value="empresa"><CompanyTab /></TabsContent>
        <TabsContent value="precos"><PricingTab /></TabsContent>
        <TabsContent value="kanban"><KanbanTab /></TabsContent>
        <TabsContent value="respostas"><QuickRepliesTab /></TabsContent>
        <TabsContent value="etiquetas"><LabelsTab /></TabsContent>
        <TabsContent value="prazos"><HolidaysTab /></TabsContent>
        <TabsContent value="metas"><GoalsTab /></TabsContent>
        <TabsContent value="whatsapp"><WhatsAppTab /></TabsContent>
        <TabsContent value="agente"><AgentTab /></TabsContent>
        <TabsContent value="conhecimento"><Suspense fallback={<Skeleton className="h-40 w-full" />}><KnowledgeTab /></Suspense></TabsContent>
        <TabsContent value="dados"><DataTab /></TabsContent>
      </Tabs>
    </div>
  )
}
