import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Plus, Trash2 } from 'lucide-react'
import { useState } from 'react'
import { SkuBadge } from '@/components/SkuBadge'
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

/** Escolhe uma linha do catálogo para pedido ou kit. Só aparece o que tem SKU e é vendável. */
export function ProductPicker({ onPick }: { onPick: (p: Product) => void }) {
  const [q, setQ] = useState('')
  const { data } = useQuery({
    queryKey: ['product-pick', q],
    enabled: q.trim().length >= 2,
    queryFn: async () => {
      const t = q.trim().replace(/[%,()]/g, ' ')
      const { data, error } = await supabase.from('products_priced').select('*').eq('active', true).eq('vendavel', true).not('sku', 'is', null)
        .or(`description.ilike.%${t}%,sku.ilike.%${t}%,category.ilike.%${t}%`).order('description').limit(8)
      if (error) throw error
      return data as Product[]
    },
  })
  return (
    <div>
      <Input aria-label="Buscar produto do catálogo" placeholder="Buscar produto do catálogo (SKU ou nome)" value={q} onChange={(e) => setQ(e.target.value)} />
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
                <span className="truncate"><span className="font-mono text-xs font-bold">{p.sku}</span> {p.category ? `${p.category} · ` : ''}{p.description}{p.colors ? ` · ${p.colors}` : ''}{p.qty ? ` · ${p.qty} un` : ''}{p.size && !/^0\s*x\s*0$/i.test(p.size) ? ` · ${p.size}` : ''}</span>
                <span className="tabular text-xs text-muted-foreground" title="Custo (privado)">{formatBRL(p.cost)}</span>
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}

/** Preço do kit pelos SKUs dele, calculado no banco (calcular_preco). Nunca digitado à mão. */
function useKitPreco(kitId: string | undefined) {
  return useQuery({
    queryKey: ['kit-preco', kitId],
    enabled: !!kitId,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('kit_preco', { p_kit: kitId! })
      if (error) throw error
      return data as { preco: number; itens_sem_sku: number; abaixo_do_piso_conjunto: boolean }
    },
  })
}

function KitCard({ kit: k, onEdit, margin }: { kit: Kit & { items: KitItem[] }; onEdit: () => void; margin: (price: number, cost: number) => { net: number; pct: number } }) {
  const { data: kp } = useKitPreco(k.id)
  const c = k.items.reduce((n, i) => n + i.qty * i.unit_cost, 0)
  const preco = kp?.preco ?? 0
  const mm = margin(preco, c)
  return (
    <article className="rounded-md border bg-card p-4">
      <div className="flex items-start justify-between gap-2">
        <h2 className="text-base font-black">{k.name}</h2>
        {k.segment && <Badge className="bg-brand-cyan/20 text-ink">{SEGMENTS.find((s) => s.value === k.segment)?.label}</Badge>}
      </div>
      {k.description && <p className="mt-1 text-sm text-muted-foreground">{k.description}</p>}
      <ul className="mt-2 space-y-0.5 text-sm">
        {k.items.slice(0, 5).map((i) => <li key={i.id} className="flex items-center gap-2">{i.qty}x {i.description} <SkuBadge sku={i.sku} /></li>)}
        {k.items.length > 5 && <li className="text-xs text-muted-foreground">+{k.items.length - 5} itens</li>}
        {k.items.length === 0 && <li className="text-xs text-muted-foreground">Sem itens. Monte a composição.</li>}
      </ul>
      {kp && kp.itens_sem_sku > 0 && <p className="mt-2 text-xs font-semibold text-brand-red">{kp.itens_sem_sku} item(ns) sem SKU válido ficam fora do preço. Edite o kit.</p>}
      <dl className="mt-3 grid grid-cols-3 gap-2 border-t pt-3 text-sm">
        <div><dt className="text-[11px] uppercase text-muted-foreground">Custo</dt><dd className="font-bold tabular">{formatBRL(c)}</dd></div>
        <div><dt className="text-[11px] uppercase text-muted-foreground" title="Calculado por calcular_preco a partir dos SKUs">Preço</dt><dd className="font-black tabular">{kp ? formatBRL(preco) : '…'}</dd></div>
        <div><dt className="text-[11px] uppercase text-muted-foreground">Margem</dt><dd className={`font-bold tabular ${mm.net < 0 ? 'text-brand-red' : ''}`}>{kp ? formatPct(mm.pct, 0) : '…'}</dd></div>
      </dl>
      <Button className="mt-3 w-full" variant="outline" size="sm" onClick={onEdit}>Editar kit</Button>
    </article>
  )
}

export function KitsTab() {
  const qc = useQueryClient()
  const toast = useToast()
  const { data: kits, isLoading } = useKits()
  const { data: settings } = useSettings()
  const rules = settings?.pricing ?? DEFAULT_PRICING
  const [editing, setEditing] = useState<{ id?: string; name: string; segment: string; description: string; items: { description: string; qty: number; unit_cost: number; product_id: string | null; sku: string | null }[] } | null>(null)
  const [confirm, setConfirm] = useState(false)

  const margin = (price: number, cost: number) => {
    const net = price * (1 - (rules.tax_pct + rules.payment_fee_pct) / 100) - cost
    return { net, pct: price > 0 ? (net / price) * 100 : 0 }
  }

  const save = useMutation({
    mutationFn: async (k: NonNullable<typeof editing>) => {
      if (k.items.some((i) => !i.sku)) throw new Error('Todo item do kit precisa de SKU. Escolha os itens pela busca do catálogo.')
      const row = { name: k.name.trim(), segment: k.segment || null, description: k.description.trim() || null }
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
        const { error } = await supabase.from('kit_items').insert(k.items.map((i) => ({ kit_id: id, product_id: i.product_id, sku: i.sku, description: i.description, qty: i.qty, unit_cost: i.unit_cost })))
        if (error) throw new Error(error.message)
      }
      // o preço guardado no kit acompanha o cálculo do banco (calcular_preco), não um valor digitado
      const { data: kp } = await supabase.rpc('kit_preco', { p_kit: id! })
      if (kp) await supabase.from('kits').update({ price: (kp as { preco: number }).preco }).eq('id', id!)
    },
    onSuccess: () => {
      toast('ok', 'Kit salvo.')
      qc.invalidateQueries({ queryKey: ['kit-preco'] })
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

  return (
    <div className="min-h-0 flex-1 overflow-y-auto p-4">
      <div className="mb-3 flex justify-end">
        <Button size="sm" onClick={() => setEditing({ name: '', segment: '', description: '', items: [] })}><Plus className="h-4 w-4" /> Novo kit</Button>
      </div>
      {(kits ?? []).length === 0 ? (
        <EmptyState icon={Layers} title="Nenhum kit ainda" action={<Button onClick={() => seed.mutate()} disabled={seed.isPending}>Criar os 4 kits padrão</Button>}>
          Kits prontos (Barbearia, Delivery, Loja e Lançamento) agilizam o orçamento. Crie os modelos e monte a composição de cada um.
        </EmptyState>
      ) : (
        <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
          {kits!.map((k) => {
            return <KitCard key={k.id} kit={k} onEdit={() => setEditing({ id: k.id, name: k.name, segment: k.segment ?? '', description: k.description ?? '', items: k.items.map((i) => ({ description: i.description, qty: i.qty, unit_cost: i.unit_cost, product_id: i.product_id, sku: i.sku })) })} margin={margin} />
          })}
        </div>
      )}
      {editing && (
        <Sheet open onOpenChange={(o) => !o && setEditing(null)} title={editing.id ? 'Editar kit' : 'Novo kit'} description="O kit é uma lista de SKUs. O preço é calculado pelo banco a partir deles, com a trava de lucro.">
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
              <div className="space-y-1.5"><Label>Preço do kit</Label><p className="flex h-10 items-center rounded-md border bg-secondary/40 px-3 text-xs text-muted-foreground">Calculado pelos SKUs (calcular_preco)</p></div>
            </div>
            <div className="space-y-1.5"><Label htmlFor="k-desc">Descrição</Label><Textarea id="k-desc" rows={2} value={editing.description} onChange={(e) => setEditing({ ...editing, description: e.target.value })} /></div>

            <section className="space-y-2">
              <h3 className="text-xs font-bold uppercase tracking-wide">Composição</h3>
              <ProductPicker onPick={(p) => setEditing({ ...editing, items: [...editing.items, { description: `${p.category ?? ''} ${p.description} ${p.colors ?? ''} (${p.qty ?? 1} un)`.replace(/\s+/g, ' ').trim(), qty: 1, unit_cost: p.cost, product_id: p.id, sku: p.sku }] })} />
              <ul className="space-y-1.5">
                {editing.items.map((i, idx) => (
                  <li key={idx} className="grid grid-cols-[1fr_72px_96px_44px] items-center gap-2">
                    <span className="flex min-w-0 flex-col gap-1 text-sm"><SkuBadge sku={i.sku} className="w-fit" /><span className="truncate">{i.description}</span></span>
                    <Input aria-label="Quantidade" type="number" min="1" value={i.qty} onChange={(e) => setEditing({ ...editing, items: editing.items.map((x, n) => (n === idx ? { ...x, qty: Math.max(1, Number(e.target.value) || 1) } : x)) })} />
                    <Input aria-label="Custo unitário" inputMode="decimal" value={String(i.unit_cost).replace('.', ',')} onChange={(e) => setEditing({ ...editing, items: editing.items.map((x, n) => (n === idx ? { ...x, unit_cost: parseMoney(e.target.value) } : x)) })} />
                    <Button variant="ghost" size="icon" aria-label="Remover item" onClick={() => setEditing({ ...editing, items: editing.items.filter((_, n) => n !== idx) })}><Trash2 className="h-4 w-4" /></Button>
                  </li>
                ))}
              </ul>
            </section>

            <dl className="grid grid-cols-2 gap-2 rounded-md border p-3 text-sm">
              <div><dt className="text-[11px] uppercase text-muted-foreground">Custo total (privado)</dt><dd className="font-bold tabular">{formatBRL(cost)}</dd></div>
              <div><dt className="text-[11px] uppercase text-muted-foreground">Preço de venda</dt><dd className="font-bold">Depois de salvar</dd></div>
            </dl>
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
