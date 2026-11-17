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
import { formatBRL } from '@/lib/money'
import { resumoNfFaltando } from '@/lib/nota-fiscal'
import { supabase } from '@/lib/supabase'
import { cn } from '@/lib/utils'

type Linha = {
  id: string
  number: number
  paid_at: string | null
  created_at: string
  nf_emitida: boolean
  nf_identificador: string | null
  nf_emitida_em: string | null
  bling_pedido_id: string | null
  bling_erro: string | null
  nf_faltantes: string[] | null
  contact: { name: string | null; wa_id: string } | null
  total: number
}

const SELECT = 'id, number, paid_at, created_at, nf_emitida, nf_identificador, nf_emitida_em, bling_pedido_id, bling_erro, nf_faltantes, contact:contacts(name, wa_id)'

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
        {o.nf_emitida ? <Badge className="bg-brand-green/10 text-brand-green">NF emitida{o.nf_emitida_em ? ` em ${dia(o.nf_emitida_em)}` : ''}</Badge> : <Badge className="bg-brand-yellow/30 text-ink">NF pendente</Badge>}
      </div>
      {o.bling_erro && <p className="mt-1 text-xs font-semibold text-brand-red">Erro no envio ao Bling: {o.bling_erro}</p>}
      {falta && !o.nf_emitida && <p className="mt-1 text-xs font-semibold">{falta}</p>}
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
  const [filtro, setFiltro] = useState<'pendentes' | 'emitidas' | 'todas'>('pendentes')
  const lista = useMemo(() => (data ?? []).filter((o) => (filtro === 'todas' ? true : filtro === 'emitidas' ? o.nf_emitida : !o.nf_emitida)), [data, filtro])
  if (isLoading) return <Skeleton className="h-64 w-full" />
  if (error) return <ErrorState message={(error as Error).message} />
  const pend = (data ?? []).filter((o) => !o.nf_emitida).length
  const emit = (data ?? []).length - pend
  return (
    <div className="space-y-3">
      <div className="flex flex-wrap gap-2" role="tablist" aria-label="Filtro de notas">
        {([['pendentes', `Pendentes (${pend})`], ['emitidas', `Emitidas (${emit})`], ['todas', `Todas (${pend + emit})`]] as const).map(([v, l]) => (
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
