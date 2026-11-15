import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Pencil, Plus, Trash2, Wallet } from 'lucide-react'
import { useMemo, useState, type FormEvent } from 'react'
import { Button } from '@/components/ui/button'
import { EmptyState } from '@/components/ui/empty-state'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { Skeleton } from '@/components/ui/skeleton'
import { Modal } from '@/components/ui/sheet'
import { useToast } from '@/components/ui/toast'
import { invokeFunction } from '@/lib/api'
import { formatBRL, parseMoney } from '@/lib/money'
import { supabase } from '@/lib/supabase'
import { cn } from '@/lib/utils'

type Resumo = {
  pedidos: { pedidos: number; faturamento: number; custo: number; impostos: number; taxas: number; lucro: number }
  manual: { receitas: number; despesas: number }
  categorias: { categoria: string; tipo: 'receita' | 'despesa'; total: number }[]
  meses: { mes: string; lucro_pedidos: number; receitas: number; despesas: number }[]
  resultado: number
}
type Lancamento = { id: string; tipo: 'receita' | 'despesa'; categoria: string; descricao: string | null; valor: number; data: string; pago: boolean }
type Saldo = { ok: boolean; disponivel?: number; a_liberar?: number; total?: number; error?: string; modo?: string }

const CATEGORIAS_DESPESA = ['Fornecedor', 'Frete e entrega', 'Anúncios', 'Ferramentas e sistemas', 'Impostos', 'Salários e pró-labore', 'Aluguel e contas', 'Outros']
const CATEGORIAS_RECEITA = ['Venda no balcão', 'Serviço de arte', 'Marketplace', 'Outros']

const iso = (d: Date) => d.toISOString().slice(0, 10)
function periodo(chave: string): { de: string; ate: string } {
  const hoje = new Date()
  if (chave === 'mes_passado') return { de: iso(new Date(hoje.getFullYear(), hoje.getMonth() - 1, 1)), ate: iso(new Date(hoje.getFullYear(), hoje.getMonth(), 0)) }
  if (chave === '30d') return { de: iso(new Date(Date.now() - 29 * 86_400_000)), ate: iso(hoje) }
  if (chave === 'ano') return { de: iso(new Date(hoje.getFullYear(), 0, 1)), ate: iso(hoje) }
  return { de: iso(new Date(hoje.getFullYear(), hoje.getMonth(), 1)), ate: iso(hoje) }
}

function Tile({ label, value, tone, children }: { label: string; value: string; tone?: 'bom' | 'ruim'; children?: React.ReactNode }) {
  return (
    <div className="rounded-md border bg-card p-3">
      <p className="text-[11px] font-bold uppercase tracking-wide text-muted-foreground">{label}</p>
      <p className={cn('mt-1 text-xl font-black tabular', tone === 'bom' && 'text-brand-green', tone === 'ruim' && 'text-brand-red')}>{value}</p>
      {children}
    </div>
  )
}

export default function Financeiro() {
  const toast = useToast()
  const qc = useQueryClient()
  const [chave, setChave] = useState('mes')
  const { de, ate } = useMemo(() => periodo(chave), [chave])
  const [form, setForm] = useState<{ id?: string; tipo: 'receita' | 'despesa'; categoria: string; descricao: string; valor: string; data: string } | null>(null)

  const resumo = useQuery({
    queryKey: ['financeiro', 'resumo', de, ate],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('financeiro_resumo', { p_de: de, p_ate: ate })
      if (error) throw new Error(error.message)
      return data as Resumo
    },
  })
  const lancamentos = useQuery({
    queryKey: ['financeiro', 'lancamentos', de, ate],
    queryFn: async () => {
      const { data, error } = await supabase.from('financeiro_lancamentos').select('*').gte('data', de).lte('data', ate).order('data', { ascending: false }).order('criado_em', { ascending: false })
      if (error) throw new Error(error.message)
      return (data ?? []) as Lancamento[]
    },
  })
  const saldo = useQuery({ queryKey: ['financeiro', 'saldo'], queryFn: () => invokeFunction<Saldo>('mp-saldo'), staleTime: 60_000, retry: false })
  const refresh = () => qc.invalidateQueries({ queryKey: ['financeiro'] })

  const salvar = useMutation({
    mutationFn: async (f: NonNullable<typeof form>) => {
      const valor = parseMoney(f.valor)
      if (!(valor > 0)) throw new Error('Informe um valor maior que zero.')
      if (!f.categoria.trim()) throw new Error('Escolha ou escreva uma categoria.')
      const linha = { tipo: f.tipo, categoria: f.categoria.trim(), descricao: f.descricao.trim() || null, valor, data: f.data }
      const { error } = f.id ? await supabase.from('financeiro_lancamentos').update(linha).eq('id', f.id) : await supabase.from('financeiro_lancamentos').insert(linha)
      if (error) throw new Error(error.message)
    },
    onSuccess: () => { setForm(null); refresh(); toast('ok', 'Lançamento salvo.') },
    onError: (e: Error) => toast('error', e.message),
  })
  const excluir = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.from('financeiro_lancamentos').delete().eq('id', id)
      if (error) throw new Error(error.message)
    },
    onSuccess: refresh,
    onError: (e: Error) => toast('error', e.message),
  })

  const r = resumo.data
  const novo = (tipo: 'receita' | 'despesa') => setForm({ tipo, categoria: '', descricao: '', valor: '', data: iso(new Date()) })
  const maxMes = Math.max(1, ...(r?.meses ?? []).map((m) => Math.max(Math.abs(m.lucro_pedidos + m.receitas - m.despesas), m.despesas)))

  return (
    <div className="flex h-full flex-col">
      <header className="flex flex-wrap items-center justify-between gap-2 border-b px-4 py-3">
        <h1 className="text-xl font-black">Financeiro</h1>
        <div className="flex flex-wrap items-center gap-2">
          <Select aria-label="Período" className="w-44" value={chave} onChange={(e) => setChave(e.target.value)}>
            <option value="mes">Este mês</option>
            <option value="mes_passado">Mês passado</option>
            <option value="30d">Últimos 30 dias</option>
            <option value="ano">Este ano</option>
          </Select>
          <Button size="sm" variant="outline" onClick={() => novo('receita')}><Plus className="h-4 w-4" /> Receita</Button>
          <Button size="sm" onClick={() => novo('despesa')}><Plus className="h-4 w-4" /> Despesa</Button>
        </div>
      </header>

      <div className="min-h-0 flex-1 space-y-5 overflow-y-auto p-4">
        {resumo.isLoading ? (
          <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">{[0, 1, 2, 3, 4, 5, 6, 7].map((i) => <Skeleton key={i} className="h-20" />)}</div>
        ) : resumo.error ? (
          <p className="text-sm text-brand-red">Não foi possível carregar o financeiro (só o dono tem acesso).</p>
        ) : r && (
          <>
            <section aria-label="Resumo" className="grid grid-cols-2 gap-3 lg:grid-cols-4">
              <Tile label="Faturamento (pedidos pagos)" value={formatBRL(r.pedidos.faturamento)}><p className="text-xs text-muted-foreground">{r.pedidos.pedidos} pedido(s)</p></Tile>
              <Tile label="Custo dos pedidos" value={formatBRL(r.pedidos.custo)} />
              <Tile label="Impostos e taxas" value={formatBRL(r.pedidos.impostos + r.pedidos.taxas)}><p className="text-xs text-muted-foreground">impostos {formatBRL(r.pedidos.impostos)} · taxas {formatBRL(r.pedidos.taxas)}</p></Tile>
              <Tile label="Lucro líquido dos pedidos" value={formatBRL(r.pedidos.lucro)} tone="bom" />
              <Tile label="Outras receitas" value={formatBRL(r.manual.receitas)} />
              <Tile label="Despesas lançadas" value={formatBRL(r.manual.despesas)} tone={r.manual.despesas > 0 ? 'ruim' : undefined} />
              <Tile label="Resultado do período" value={formatBRL(r.resultado)} tone={r.resultado >= 0 ? 'bom' : 'ruim'}><p className="text-xs text-muted-foreground">lucro dos pedidos + receitas - despesas</p></Tile>
              <Tile label="Saldo no Mercado Pago" value={saldo.data?.ok ? formatBRL(saldo.data.disponivel) : '—'}>
                <p className="text-xs text-muted-foreground">
                  {saldo.isLoading ? 'Consultando…' : saldo.data?.ok ? `a liberar ${formatBRL(saldo.data.a_liberar)}${saldo.data.modo === 'teste' ? ' (modo teste)' : ''}` : saldo.data?.error ?? 'Indisponível agora'}
                </p>
              </Tile>
            </section>

            <section aria-label="Últimos meses" className="rounded-md border bg-card p-4">
              <h2 className="mb-3 text-base font-black">Resultado nos últimos 6 meses</h2>
              <ul className="space-y-2">
                {r.meses.map((m) => {
                  const res = m.lucro_pedidos + m.receitas - m.despesas
                  return (
                    <li key={m.mes} className="grid grid-cols-[4.5rem_1fr_6.5rem] items-center gap-2 text-sm">
                      <span className="tabular text-muted-foreground">{m.mes.slice(5)}/{m.mes.slice(2, 4)}</span>
                      <span className="h-3 overflow-hidden rounded-sm bg-secondary" role="img" aria-label={`Resultado de ${m.mes}: ${formatBRL(res)}`}>
                        <span className={cn('block h-full rounded-sm', res >= 0 ? 'bg-brand-green' : 'bg-brand-red')} style={{ width: `${Math.max(2, (Math.abs(res) / maxMes) * 100)}%` }} />
                      </span>
                      <span className={cn('text-right font-bold tabular', res < 0 && 'text-brand-red')}>{formatBRL(res)}</span>
                    </li>
                  )
                })}
              </ul>
            </section>

            {r.categorias.length > 0 && (
              <section aria-label="Por categoria" className="rounded-md border bg-card p-4">
                <h2 className="mb-2 text-base font-black">Lançamentos por categoria</h2>
                <ul className="divide-y text-sm">
                  {r.categorias.map((c) => (
                    <li key={`${c.tipo}-${c.categoria}`} className="flex items-center justify-between gap-2 py-1.5">
                      <span>{c.categoria} <span className="text-xs text-muted-foreground">({c.tipo === 'receita' ? 'receita' : 'despesa'})</span></span>
                      <span className={cn('font-bold tabular', c.tipo === 'despesa' && 'text-brand-red')}>{formatBRL(c.total)}</span>
                    </li>
                  ))}
                </ul>
              </section>
            )}
          </>
        )}

        <section aria-label="Lançamentos">
          <h2 className="mb-2 text-base font-black">Lançamentos do período</h2>
          {lancamentos.isLoading ? (
            <Skeleton className="h-24" />
          ) : (lancamentos.data ?? []).length === 0 ? (
            <EmptyState icon={Wallet} title="Nenhum lançamento neste período">Use os botões Receita e Despesa para registrar o que entra e sai além dos pedidos.</EmptyState>
          ) : (
            <ul className="divide-y rounded-md border">
              {lancamentos.data!.map((l) => (
                <li key={l.id} className="flex flex-wrap items-center justify-between gap-2 px-3 py-2 text-sm">
                  <div className="min-w-0">
                    <p className="font-semibold">{l.categoria}{l.descricao ? ` · ${l.descricao}` : ''}</p>
                    <p className="text-xs text-muted-foreground">{new Date(l.data + 'T12:00').toLocaleDateString('pt-BR')} · {l.tipo === 'receita' ? 'Receita' : 'Despesa'}</p>
                  </div>
                  <div className="flex items-center gap-1">
                    <span className={cn('mr-2 font-bold tabular', l.tipo === 'despesa' && 'text-brand-red')}>{l.tipo === 'despesa' ? '-' : '+'}{formatBRL(l.valor)}</span>
                    <Button size="icon" variant="ghost" aria-label="Editar lançamento" onClick={() => setForm({ id: l.id, tipo: l.tipo, categoria: l.categoria, descricao: l.descricao ?? '', valor: String(l.valor).replace('.', ','), data: l.data })}><Pencil className="h-4 w-4" /></Button>
                    <Button size="icon" variant="ghost" aria-label="Excluir lançamento" onClick={() => { if (window.confirm('Excluir este lançamento?')) excluir.mutate(l.id) }}><Trash2 className="h-4 w-4" /></Button>
                  </div>
                </li>
              ))}
            </ul>
          )}
        </section>
      </div>

      <Modal open={!!form} onOpenChange={(o) => !o && setForm(null)} title={form?.id ? 'Editar lançamento' : form?.tipo === 'receita' ? 'Nova receita' : 'Nova despesa'} description="O lucro dos pedidos pagos já entra sozinho. Aqui ficam só as outras entradas e saídas.">
        {form && (
          <form className="space-y-3" onSubmit={(e: FormEvent) => { e.preventDefault(); salvar.mutate(form) }}>
            <div className="space-y-1.5">
              <Label htmlFor="fin-tipo">Tipo</Label>
              <Select id="fin-tipo" value={form.tipo} onChange={(e) => setForm({ ...form, tipo: e.target.value as 'receita' | 'despesa' })}>
                <option value="despesa">Despesa (saída)</option>
                <option value="receita">Receita (entrada)</option>
              </Select>
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="fin-cat">Categoria</Label>
              <Input id="fin-cat" list="fin-cats" required value={form.categoria} onChange={(e) => setForm({ ...form, categoria: e.target.value })} />
              <datalist id="fin-cats">{(form.tipo === 'despesa' ? CATEGORIAS_DESPESA : CATEGORIAS_RECEITA).map((c) => <option key={c} value={c} />)}</datalist>
            </div>
            <div className="space-y-1.5"><Label htmlFor="fin-desc">Descrição (opcional)</Label><Input id="fin-desc" value={form.descricao} onChange={(e) => setForm({ ...form, descricao: e.target.value })} /></div>
            <div className="grid grid-cols-2 gap-2">
              <div className="space-y-1.5"><Label htmlFor="fin-valor">Valor (R$)</Label><Input id="fin-valor" inputMode="decimal" required value={form.valor} onChange={(e) => setForm({ ...form, valor: e.target.value })} /></div>
              <div className="space-y-1.5"><Label htmlFor="fin-data">Data</Label><Input id="fin-data" type="date" required value={form.data} onChange={(e) => setForm({ ...form, data: e.target.value })} /></div>
            </div>
            <div className="flex justify-end gap-2">
              <Button type="button" variant="outline" onClick={() => setForm(null)}>Cancelar</Button>
              <Button type="submit" disabled={salvar.isPending}>{salvar.isPending ? 'Salvando…' : 'Salvar'}</Button>
            </div>
          </form>
        )}
      </Modal>
    </div>
  )
}
