import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Plus, Trash2 } from 'lucide-react'
import { useState } from 'react'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { EmptyState } from '@/components/ui/empty-state'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Modal, Sheet } from '@/components/ui/sheet'
import { Select } from '@/components/ui/select'
import { Skeleton } from '@/components/ui/skeleton'
import { Textarea } from '@/components/ui/textarea'
import { useToast } from '@/components/ui/toast'
import { useSettings } from '@/hooks/orders'
import { formatBRL, formatPct, parseMoney } from '@/lib/money'
import { DEFAULT_PRICING } from '@/lib/pricing'
import { supabase } from '@/lib/supabase'
import type { Kit, KitItem, Product } from '@/lib/types'
import { Layers } from 'lucide-react'

const SEGMENTS: { value: NonNullable<Kit['segment']>; label: string }[] = [
  { value: 'barbearia', label: 'Barbearia' },
  { value: 'delivery', label: 'Delivery' },
  { value: 'loja', label: 'Loja' },
  { value: 'lancamento', label: 'Lançamento' },
  { value: 'outro', label: 'Outro' },
]

function useKits() {
  return useQuery({
    queryKey: ['kits'],
    queryFn: async () => {
      const [kits, items] = await Promise.all([supabase.from('kits').select('*').order('name'), supabase.from('kit_items').select('*')])
      if (kits.error) throw kits.error
      if (items.error) throw items.error
      return (kits.data as Kit[]).map((k) => ({ ...k, items: (items.data as KitItem[]).filter((i) => i.kit_id === k.id) }))
    },
  })
}

export function ProductPicker({ onPick }: { onPick: (p: Product) => void }) {
  const [q, setQ] = useState('')
  const { data } = useQuery({
    queryKey: ['product-pick', q],
    enabled: q.trim().length >= 2,
    queryFn: async () => {
      const t = q.trim().replace(/[%,()]/g, ' ')
      const { data, error } = await supabase.from('products_priced').select('*').or(`description.ilike.%${t}%,code.ilike.%${t}%`).limit(6)
      if (error) throw error
      return data as Product[]
    },
  })
  return (
    <div>
      <Input aria-label="Buscar produto do catálogo" placeholder="Buscar produto do catálogo (código ou nome)" value={q} onChange={(e) => setQ(e.target.value)} />
      {(data ?? []).length > 0 && (
        <ul className="mt-1 overflow-hidden rounded-md border">
          {data!.map((p) => (
            <li key={p.id}>
              <button
                className="flex min-h-11 w-full items-center justify-between gap-2 px-3 py-1.5 text-left text-sm hover:bg-secondary md:min-h-9"
                onClick={() => {
                  onPick(p)
                  setQ('')
                }}
              >
                <span className="truncate"><span className="font-mono text-xs">{p.code}</span> {p.description}{p.grammage ? ` · ${p.grammage} g` : ''}{p.qty ? ` · ${p.qty} un` : ''}{p.size ? ` · ${p.size}` : ''}{p.lead_days ? ` · ${p.lead_days} d` : ''}</span>
                <span className="tabular">{formatBRL(p.cost)}</span>
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}

export function KitsTab() {
  const qc = useQueryClient()
  const toast = useToast()
  const { data: kits, isLoading } = useKits()
  const { data: settings } = useSettings()
  const rules = settings?.pricing ?? DEFAULT_PRICING
  const [editing, setEditing] = useState<{ id?: string; name: string; segment: string; description: string; price: string; items: { description: string; qty: number; unit_cost: number; product_id: string | null }[] } | null>(null)
  const [confirm, setConfirm] = useState(false)

  const margin = (price: number, cost: number) => {
    const net = price * (1 - (rules.tax_pct + rules.payment_fee_pct) / 100) - cost
    return { net, pct: price > 0 ? (net / price) * 100 : 0 }
  }

  const save = useMutation({
    mutationFn: async (k: NonNullable<typeof editing>) => {
      const row = { name: k.name.trim(), segment: k.segment || null, description: k.description.trim() || null, price: parseMoney(k.price) }
      let id = k.id
      if (id) {
        const { error } = await supabase.from('kits').update(row).eq('id', id)
        if (error) throw new Error(error.message)
        const { error: dErr } = await supabase.from('kit_items').delete().eq('kit_id', id)
        if (dErr) throw new Error(dErr.message)
      } else {
        const { data, error } = await supabase.from('kits').insert(row).select('id').single()
        if (error) throw new Error(error.message)
        id = data.id as string
      }
      if (k.items.length) {
        const { error } = await supabase.from('kit_items').insert(k.items.map((i) => ({ kit_id: id, product_id: i.product_id, description: i.description, qty: i.qty, unit_cost: i.unit_cost })))
        if (error) throw new Error(error.message)
      }
    },
    onSuccess: () => {
      toast('ok', 'Kit salvo.')
      setEditing(null)
      setConfirm(false)
      qc.invalidateQueries({ queryKey: ['kits'] })
    },
    onError: (e: Error) => toast('error', e.message),
  })

  const seed = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.from('kits').insert(SEGMENTS.slice(0, 4).map((s) => ({ name: `Kit ${s.label}`, segment: s.value, price: 0 })))
      if (error) throw new Error(error.message)
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['kits'] }),
    onError: (e: Error) => toast('error', e.message),
  })

  if (isLoading) return <div className="grid gap-3 p-4 md:grid-cols-2"><Skeleton className="h-40" /><Skeleton className="h-40" /></div>

  const original = kits?.find((k) => k.id === editing?.id)
  const cost = editing ? editing.items.reduce((n, i) => n + i.qty * i.unit_cost, 0) : 0
  const m = editing ? margin(parseMoney(editing.price), cost) : null

  return (
    <div className="min-h-0 flex-1 overflow-y-auto p-4">
      <div className="mb-3 flex justify-end">
        <Button size="sm" onClick={() => setEditing({ name: '', segment: '', description: '', price: '', items: [] })}><Plus className="h-4 w-4" /> Novo kit</Button>
      </div>
      {(kits ?? []).length === 0 ? (
        <EmptyState icon={Layers} title="Nenhum kit ainda" action={<Button onClick={() => seed.mutate()} disabled={seed.isPending}>Criar os 4 kits padrão</Button>}>
          Kits prontos (Barbearia, Delivery, Loja e Lançamento) agilizam o orçamento. Crie os modelos e monte a composição de cada um.
        </EmptyState>
      ) : (
        <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
          {kits!.map((k) => {
            const c = k.items.reduce((n, i) => n + i.qty * i.unit_cost, 0)
            const mm = margin(k.price, c)
            return (
              <article key={k.id} className="rounded-md border bg-card p-4">
                <div className="flex items-start justify-between gap-2">
                  <h2 className="text-base font-black">{k.name}</h2>
                  {k.segment && <Badge className="bg-brand-cyan/20 text-ink">{SEGMENTS.find((s) => s.value === k.segment)?.label}</Badge>}
                </div>
                {k.description && <p className="mt-1 text-sm text-muted-foreground">{k.description}</p>}
                <ul className="mt-2 space-y-0.5 text-sm">
                  {k.items.slice(0, 5).map((i) => <li key={i.id}>{i.qty}x {i.description}</li>)}
                  {k.items.length > 5 && <li className="text-xs text-muted-foreground">+{k.items.length - 5} itens</li>}
                  {k.items.length === 0 && <li className="text-xs text-muted-foreground">Sem itens. Monte a composição.</li>}
                </ul>
                <dl className="mt-3 grid grid-cols-3 gap-2 border-t pt-3 text-sm">
                  <div><dt className="text-[11px] uppercase text-muted-foreground">Custo</dt><dd className="font-bold tabular">{formatBRL(c)}</dd></div>
                  <div><dt className="text-[11px] uppercase text-muted-foreground">Preço</dt><dd className="font-black tabular">{formatBRL(k.price)}</dd></div>
                  <div><dt className="text-[11px] uppercase text-muted-foreground">Margem</dt><dd className={`font-bold tabular ${mm.net < 0 ? 'text-brand-red' : ''}`}>{formatPct(mm.pct, 0)}</dd></div>
                </dl>
                <Button className="mt-3 w-full" variant="outline" size="sm" onClick={() => setEditing({ id: k.id, name: k.name, segment: k.segment ?? '', description: k.description ?? '', price: String(k.price).replace('.', ','), items: k.items.map((i) => ({ description: i.description, qty: i.qty, unit_cost: i.unit_cost, product_id: i.product_id })) })}>
                  Editar kit
                </Button>
              </article>
            )
          })}
        </div>
      )}

      {editing && (
        <Sheet open onOpenChange={(o) => !o && setEditing(null)} title={editing.id ? 'Editar kit' : 'Novo kit'} description="O preço do kit é o que o cliente paga. Custo e margem são calculados a partir dos itens.">
          <div className="min-h-0 flex-1 space-y-4 overflow-y-auto p-4">
            <div className="space-y-1.5"><Label htmlFor="k-name">Nome</Label><Input id="k-name" value={editing.name} onChange={(e) => setEditing({ ...editing, name: e.target.value })} /></div>
            <div className="grid grid-cols-2 gap-2">
              <div className="space-y-1.5">
                <Label htmlFor="k-seg">Segmento</Label>
                <Select id="k-seg" value={editing.segment} onChange={(e) => setEditing({ ...editing, segment: e.target.value })}>
                  <option value="">Sem segmento</option>
                  {SEGMENTS.map((s) => <option key={s.value} value={s.value}>{s.label}</option>)}
                </Select>
              </div>
              <div className="space-y-1.5"><Label htmlFor="k-price">Preço do kit (R$)</Label><Input id="k-price" inputMode="decimal" value={editing.price} onChange={(e) => setEditing({ ...editing, price: e.target.value })} /></div>
            </div>
            <div className="space-y-1.5"><Label htmlFor="k-desc">Descrição</Label><Textarea id="k-desc" rows={2} value={editing.description} onChange={(e) => setEditing({ ...editing, description: e.target.value })} /></div>

            <section className="space-y-2">
              <h3 className="text-xs font-bold uppercase tracking-wide">Composição</h3>
              <ProductPicker onPick={(p) => setEditing({ ...editing, items: [...editing.items, { description: p.description, qty: 1, unit_cost: p.cost, product_id: p.id }] })} />
              <ul className="space-y-1.5">
                {editing.items.map((i, idx) => (
                  <li key={idx} className="grid grid-cols-[1fr_72px_96px_44px] items-center gap-2">
                    <Input aria-label="Descrição" value={i.description} onChange={(e) => setEditing({ ...editing, items: editing.items.map((x, n) => (n === idx ? { ...x, description: e.target.value } : x)) })} />
                    <Input aria-label="Quantidade" type="number" min="1" value={i.qty} onChange={(e) => setEditing({ ...editing, items: editing.items.map((x, n) => (n === idx ? { ...x, qty: Math.max(1, Number(e.target.value) || 1) } : x)) })} />
                    <Input aria-label="Custo unitário" inputMode="decimal" value={String(i.unit_cost).replace('.', ',')} onChange={(e) => setEditing({ ...editing, items: editing.items.map((x, n) => (n === idx ? { ...x, unit_cost: parseMoney(e.target.value) } : x)) })} />
                    <Button variant="ghost" size="icon" aria-label="Remover item" onClick={() => setEditing({ ...editing, items: editing.items.filter((_, n) => n !== idx) })}><Trash2 className="h-4 w-4" /></Button>
                  </li>
                ))}
              </ul>
              <button className="min-h-11 text-sm font-semibold text-link underline md:min-h-0" onClick={() => setEditing({ ...editing, items: [...editing.items, { description: '', qty: 1, unit_cost: 0, product_id: null }] })}>
                Adicionar item sem catálogo
              </button>
            </section>

            <dl className="grid grid-cols-3 gap-2 rounded-md border p-3 text-sm">
              <div><dt className="text-[11px] uppercase text-muted-foreground">Custo total</dt><dd className="font-bold tabular">{formatBRL(cost)}</dd></div>
              <div><dt className="text-[11px] uppercase text-muted-foreground">Lucro líquido</dt><dd className={`font-bold tabular ${m!.net < 0 ? 'text-brand-red' : ''}`}>{formatBRL(m!.net)}</dd></div>
              <div><dt className="text-[11px] uppercase text-muted-foreground">Margem</dt><dd className="font-bold tabular">{formatPct(m!.pct, 0)}</dd></div>
            </dl>
            {m!.net < rules.min_net_profit && parseMoney(editing.price) > 0 && (
              <p role="alert" className="rounded-md border border-brand-red/40 bg-brand-red/5 p-2.5 text-sm">Lucro líquido abaixo do mínimo por pedido ({formatBRL(rules.min_net_profit)}).</p>
            )}
          </div>
          <footer className="flex justify-end gap-2 border-t p-3">
            <Button variant="outline" onClick={() => setEditing(null)}>Cancelar</Button>
            <Button disabled={!editing.name.trim() || save.isPending} onClick={() => (editing.id ? setConfirm(true) : save.mutate(editing))}>{save.isPending ? 'Salvando…' : 'Salvar kit'}</Button>
          </footer>
        </Sheet>
      )}

      <Modal open={confirm} onOpenChange={setConfirm} title="Confirmar alteração do kit?" description="Kits alimentam orçamentos. Confira o antes e o depois.">
        {editing && original && (
          <dl className="mb-4 space-y-1 text-sm">
            <div className="flex justify-between"><dt className="text-muted-foreground">Preço</dt><dd className="tabular">{formatBRL(original.price)} → <strong>{formatBRL(parseMoney(editing.price))}</strong></dd></div>
            <div className="flex justify-between"><dt className="text-muted-foreground">Custo</dt><dd className="tabular">{formatBRL(original.items.reduce((n, i) => n + i.qty * i.unit_cost, 0))} → <strong>{formatBRL(cost)}</strong></dd></div>
            <div className="flex justify-between"><dt className="text-muted-foreground">Itens</dt><dd className="tabular">{original.items.length} → <strong>{editing.items.length}</strong></dd></div>
          </dl>
        )}
        <div className="flex justify-end gap-2">
          <Button variant="outline" onClick={() => setConfirm(false)}>Voltar</Button>
          <Button onClick={() => editing && save.mutate(editing)} disabled={save.isPending}>Confirmar</Button>
        </div>
      </Modal>
    </div>
  )
}
