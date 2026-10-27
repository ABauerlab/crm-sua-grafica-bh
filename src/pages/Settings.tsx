import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
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

export default function Settings() {
  return (
    <div className="flex h-full flex-col">
      <header className="border-b px-4 py-3">
        <h1 className="text-xl font-black">Configurações</h1>
      </header>
      <Tabs defaultValue="precos" className="flex min-h-0 flex-1 flex-col">
        <TabsList>
          <TabsTrigger value="precos">Preços</TabsTrigger>
          <TabsTrigger value="kanban">Kanban</TabsTrigger>
          <TabsTrigger value="whatsapp">WhatsApp</TabsTrigger>
        </TabsList>
        <TabsContent value="precos"><PricingTab /></TabsContent>
        <TabsContent value="kanban"><KanbanTab /></TabsContent>
        <TabsContent value="whatsapp" className="space-y-3 text-sm">
          <p>Templates, status de aprovação e sincronização com a Meta.</p>
          <Button asChild variant="outline"><Link to="/templates">Abrir templates do WhatsApp</Link></Button>
        </TabsContent>
      </Tabs>
    </div>
  )
}
