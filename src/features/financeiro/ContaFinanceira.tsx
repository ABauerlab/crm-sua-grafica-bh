import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { AlertTriangle } from 'lucide-react'
import { useState, type FormEvent, type ReactNode } from 'react'
import { Link } from 'react-router-dom'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { useToast } from '@/components/ui/toast'
import { formatBRL, parseMoney } from '@/lib/money'
import { supabase } from '@/lib/supabase'
import { cn } from '@/lib/utils'

type CustoItem = { id: string; numero: number; cliente: string | null; valor: number; status: 'pendente' | 'pago' | 'ja_pago'; pago_em: string | null }
type Painel = {
  saldo: number; receitas: number; despesas: number
  saldo_mp: number | null; saldo_mp_em: string | null; inicio_automatico: string | null
  custos: { pendente: number; qtd_pendente: number; itens: CustoItem[] }
  imposto: {
    devido: number; notas: number; pago: number; a_pagar: number
    sem_nota_qtd: number; sem_nota_bruto: number; sem_nota_imposto: number
    por_mes: { mes: string; notas: number; imposto: number }[]
    pagamentos: { id: string; valor: number; data: string; observacao: string | null; movimentou: boolean }[]
  }
}

const dia = (iso: string | null) => (iso ? new Date(iso).toLocaleDateString('pt-BR') : '-')
const mesBR = (m: string) => `${m.slice(5)}/${m.slice(0, 4)}`

function Tile({ label, value, tone, children }: { label: string; value: string; tone?: 'bom' | 'ruim'; children?: ReactNode }) {
  return (
    <div className="min-w-0 rounded-md border bg-card p-3">
      <p className="text-[11px] font-bold uppercase tracking-wide text-muted-foreground">{label}</p>
      <p className={cn('mt-1 break-words text-xl font-black tabular', tone === 'bom' && 'text-brand-green', tone === 'ruim' && 'text-brand-red')}>{value}</p>
      {children}
    </div>
  )
}

/** Conta do financeiro: saldo que bate com o Mercado Pago, custos a pagar e imposto só de notas emitidas. */
export function ContaFinanceira() {
  const toast = useToast()
  const qc = useQueryClient()
  const [saldoMp, setSaldoMp] = useState('')
  const [imp, setImp] = useState({ valor: '', data: new Date().toLocaleDateString('sv-SE'), obs: '', movimentar: true })
  const painel = useQuery({
    queryKey: ['financeiro', 'painel'],
    refetchInterval: 60_000,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('financeiro_painel')
      if (error) throw new Error(error.message)
      return data as Painel
    },
  })
  const refresh = () => qc.invalidateQueries({ queryKey: ['financeiro'] })
  const erro = (e: Error) => toast('error', e.message)

  const informarSaldo = useMutation({
    mutationFn: async (valor: number) => { const { error } = await supabase.rpc('financeiro_saldo_informar', { p_valor: valor }); if (error) throw new Error(error.message) },
    onSuccess: () => { setSaldoMp(''); refresh(); toast('ok', 'Saldo do Mercado Pago registrado.') },
    onError: erro,
  })
  const baixarCusto = useMutation({
    mutationFn: async (v: { id: string; movimentar: boolean }) => { const { error } = await supabase.rpc('financeiro_custo_baixar', { p_id: v.id, p_movimentar: v.movimentar }); if (error) throw new Error(error.message) },
    onSuccess: refresh,
    onError: erro,
  })
  const reabrirCusto = useMutation({
    mutationFn: async (id: string) => { const { error } = await supabase.rpc('financeiro_custo_reabrir', { p_id: id }); if (error) throw new Error(error.message) },
    onSuccess: refresh,
    onError: erro,
  })
  const pagarImposto = useMutation({
    mutationFn: async () => {
      const valor = parseMoney(imp.valor)
      if (!(valor > 0)) throw new Error('Informe o valor pago de imposto.')
      const { error } = await supabase.rpc('financeiro_imposto_pagar', { p_valor: valor, p_data: imp.data, p_movimentar: imp.movimentar, p_obs: imp.obs })
      if (error) throw new Error(error.message)
    },
    onSuccess: () => { setImp({ ...imp, valor: '', obs: '' }); refresh(); toast('ok', 'Pagamento de imposto registrado.') },
    onError: erro,
  })
  const excluirImposto = useMutation({
    mutationFn: async (id: string) => { const { error } = await supabase.rpc('financeiro_imposto_excluir', { p_id: id }); if (error) throw new Error(error.message) },
    onSuccess: refresh,
    onError: erro,
  })

  const p = painel.data
  if (painel.isLoading) return <p className="text-sm text-muted-foreground">Carregando a conta…</p>
  if (painel.error || !p) return <p className="text-sm text-brand-red">Não foi possível carregar a conta (só o dono tem acesso).</p>

  const dif = p.saldo_mp === null ? null : Math.round((p.saldo - p.saldo_mp) * 100) / 100
  const pendentes = p.custos.itens.filter((c) => c.status === 'pendente')
  const baixados = p.custos.itens.filter((c) => c.status !== 'pendente')

  return (
    <div className="space-y-5">
      <section aria-label="Saldo da conta" className="rounded-md border bg-card p-4">
        <h2 className="text-base font-black">Saldo da conta</h2>
        <p className="mb-3 text-xs text-muted-foreground">
          Entra sozinho: todo pedido pago (valor bruto) e a taxa do Mercado Pago. Movimenta quando você marca: custo pago, imposto pago e o que você lançar em Receita e Despesa.
          {p.inicio_automatico ? ` Abertura em ${dia(p.inicio_automatico)}: pedidos pagos antes dessa data já estão no saldo inicial.` : ''}
        </p>
        <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
          <Tile label="Saldo pelo financeiro" value={formatBRL(p.saldo)} tone={p.saldo >= 0 ? 'bom' : 'ruim'}><p className="text-xs text-muted-foreground">entradas {formatBRL(p.receitas)} - saídas {formatBRL(p.despesas)}</p></Tile>
          <Tile label="Saldo no Mercado Pago" value={p.saldo_mp === null ? '—' : formatBRL(p.saldo_mp)}><p className="text-xs text-muted-foreground">{p.saldo_mp_em ? `informado em ${new Date(p.saldo_mp_em).toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' })}` : 'informe ao lado'}</p></Tile>
          <Tile label="Diferença" value={dif === null ? '—' : formatBRL(dif)} tone={dif === null ? undefined : dif === 0 ? 'bom' : 'ruim'}>
            <p className="text-xs text-muted-foreground">{dif === null ? 'sem saldo informado' : dif === 0 ? 'conferido: bate certinho' : dif > 0 ? 'o financeiro tem a mais: falta lançar uma saída' : 'o financeiro tem a menos: falta lançar uma entrada'}</p>
          </Tile>
          <form className="flex flex-col justify-end gap-1.5 rounded-md border bg-card p-3" onSubmit={(e: FormEvent) => { e.preventDefault(); const v = parseMoney(saldoMp); if (Number.isFinite(v)) informarSaldo.mutate(v) }}>
            <Label htmlFor="saldo-mp" className="text-[11px] font-bold uppercase tracking-wide text-muted-foreground">Conferir com o saldo de hoje no Mercado Pago</Label>
            <div className="flex gap-2">
              <Input id="saldo-mp" inputMode="decimal" placeholder="0,00" value={saldoMp} onChange={(e) => setSaldoMp(e.target.value)} />
              <Button type="submit" size="sm" disabled={!saldoMp.trim() || informarSaldo.isPending}>Salvar</Button>
            </div>
          </form>
        </div>
      </section>

      <section aria-label="Custos a pagar" className="rounded-md border bg-card p-4">
        <div className="mb-2 flex flex-wrap items-end justify-between gap-2">
          <div>
            <h2 className="text-base font-black">Custos a pagar</h2>
            <p className="text-xs text-muted-foreground">O custo de cada pedido pago só sai do saldo quando você marca que pagou.</p>
          </div>
          <p className="text-xl font-black tabular">{formatBRL(p.custos.pendente)} <span className="text-xs font-semibold text-muted-foreground">em {p.custos.qtd_pendente} pedido(s)</span></p>
        </div>
        {pendentes.length === 0 ? (
          <p className="text-sm text-muted-foreground">Nenhum custo pendente.</p>
        ) : (
          <ul className="divide-y text-sm">
            {pendentes.map((c) => (
              <li key={c.id} className="flex flex-wrap items-center justify-between gap-2 py-2">
                <div className="min-w-0">
                  <p className="font-semibold">Pedido SG-{String(c.numero).padStart(4, '0')} <span className="font-normal text-muted-foreground">· {c.cliente ?? 'sem nome'}</span></p>
                  <p className="font-bold tabular">{formatBRL(c.valor)}</p>
                </div>
                <div className="flex flex-wrap gap-2">
                  <Button size="sm" disabled={baixarCusto.isPending} onClick={() => baixarCusto.mutate({ id: c.id, movimentar: true })}>Paguei (sai do saldo)</Button>
                  <Button size="sm" variant="outline" disabled={baixarCusto.isPending} title="Já foi pago antes da abertura: tira da lista sem mexer no saldo" onClick={() => baixarCusto.mutate({ id: c.id, movimentar: false })}>Já estava pago</Button>
                </div>
              </li>
            ))}
          </ul>
        )}
        {baixados.length > 0 && (
          <details className="mt-3 text-sm">
            <summary className="cursor-pointer font-semibold">Custos baixados ({baixados.length})</summary>
            <ul className="mt-2 divide-y">
              {baixados.map((c) => (
                <li key={c.id} className="flex flex-wrap items-center justify-between gap-2 py-1.5">
                  <span>SG-{String(c.numero).padStart(4, '0')} · {formatBRL(c.valor)} · {c.status === 'pago' ? 'pago (saiu do saldo)' : 'já estava pago'} em {dia(c.pago_em)}</span>
                  <Button size="sm" variant="ghost" disabled={reabrirCusto.isPending} onClick={() => reabrirCusto.mutate(c.id)}>Desfazer</Button>
                </li>
              ))}
            </ul>
          </details>
        )}
      </section>

      <section aria-label="Imposto" className="rounded-md border bg-card p-4">
        <h2 className="text-base font-black">Imposto</h2>
        <p className="mb-3 text-xs font-semibold">O imposto só é calculado sobre pedidos com nota fiscal emitida. Pedido pago sem nota não entra.</p>
        <div className="grid grid-cols-2 gap-3 lg:grid-cols-3">
          <Tile label="Imposto devido (notas emitidas)" value={formatBRL(p.imposto.devido)}><p className="text-xs text-muted-foreground">{p.imposto.notas} pedido(s) com nota emitida</p></Tile>
          <Tile label="Imposto já pago" value={formatBRL(p.imposto.pago)} />
          <Tile label="Imposto a pagar" value={formatBRL(p.imposto.a_pagar)} tone={p.imposto.a_pagar > 0 ? 'ruim' : 'bom'}><p className="text-xs text-muted-foreground">devido menos o que você já registrou como pago</p></Tile>
        </div>
        {p.imposto.sem_nota_qtd > 0 && (
          <div role="status" className="mt-3 flex items-start gap-2 rounded-md border border-brand-yellow bg-brand-yellow/15 p-3 text-sm">
            <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden />
            <p>
              <strong>{p.imposto.sem_nota_qtd} pedido(s) pago(s) sem nota emitida</strong> ({formatBRL(p.imposto.sem_nota_bruto)} bruto) estão fora do imposto. Imposto estimado que ainda não entra: {formatBRL(p.imposto.sem_nota_imposto)}.{' '}
              <Link to="/bling" className="font-bold underline">Ver em Bling e NF</Link>
            </p>
          </div>
        )}
        {p.imposto.por_mes.length > 0 && (
          <ul className="mt-3 divide-y text-sm" aria-label="Imposto por mês">
            {p.imposto.por_mes.map((m) => (
              <li key={m.mes} className="flex items-center justify-between gap-2 py-1.5"><span>{mesBR(m.mes)} <span className="text-xs text-muted-foreground">({m.notas} nota(s), pela data da emissão)</span></span><span className="font-bold tabular">{formatBRL(m.imposto)}</span></li>
            ))}
          </ul>
        )}
        <form className="mt-4 grid gap-3 rounded-md border p-3 sm:grid-cols-[1fr_1fr_2fr_auto] sm:items-end" onSubmit={(e: FormEvent) => { e.preventDefault(); pagarImposto.mutate() }}>
          <div className="space-y-1.5"><Label htmlFor="imp-valor">Imposto pago (R$)</Label><Input id="imp-valor" inputMode="decimal" placeholder="0,00" value={imp.valor} onChange={(e) => setImp({ ...imp, valor: e.target.value })} /></div>
          <div className="space-y-1.5"><Label htmlFor="imp-data">Data</Label><Input id="imp-data" type="date" value={imp.data} onChange={(e) => setImp({ ...imp, data: e.target.value })} /></div>
          <div className="space-y-1.5"><Label htmlFor="imp-obs">Observação (opcional)</Label><Input id="imp-obs" placeholder="Ex.: DAS de novembro" value={imp.obs} onChange={(e) => setImp({ ...imp, obs: e.target.value })} /></div>
          <Button type="submit" disabled={pagarImposto.isPending}>Registrar</Button>
          <label className="flex items-center gap-2 text-xs sm:col-span-4">
            <input type="checkbox" className="h-4 w-4" checked={!imp.movimentar} onChange={(e) => setImp({ ...imp, movimentar: !e.target.checked })} />
            Já estava descontado do saldo (pago antes da abertura): abate o imposto sem mexer no saldo
          </label>
        </form>
        {p.imposto.pagamentos.length > 0 && (
          <ul className="mt-3 divide-y text-sm" aria-label="Pagamentos de imposto">
            {p.imposto.pagamentos.map((g) => (
              <li key={g.id} className="flex flex-wrap items-center justify-between gap-2 py-1.5">
                <span>{dia(g.data)} · {formatBRL(g.valor)}{g.observacao ? ` · ${g.observacao}` : ''} <span className="text-xs text-muted-foreground">{g.movimentou ? '(saiu do saldo)' : '(sem mexer no saldo)'}</span></span>
                <Button size="sm" variant="ghost" disabled={excluirImposto.isPending} onClick={() => { if (window.confirm('Excluir este pagamento de imposto?')) excluirImposto.mutate(g.id) }}>Excluir</Button>
              </li>
            ))}
          </ul>
        )}
      </section>
    </div>
  )
}
