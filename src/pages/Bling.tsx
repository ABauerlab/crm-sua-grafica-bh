import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { FileCheck2 } from 'lucide-react'
import { useMemo, useState } from 'react'
import { Badge } from '@/components/ui/badge'
import { ErrorState } from '@/components/ui/empty-state'
import { Input } from '@/components/ui/input'
import { Skeleton } from '@/components/ui/skeleton'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { useToast } from '@/components/ui/toast'
import BlingTab from '@/features/bling/BlingTab'
import { Button } from '@/components/ui/button'
import { invokeFunction } from '@/lib/api'
import { formatBRL } from '@/lib/money'
import { motivoNaoEmitida, resumoNfFaltando } from '@/lib/nota-fiscal'
import { supabase } from '@/lib/supabase'
import { cn } from '@/lib/utils'

type Linha = {
  id: string
  number: number
  paid_at: string | null
  created_at: string
  nf_emitida: boolean
  nf_identificador: string | null
  nf_tipo: string | null
  nf_situacao: string | null
  nf_motivo: string | null
  nf_dispensada: boolean
  nf_conferido_em: string | null
  nf_emitida_em: string | null
  bling_pedido_id: string | null
  bling_erro: string | null
  nf_faltantes: string[] | null
  contact: { name: string | null; wa_id: string } | null
  total: number
}

const SELECT = 'id, number, paid_at, created_at, nf_emitida, nf_identificador, nf_tipo, nf_situacao, nf_motivo, nf_dispensada, nf_conferido_em, nf_emitida_em, bling_pedido_id, bling_erro, nf_faltantes, contact:contacts(name, wa_id)'

function useNotasFiscais() {
  return useQuery({
    queryKey: ['nf-checklist'],
    queryFn: async (): Promise<Linha[]> => {
      const [pedidos, fins] = await Promise.all([
        supabase.from('orders').select(SELECT).eq('payment_status', 'aprovado').is('excluido_em', null).eq('teste', false).order('paid_at', { ascending: false, nullsFirst: false }).limit(1000),
        supabase.from('order_financials').select('order_id, total').limit(2000),
      ])
      if (pedidos.error) throw new Error(pedidos.error.message)
      if (fins.error) throw new Error(fins.error.message)
      const total = new Map((fins.data as { order_id: string; total: number }[]).map((f) => [f.order_id, Number(f.total)]))
      return (pedidos.data as unknown as Omit<Linha, 'total'>[]).map((o) => ({ ...o, total: total.get(o.id) ?? 0 }))
    },
  })
}

const dia = (iso: string | null) => (iso ? new Date(iso).toLocaleDateString('pt-BR') : '-')

function LinhaNf({ o }: { o: Linha }) {
  const toast = useToast()
  const qc = useQueryClient()
  const [ident, setIdent] = useState(o.nf_identificador ?? '')
  const salvar = useMutation({
    mutationFn: async (v: { emitida: boolean; ident: string }) => {
      const { error } = await supabase.rpc('nf_marcar', { p_order: o.id, p_emitida: v.emitida, p_identificador: v.ident })
      if (error) throw new Error(error.message)
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['nf-checklist'] }),
    onError: (e: Error) => toast('error', e.message),
  })
  const falta = resumoNfFaltando(o.nf_faltantes)
  const dispensar = useMutation({
    mutationFn: async (v: { dispensada: boolean; motivo: string }) => { const { error } = await supabase.rpc('nf_dispensar', { p_order: o.id, p_dispensada: v.dispensada, p_motivo: v.motivo }); if (error) throw new Error(error.message) },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['nf-checklist'] }),
    onError: (e: Error) => toast('error', e.message),
  })
  const [motivo, setMotivo] = useState(o.nf_motivo ?? '')
  const salvarMotivo = useMutation({
    mutationFn: async (m: string) => { const { error } = await supabase.rpc('nf_motivo_salvar', { p_order: o.id, p_motivo: m }); if (error) throw new Error(error.message) },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['nf-checklist'] }),
    onError: (e: Error) => toast('error', e.message),
  })
  const alterouIdent = ident.trim() !== (o.nf_identificador ?? '')
  return (
    <li className={cn('rounded-lg border bg-background p-3', o.nf_emitida && 'border-brand-green/40 bg-brand-green/5')}>
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div className="min-w-0">
          <p className="text-sm font-black">
            Pedido SG-{String(o.number).padStart(4, '0')} <span className="font-semibold text-muted-foreground">· {o.contact?.name?.trim() || o.contact?.wa_id}</span>
          </p>
          <p className="text-xs text-muted-foreground tabular">
            {formatBRL(o.total)} · pago em {dia(o.paid_at)} · {o.bling_pedido_id ? 'enviado ao Bling' : 'ainda não enviado ao Bling'}
          </p>
        </div>
        {o.nf_dispensada ? (
          <Badge className="bg-ink/10 text-ink">NF não será emitida</Badge>
        ) : o.nf_emitida ? (
          <Badge className="bg-brand-green/10 text-brand-green">{o.nf_tipo === 'nfe' ? 'NF-e' : 'NFC-e'}{o.nf_identificador ? ` nº ${o.nf_identificador}` : ''} · {o.nf_situacao ?? 'emitida'}</Badge>
        ) : o.nf_situacao ? (
          <Badge className="bg-brand-red/10 text-brand-red">{o.nf_tipo === 'nfe' ? 'NF-e' : 'NFC-e'}{o.nf_identificador ? ` nº ${o.nf_identificador}` : ''} · {o.nf_situacao}</Badge>
        ) : (
          <Badge className="bg-brand-yellow/30 text-ink">NF pendente</Badge>
        )}
      </div>
      {o.bling_erro && <p className="mt-1 text-xs font-semibold text-brand-red">Erro no envio ao Bling: {o.bling_erro}</p>}
      {o.nf_dispensada ? (
        <p className="mt-1 text-xs font-semibold">Motivo: {o.nf_motivo || 'não informado'}</p>
      ) : !o.nf_emitida && <p className="mt-1 text-xs font-semibold text-brand-red">Motivo: {motivoNaoEmitida(o)}</p>}
      {falta && !o.nf_emitida && !o.nf_dispensada && <p className="mt-1 text-xs font-semibold">{falta}</p>}
      {!o.nf_emitida && (
        <Input
          className="mt-2 h-11 md:h-9"
          placeholder="Sua anotação do motivo (opcional)"
          aria-label={`Motivo da nota não emitida do pedido ${o.number}`}
          value={motivo}
          onChange={(e) => setMotivo(e.target.value)}
          onBlur={() => motivo.trim() !== (o.nf_motivo ?? '') && salvarMotivo.mutate(motivo)}
        />
      )}
      <div className="mt-2 flex flex-wrap items-center gap-3">
        <label className="flex min-h-11 items-center gap-2 text-sm font-semibold md:min-h-9">
          <input
            type="checkbox"
            className="h-5 w-5 accent-[#16a34a]"
            checked={o.nf_emitida}
            disabled={salvar.isPending}
            onChange={(e) => salvar.mutate({ emitida: e.target.checked, ident })}
          />
          Nota fiscal emitida
        </label>
        <label className="flex min-h-11 items-center gap-2 text-sm font-semibold md:min-h-9">
          <input
            type="checkbox"
            className="h-5 w-5 accent-[#52525b]"
            checked={o.nf_dispensada}
            disabled={dispensar.isPending || o.nf_emitida}
            title={o.nf_emitida ? 'Desmarque "emitida" antes' : 'Tira o pedido de pendente. Anote o motivo no campo acima.'}
            onChange={(e) => dispensar.mutate({ dispensada: e.target.checked, motivo })}
          />
          Nota não será emitida
        </label>
        <Input
          className="h-11 w-full min-w-0 flex-1 md:h-9 md:max-w-xs"
          placeholder="Nº ou identificador da NF no Bling"
          aria-label={`Identificador da NF do pedido ${o.number}`}
          value={ident}
          onChange={(e) => setIdent(e.target.value)}
          onBlur={() => alterouIdent && salvar.mutate({ emitida: o.nf_emitida, ident })}
          onKeyDown={(e) => { if (e.key === 'Enter') (e.target as HTMLInputElement).blur() }}
        />
      </div>
    </li>
  )
}

function ChecklistNf() {
  const { data, isLoading, error } = useNotasFiscais()
  const toast = useToast()
  const qc = useQueryClient()
  const conferir = useMutation({
    mutationFn: () => invokeFunction<{ ok: boolean; conferidas?: number; com_nota?: number; erro?: string }>('bling-integracao', { acao: 'conferir_nf' }),
    onSuccess: (r) => { qc.invalidateQueries({ queryKey: ['nf-checklist'] }); toast(r.ok ? 'ok' : 'error', r.ok ? `Conferido no Bling: ${r.com_nota ?? 0} nota(s) encontrada(s) em ${r.conferidas ?? 0} pedido(s).` : r.erro ?? 'Não foi possível conferir.') },
    onError: (e: Error) => toast('error', e.message),
  })
  const [filtro, setFiltro] = useState<'pendentes' | 'emitidas' | 'dispensadas' | 'todas'>('pendentes')
  const lista = useMemo(() => (data ?? []).filter((o) => (filtro === 'todas' ? true : filtro === 'emitidas' ? o.nf_emitida : filtro === 'dispensadas' ? o.nf_dispensada : !o.nf_emitida && !o.nf_dispensada)), [data, filtro])
  if (isLoading) return <Skeleton className="h-64 w-full" />
  if (error) return <ErrorState message={(error as Error).message} />
  const lista0 = data ?? []
  const pendentes = lista0.filter((o) => !o.nf_emitida && !o.nf_dispensada)
  const dispensadas = lista0.filter((o) => o.nf_dispensada)
  const emitidas = lista0.filter((o) => o.nf_emitida)
  const pend = pendentes.length
  const emit = emitidas.length
  const contar = (l: string[]) => { const m = new Map<string, number>(); for (const k of l) m.set(k, (m.get(k) ?? 0) + 1); return [...m.entries()] }
  const porMotivo = contar(pendentes.map((o) => o.nf_motivo?.trim() || motivoNaoEmitida(o).replace(/ nº \d+/, '').replace(/: corrigir e emitir de novo/, '')))
  const porMotivoDisp = contar(dispensadas.map((o) => o.nf_motivo?.trim() || 'sem motivo informado'))
  const somaTotal = (l: Linha[]) => l.reduce((n, o) => n + o.total, 0)
  return (
    <div className="space-y-3">
      <div className="grid grid-cols-1 gap-3 md:grid-cols-3">
        <div className="rounded-lg border border-brand-green/40 bg-brand-green/5 p-3">
          <p className="text-[11px] font-bold uppercase tracking-wide text-muted-foreground">Notas emitidas</p>
          <p className="text-2xl font-black tabular">{emit}</p>
          <p className="text-xs text-muted-foreground tabular">{formatBRL(somaTotal(emitidas))} em vendas com nota</p>
        </div>
        <div className={cn('rounded-lg border p-3', pend > 0 ? 'border-brand-red/40 bg-brand-red/5' : 'border-brand-green/40 bg-brand-green/5')}>
          <p className="text-[11px] font-bold uppercase tracking-wide text-muted-foreground">Notas pendentes</p>
          <p className={cn('text-2xl font-black tabular', pend > 0 && 'text-brand-red')}>{pend}</p>
          <p className="text-xs text-muted-foreground tabular">{formatBRL(somaTotal(pendentes))} aguardando nota</p>
          {porMotivo.length > 0 && (
            <ul className="mt-2 space-y-0.5 text-xs" aria-label="Motivos das notas pendentes">
              {porMotivo.map(([m, n]) => <li key={m}><strong className="tabular">{n}</strong> · {m}</li>)}
            </ul>
          )}
        </div>
        <div className="rounded-lg border border-ink/20 bg-ink/5 p-3">
          <p className="text-[11px] font-bold uppercase tracking-wide text-muted-foreground">Notas não emitidas</p>
          <p className="text-2xl font-black tabular">{dispensadas.length}</p>
          <p className="text-xs text-muted-foreground tabular">{formatBRL(somaTotal(dispensadas))} em vendas sem nota (decisão sua)</p>
          {porMotivoDisp.length > 0 && (
            <ul className="mt-2 space-y-0.5 text-xs" aria-label="Motivos das notas não emitidas">
              {porMotivoDisp.map(([m, n]) => <li key={m}><strong className="tabular">{n}</strong> · {m}</li>)}
            </ul>
          )}
        </div>
      </div>
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="text-xs text-muted-foreground">O número e a situação da nota são preenchidos sozinhos a partir do Bling, a cada 10 minutos.</p>
        <Button size="sm" variant="outline" disabled={conferir.isPending} onClick={() => conferir.mutate()}>{conferir.isPending ? 'Conferindo…' : 'Conferir no Bling agora'}</Button>
      </div>
      <div className="flex flex-wrap gap-2" role="tablist" aria-label="Filtro de notas">
        {([['pendentes', `Pendentes (${pend})`], ['emitidas', `Emitidas (${emit})`], ['dispensadas', `Não emitidas (${dispensadas.length})`], ['todas', `Todas (${lista0.length})`]] as const).map(([v, l]) => (
          <button key={v} role="tab" aria-selected={filtro === v} onClick={() => setFiltro(v)} className={cn('min-h-11 rounded-md border px-3 text-sm font-bold md:min-h-9', filtro === v ? 'border-ink bg-ink text-white' : 'bg-background hover:bg-secondary')}>
            {l}
          </button>
        ))}
      </div>
      {lista.length === 0 ? (
        <p className="rounded-lg border border-dashed p-6 text-center text-sm text-muted-foreground">{filtro === 'pendentes' ? 'Nenhuma nota pendente. Tudo emitido.' : 'Nada por aqui.'}</p>
      ) : (
        <ul className="space-y-2">{lista.map((o) => <LinhaNf key={o.id} o={o} />)}</ul>
      )}
    </div>
  )
}

/** Área do Bling: checklist de nota fiscal por pedido pago e a conexão com a conta do Bling. */
export default function Bling() {
  return (
    <div className="mx-auto w-full max-w-4xl space-y-4 p-4 md:p-6">
      <div className="flex items-center gap-2">
        <FileCheck2 className="h-5 w-5" aria-hidden />
        <h1 className="text-xl font-black">Bling e notas fiscais</h1>
      </div>
      <Tabs defaultValue="notas">
        <TabsList>
          <TabsTrigger value="notas">Checklist de NF</TabsTrigger>
          <TabsTrigger value="integracao">Integração</TabsTrigger>
        </TabsList>
        <TabsContent value="notas"><ChecklistNf /></TabsContent>
        <TabsContent value="integracao"><BlingTab /></TabsContent>
      </Tabs>
    </div>
  )
}
