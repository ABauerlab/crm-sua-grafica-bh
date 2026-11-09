import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { ChevronLeft, ChevronRight, FileUp, Package, Plus, Search } from 'lucide-react'
import { useEffect, useRef, useState } from 'react'
import { Button } from '@/components/ui/button'
import { EmptyState, ErrorState } from '@/components/ui/empty-state'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Modal } from '@/components/ui/sheet'
import { Badge } from '@/components/ui/badge'
import { Select } from '@/components/ui/select'
import { Skeleton } from '@/components/ui/skeleton'
import { useToast } from '@/components/ui/toast'
import { SkuBadge } from '@/components/SkuBadge'
import { extractGrammage, readCatalogFile, type CatalogFile } from '@/lib/spreadsheet'
import { ImportDialog } from './ImportDialog'
import { PlanilhaPrecosImport } from './PlanilhaPrecosImport'
import { formatBRL, formatNumber, parseMoney } from '@/lib/money'
import { supabase } from '@/lib/supabase'
import { STATUS_VENDA_LABELS, type Product, type StatusVenda } from '@/lib/types'

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
export function useProducts(search: string, category: string, page: number, status = '') {
  return useQuery({
    queryKey: ['products', search, category, page, status],
    placeholderData: (prev) => prev,
    queryFn: async () => {
      let q = supabase.from('products_priced').select('*', { count: 'exact' }).eq('active', true).order('description').range(page * PAGE, page * PAGE + PAGE - 1)
      if (status) q = q.eq('status_venda', status)
      const t = search.trim().replace(/[%,()]/g, ' ')
      if (t) q = q.or(`description.ilike.%${t}%,sku.ilike.%${t}%,size.ilike.%${t}%,colors.ilike.%${t}%`)
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

/** Preço de venda de cada linha da página, calculado pelo banco (calcular_preco): planilha oficial e trava de lucro. */
function usePrecosPagina(skus: string[]) {
  return useQuery({
    queryKey: ['catalogo-precos', skus.join(',')],
    enabled: skus.length > 0,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('catalogo_precos', { p_skus: skus })
      if (error) throw error
      return new Map((data as { sku: string; preco_total: number; regra: string; confianca: string; margem_liquida_pct: number; nao_competitivo: boolean }[]).map((r) => [r.sku, r]))
    },
  })
}

const STATUS_TONE: Record<StatusVenda, string> = {
  vender_forte: 'bg-brand-green/15 text-brand-green',
  vender: 'bg-secondary text-ink',
  so_sob_demanda: 'bg-brand-blue/15 text-ink',
  nao_competitivo: 'bg-brand-yellow/30 text-ink',
  nao_vender: 'bg-brand-red/10 text-brand-red',
  sem_sku: 'bg-brand-red/10 text-brand-red',
}

export function ProductsTab() {
  const qc = useQueryClient()
  const toast = useToast()
  const [search, setSearch] = useState('')
  const [category, setCategory] = useState('')
  const [status, setStatus] = useState('')
  const [page, setPage] = useState(0)
  const debounced = useDebounced(search)
  const { data, isLoading, error, refetch, isFetching } = useProducts(debounced, category, page, status)
  const { data: categories } = useCategories()
  const { data: precos } = usePrecosPagina((data?.rows ?? []).filter((p) => p.sku && p.vendavel).map((p) => p.sku!))
  const file = useRef<HTMLInputElement>(null)
  const [form, setForm] = useState<{ sku: string; description: string; category: string; colors: string; weight: string; qty: string; size: string; lead: string; cost: string } | null>(null)

  useEffect(() => setPage(0), [debounced, category, status])

  const [sheet, setSheet] = useState<(CatalogFile & { name: string; file: File }) | null>(null)
  const [reading, setReading] = useState(false)

  async function pickFile(f: File) {
    setReading(true)
    try {
      const r = await readCatalogFile(f)
      if (r.rows.length < 2) throw new Error('O arquivo está vazio.')
      setSheet({ ...r, name: f.name, file: f })
    } catch (e) {
      toast('error', e instanceof Error ? e.message : 'Não foi possível ler o arquivo.')
    } finally {
      setReading(false)
    }
  }

  const saveOne = useMutation({
    mutationFn: async (f: NonNullable<typeof form>) => {
      const row = {
        sku: f.sku.trim() || null,
        descricao: f.description.trim(),
        categoria: f.category.trim() || null,
        cores: f.colors.trim() || null,
        peso_g: f.weight.trim() ? parseMoney(f.weight) : null,
        gramatura_g: extractGrammage(f.description),
        quantidade: f.qty.trim() ? Math.round(parseMoney(f.qty)) : null,
        tamanho_mm: f.size.trim() || null,
        prazo_dias_uteis: f.lead.trim() ? Math.round(parseMoney(f.lead)) : null,
        custo: parseMoney(f.cost),
        active: true,
      }
      if (!row.sku) throw new Error('Informe o SKU. Item sem código não é vendável; para cadastrar depois, use a aba "Sem código".')
      const { error } = await supabase.from('catalogo').upsert(row, { onConflict: 'sku' })
      if (error) throw new Error(error.message)
    },
    onSuccess: () => {
      setForm(null)
      toast('ok', 'Produto salvo.')
      qc.invalidateQueries({ queryKey: ['products'] })
    },
    onError: (e: Error) => toast('error', e.message),
  })

  // Mudou um parâmetro de preço ou a regra da bicicleta: refaz piso, piso duro e cabe_na_bike de todas as linhas, em lotes
  const recalcular = useMutation({
    mutationFn: async () => {
      let depois: string | null = null
      let n = 0
      do {
        const { data, error } = await supabase.rpc('catalogo_recalcular', { p_depois: depois, p_limite: 2000 })
        if (error) throw new Error(error.message)
        const r = data as { processados: number; ultimo: string | null }
        n += r.processados
        depois = r.ultimo
      } while (depois)
      const { data: nc } = await supabase.rpc('catalogo_atualizar_competitividade')
      return { n, naoCompetitivos: Number(nc ?? 0) }
    },
    onSuccess: (r) => {
      toast('ok', `${formatNumber(r.n)} linhas recalculadas. ${formatNumber(r.naoCompetitivos)} item(ns) não competitivo(s).`)
      qc.invalidateQueries({ queryKey: ['products'] })
      qc.invalidateQueries({ queryKey: ['catalogo-precos'] })
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
            <Input className="pl-9" placeholder="Buscar por SKU ou descrição" aria-label="Buscar produto" value={search} onChange={(e) => setSearch(e.target.value)} />
          </div>
          <Select aria-label="Categoria" className="w-52" value={category} onChange={(e) => setCategory(e.target.value)}>
            <option value="">Todas as categorias</option>
            {(categories ?? []).map((c) => <option key={c} value={c}>{c}</option>)}
          </Select>
          <Select aria-label="Status de venda" className="w-44" value={status} onChange={(e) => setStatus(e.target.value)}>
            <option value="">Todos os status</option>
            {(Object.keys(STATUS_VENDA_LABELS) as StatusVenda[]).map((k) => <option key={k} value={k}>{STATUS_VENDA_LABELS[k]}</option>)}
          </Select>
          <input ref={file} type="file" accept=".pdf,.xlsx,.xls,.csv,application/pdf,text/csv" className="sr-only" aria-label="Tabela do fornecedor (PDF, Excel ou CSV)" onChange={(e) => { const f = e.target.files?.[0]; if (f) void pickFile(f); e.target.value = '' }} />
          <Button variant="outline" size="sm" onClick={() => file.current?.click()} disabled={reading}>
            <FileUp className="h-4 w-4" /> {reading ? 'Lendo…' : 'Importar tabela'}
          </Button>
          <PlanilhaPrecosImport />
          <Button variant="outline" size="sm" onClick={() => recalcular.mutate()} disabled={recalcular.isPending} title="Use depois de mudar parâmetros de preço ou a regra da bicicleta">
            {recalcular.isPending ? 'Recalculando…' : 'Recalcular pisos'}
          </Button>
          <Button size="sm" onClick={() => setForm({ sku: '', description: '', category: '', colors: '', weight: '', qty: '', size: '', lead: '', cost: '' })}><Plus className="h-4 w-4" /> Novo produto</Button>
        </div>
        <p className="text-xs text-muted-foreground">
          Cada linha é uma opção fechada de quantidade: o SKU identifica o item exato. O custo é privado (só o dono vê). O <b>preço de venda</b> vem da <b>planilha oficial de preços</b> (botão "Importar planilha de preços"), aplicado por <code>calcular_preco</code> com as travas de lucro; a <b>base de custo</b> só vale para SKU sem preço de planilha.
        </p>
      </div>

      <div className="min-h-0 flex-1 overflow-auto">
        {error ? (
          <ErrorState message="Não foi possível carregar o catálogo." onRetry={() => refetch()} />
        ) : isLoading ? (
          <div className="space-y-2 p-4">{[0, 1, 2, 3, 4].map((i) => <Skeleton key={i} className="h-10 w-full" />)}</div>
        ) : total === 0 ? (
          <EmptyState icon={Package} title={debounced || category || status ? 'Nenhum produto encontrado' : 'Catálogo vazio'}>
            {debounced || category || status ? 'Tente outro termo, categoria ou status.' : 'Importe a tabela do fornecedor (PDF, Excel ou CSV) ou cadastre os produtos um a um.'}
          </EmptyState>
        ) : (
          <table className="w-full min-w-[1360px] text-sm">
            <thead className="sticky top-0 bg-background">
              <tr className="border-b text-left text-[11px] uppercase tracking-wide text-muted-foreground">
                <th className="px-4 py-2 font-medium">SKU</th>
                <th className="py-2 font-medium">Categoria</th>
                <th className="py-2 font-medium">Descrição do serviço</th>
                <th className="py-2 font-medium">Cores</th>
                <th className="py-2 text-right font-medium" title="Peso do pacote em gramas">Peso (g)</th>
                <th className="py-2 text-right font-medium">Gramatura</th>
                <th className="py-2 text-right font-medium">Qtde</th>
                <th className="py-2 pl-4 font-medium" title="Tamanho em milímetros">Tam (mm)</th>
                <th className="py-2 text-right font-medium" title="Prazo bruto do fornecedor, em dias úteis. O +1 de logística só entra no cálculo da data.">Prazo (d.u.)</th>
                <th className="py-2 text-right font-medium">Custo</th>
                <th className="py-2 text-right font-medium" title="Custo x multiplicador da faixa, terminado em ,90. Referência SEM pesquisa de mercado. Não vale para orçamento.">Base de custo (ref.)</th>
                <th className="py-2 text-right font-medium" title="Preço calculado por calcular_preco">Preço de venda</th>
                <th className="py-2 text-right font-medium">Piso</th>
                <th className="py-2 pl-4 font-medium">Status</th>
                <th className="px-4 py-2 text-center font-medium" title="Cabe na bicicleta (peso e maior lado)">Bike</th>
              </tr>
            </thead>
            <tbody className={isFetching ? 'opacity-60' : undefined}>
              {data!.rows.map((p) => {
                const pr = p.sku ? precos?.get(p.sku) : undefined
                return (
                  <tr key={p.id} className="border-b hover:bg-secondary/50">
                    <td className="px-4 py-2"><SkuBadge sku={p.sku} /></td>
                    <td className="py-2 text-xs text-muted-foreground">{p.category ?? '—'}</td>
                    <td className="max-w-sm py-2 font-semibold">{p.description}</td>
                    <td className="py-2">{p.colors ?? '—'}</td>
                    <td className="py-2 text-right tabular">{p.weight === null ? '—' : formatNumber(p.weight)}</td>
                    <td className="py-2 text-right tabular">{p.grammage === null ? '—' : `${p.grammage} g`}</td>
                    <td className="py-2 text-right tabular">{p.qty === null ? '—' : formatNumber(p.qty)}</td>
                    <td className="py-2 pl-4 whitespace-nowrap">{p.size && !/^0\s*x\s*0$/i.test(p.size) ? p.size : '—'}</td>
                    <td className="py-2 text-right tabular">{p.lead_days === null ? '—' : p.lead_days}</td>
                    <td className="py-2 text-right tabular">{formatBRL(p.cost)}</td>
                    <td className="py-2 text-right tabular text-muted-foreground">{formatBRL(p.suggested_price)}</td>
                    <td className="py-2 text-right font-bold tabular" title={pr ? `Regra: ${pr.regra} · confiança ${pr.confianca} · margem ${pr.margem_liquida_pct}%` : undefined}>{pr ? formatBRL(pr.preco_total) : p.vendavel ? '…' : '—'}</td>
                    <td className="py-2 text-right tabular">{p.piso === null ? '—' : formatBRL(p.piso)}</td>
                    <td className="py-2 pl-4"><Badge className={STATUS_TONE[p.status_venda]}>{STATUS_VENDA_LABELS[p.status_venda]}</Badge></td>
                    <td className="px-4 py-2 text-center">{p.cabe_na_bike === null ? '?' : p.cabe_na_bike ? 'Sim' : 'Não'}</td>
                  </tr>
                )
              })}
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

      {sheet && <ImportDialog key={sheet.name} rows={sheet.rows} fileName={sheet.name} file={sheet.file} candidatas={sheet.candidatas} emitidoEm={sheet.emitidoEm} avisos={sheet.avisos} onClose={() => setSheet(null)} />}

      <Modal open={!!form} onOpenChange={(o) => !o && setForm(null)} title="Produto" description="Se o SKU já existir, o produto é atualizado. O preço de venda não é digitado: vem de calcular_preco.">
        {form && (
          <form
            className="space-y-3"
            onSubmit={(e) => {
              e.preventDefault()
              saveOne.mutate(form)
            }}
          >
            <div className="space-y-1.5"><Label htmlFor="pr-code">SKU</Label><Input id="pr-code" required value={form.sku} onChange={(e) => setForm({ ...form, sku: e.target.value })} /></div>
            <div className="space-y-1.5"><Label htmlFor="pr-desc">Descrição</Label><Input id="pr-desc" required value={form.description} onChange={(e) => setForm({ ...form, description: e.target.value })} /></div>
            <div className="space-y-1.5"><Label htmlFor="pr-cat">Categoria</Label><Input id="pr-cat" value={form.category} onChange={(e) => setForm({ ...form, category: e.target.value })} /></div>
            <div className="grid grid-cols-3 gap-2">
              <div className="space-y-1.5"><Label htmlFor="pr-col">Cores</Label><Input id="pr-col" placeholder="4X0" value={form.colors} onChange={(e) => setForm({ ...form, colors: e.target.value })} /></div>
              <div className="space-y-1.5"><Label htmlFor="pr-qty">Qtde</Label><Input id="pr-qty" inputMode="numeric" value={form.qty} onChange={(e) => setForm({ ...form, qty: e.target.value })} /></div>
              <div className="space-y-1.5"><Label htmlFor="pr-size">Tam (mm)</Label><Input id="pr-size" placeholder="90 x 50" value={form.size} onChange={(e) => setForm({ ...form, size: e.target.value })} /></div>
              <div className="space-y-1.5"><Label htmlFor="pr-w">Peso (g)</Label><Input id="pr-w" inputMode="decimal" value={form.weight} onChange={(e) => setForm({ ...form, weight: e.target.value })} /></div>
              <div className="space-y-1.5"><Label htmlFor="pr-lead">Prazo (dias úteis)</Label><Input id="pr-lead" inputMode="numeric" value={form.lead} onChange={(e) => setForm({ ...form, lead: e.target.value })} /></div>
              <div className="space-y-1.5"><Label htmlFor="pr-cost">Custo (R$)</Label><Input id="pr-cost" inputMode="decimal" required value={form.cost} onChange={(e) => setForm({ ...form, cost: e.target.value })} /></div>
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
