import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { ChevronLeft, ChevronRight, FileUp, Package, Plus, Search } from 'lucide-react'
import { useEffect, useRef, useState } from 'react'
import { Button } from '@/components/ui/button'
import { EmptyState, ErrorState } from '@/components/ui/empty-state'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Modal } from '@/components/ui/sheet'
import { Select } from '@/components/ui/select'
import { Skeleton } from '@/components/ui/skeleton'
import { useToast } from '@/components/ui/toast'
import { readTable } from '@/lib/spreadsheet'
import { ImportDialog } from './ImportDialog'
import { formatBRL, formatNumber, parseMoney } from '@/lib/money'
import { supabase } from '@/lib/supabase'
import type { Product } from '@/lib/types'

const PAGE = 25

function useDebounced<T>(value: T, ms = 300): T {
  const [v, setV] = useState(value)
  useEffect(() => {
    const id = setTimeout(() => setV(value), ms)
    return () => clearTimeout(id)
  }, [value, ms])
  return v
}

/** Busca e paginação no servidor: o catálogo do fornecedor pode ter milhares de itens. */
export function useProducts(search: string, category: string, page: number) {
  return useQuery({
    queryKey: ['products', search, category, page],
    placeholderData: (prev) => prev,
    queryFn: async () => {
      let q = supabase.from('products_priced').select('*', { count: 'exact' }).eq('active', true).order('description').range(page * PAGE, page * PAGE + PAGE - 1)
      const t = search.trim().replace(/[%,()]/g, ' ')
      if (t) q = q.or(`description.ilike.%${t}%,code.ilike.%${t}%`)
      if (category) q = q.eq('category', category)
      const { data, error, count } = await q
      if (error) throw error
      return { rows: data as Product[], total: count ?? 0 }
    },
  })
}

function useCategories() {
  return useQuery({
    queryKey: ['product-categories'],
    staleTime: 60_000,
    queryFn: async () => {
      const { data, error } = await supabase.from('product_categories').select('category').order('category').limit(1000)
      if (error) throw error
      return (data as { category: string }[]).map((r) => r.category)
    },
  })
}

export function ProductsTab() {
  const qc = useQueryClient()
  const toast = useToast()
  const [search, setSearch] = useState('')
  const [category, setCategory] = useState('')
  const [page, setPage] = useState(0)
  const debounced = useDebounced(search)
  const { data, isLoading, error, refetch, isFetching } = useProducts(debounced, category, page)
  const { data: categories } = useCategories()
  const file = useRef<HTMLInputElement>(null)
  const [form, setForm] = useState<{ code: string; description: string; category: string; cost: string; price: string } | null>(null)

  useEffect(() => setPage(0), [debounced, category])

  const [sheet, setSheet] = useState<{ rows: string[][]; name: string } | null>(null)
  const [reading, setReading] = useState(false)

  async function pickFile(f: File) {
    setReading(true)
    try {
      const rows = await readTable(f)
      if (rows.length < 2) throw new Error('O arquivo está vazio.')
      setSheet({ rows, name: f.name })
    } catch (e) {
      toast('error', e instanceof Error ? e.message : 'Não foi possível ler o arquivo.')
    } finally {
      setReading(false)
    }
  }

  const saveOne = useMutation({
    mutationFn: async (f: NonNullable<typeof form>) => {
      const { error } = await supabase.from('products').upsert(
        { code: f.code.trim(), description: f.description.trim(), category: f.category.trim() || null, cost: parseMoney(f.cost), suggested_price: parseMoney(f.price), active: true },
        { onConflict: 'code' },
      )
      if (error) throw new Error(error.message)
    },
    onSuccess: () => {
      setForm(null)
      toast('ok', 'Produto salvo.')
      qc.invalidateQueries({ queryKey: ['products'] })
    },
    onError: (e: Error) => toast('error', e.message),
  })

  const total = data?.total ?? 0
  const pages = Math.max(1, Math.ceil(total / PAGE))

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <div className="space-y-3 border-b px-4 py-3">
        <div className="flex flex-wrap items-center gap-2">
          <div className="relative min-w-52 flex-1">
            <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" aria-hidden />
            <Input className="pl-9" placeholder="Buscar por código ou descrição" aria-label="Buscar produto" value={search} onChange={(e) => setSearch(e.target.value)} />
          </div>
          <Select aria-label="Categoria" className="w-52" value={category} onChange={(e) => setCategory(e.target.value)}>
            <option value="">Todas as categorias</option>
            {(categories ?? []).map((c) => <option key={c} value={c}>{c}</option>)}
          </Select>
          <input ref={file} type="file" accept=".xlsx,.xls,.csv,text/csv" className="sr-only" aria-label="Planilha do catálogo (Excel ou CSV)" onChange={(e) => { const f = e.target.files?.[0]; if (f) void pickFile(f); e.target.value = '' }} />
          <Button variant="outline" size="sm" onClick={() => file.current?.click()} disabled={reading}>
            <FileUp className="h-4 w-4" /> {reading ? 'Lendo…' : 'Importar planilha'}
          </Button>
          <Button size="sm" onClick={() => setForm({ code: '', description: '', category: '', cost: '', price: '' })}><Plus className="h-4 w-4" /> Novo produto</Button>
        </div>
        <p className="text-xs text-muted-foreground">
          Preço sugerido, piso (custo x multiplicador), preço com desconto máximo e lucro líquido estimado vêm do banco e acompanham os parâmetros de Configurações. Importe a planilha do fornecedor em Excel (.xlsx ou .xls) ou CSV: você escolhe quais colunas são código, descrição, custo e preço.
        </p>
      </div>

      <div className="min-h-0 flex-1 overflow-auto">
        {error ? (
          <ErrorState message="Não foi possível carregar o catálogo." onRetry={() => refetch()} />
        ) : isLoading ? (
          <div className="space-y-2 p-4">{[0, 1, 2, 3, 4].map((i) => <Skeleton key={i} className="h-10 w-full" />)}</div>
        ) : total === 0 ? (
          <EmptyState icon={Package} title={debounced || category ? 'Nenhum produto encontrado' : 'Catálogo vazio'}>
            {debounced || category ? 'Tente outro termo ou categoria.' : 'Importe a planilha do fornecedor (ZAP Gráfica, em Excel ou CSV) ou cadastre os produtos um a um.'}
          </EmptyState>
        ) : (
          <table className="w-full min-w-[860px] text-sm">
            <thead className="sticky top-0 bg-background">
              <tr className="border-b text-left text-[11px] uppercase tracking-wide text-muted-foreground">
                <th className="px-4 py-2 font-medium">Código</th>
                <th className="py-2 font-medium">Descrição</th>
                <th className="py-2 text-right font-medium">Custo</th>
                <th className="py-2 text-right font-medium">Preço sugerido</th>
                <th className="py-2 text-right font-medium">Piso</th>
                <th className="py-2 text-right font-medium">Com desc. máx.</th>
                <th className="px-4 py-2 text-right font-medium">Lucro líq. est.</th>
              </tr>
            </thead>
            <tbody className={isFetching ? 'opacity-60' : undefined}>
              {data!.rows.map((p) => (
                <tr key={p.id} className="border-b hover:bg-secondary/50">
                  <td className="px-4 py-2 font-mono text-xs">{p.code}</td>
                  <td className="py-2"><p className="font-semibold">{p.description}</p>{p.category && <p className="text-xs text-muted-foreground">{p.category}</p>}</td>
                  <td className="py-2 text-right tabular">{formatBRL(p.cost)}</td>
                  <td className="py-2 text-right font-bold tabular">{formatBRL(p.suggested_price)}</td>
                  <td className="py-2 text-right tabular">{formatBRL(p.floor_price)}</td>
                  <td className="py-2 text-right tabular">{formatBRL(p.max_discount_price)}</td>
                  <td className={`px-4 py-2 text-right font-semibold tabular ${p.est_net_profit < 0 ? 'text-brand-red' : ''}`}>{formatBRL(p.est_net_profit)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      <footer className="flex items-center justify-between gap-2 border-t px-4 py-2 text-sm">
        <span className="text-muted-foreground tabular">{formatNumber(total)} produto(s)</span>
        <span className="flex items-center gap-2">
          <Button variant="outline" size="icon" aria-label="Página anterior" disabled={page === 0} onClick={() => setPage((p) => p - 1)}><ChevronLeft className="h-4 w-4" /></Button>
          <span className="tabular">Página {page + 1} de {pages}</span>
          <Button variant="outline" size="icon" aria-label="Próxima página" disabled={page + 1 >= pages} onClick={() => setPage((p) => p + 1)}><ChevronRight className="h-4 w-4" /></Button>
        </span>
      </footer>

      {sheet && <ImportDialog rows={sheet.rows} fileName={sheet.name} onClose={() => setSheet(null)} />}

      <Modal open={!!form} onOpenChange={(o) => !o && setForm(null)} title="Produto" description="Se o código já existir, o produto é atualizado.">
        {form && (
          <form
            className="space-y-3"
            onSubmit={(e) => {
              e.preventDefault()
              saveOne.mutate(form)
            }}
          >
            <div className="space-y-1.5"><Label htmlFor="pr-code">Código</Label><Input id="pr-code" required value={form.code} onChange={(e) => setForm({ ...form, code: e.target.value })} /></div>
            <div className="space-y-1.5"><Label htmlFor="pr-desc">Descrição</Label><Input id="pr-desc" required value={form.description} onChange={(e) => setForm({ ...form, description: e.target.value })} /></div>
            <div className="space-y-1.5"><Label htmlFor="pr-cat">Categoria</Label><Input id="pr-cat" value={form.category} onChange={(e) => setForm({ ...form, category: e.target.value })} /></div>
            <div className="grid grid-cols-2 gap-2">
              <div className="space-y-1.5"><Label htmlFor="pr-cost">Custo (R$)</Label><Input id="pr-cost" inputMode="decimal" required value={form.cost} onChange={(e) => setForm({ ...form, cost: e.target.value })} /></div>
              <div className="space-y-1.5"><Label htmlFor="pr-price">Preço sugerido (R$)</Label><Input id="pr-price" inputMode="decimal" required value={form.price} onChange={(e) => setForm({ ...form, price: e.target.value })} /></div>
            </div>
            <div className="flex justify-end gap-2">
              <Button type="button" variant="outline" onClick={() => setForm(null)}>Cancelar</Button>
              <Button type="submit" disabled={saveOne.isPending}>{saveOne.isPending ? 'Salvando…' : 'Salvar produto'}</Button>
            </div>
          </form>
        )}
      </Modal>
    </div>
  )
}
