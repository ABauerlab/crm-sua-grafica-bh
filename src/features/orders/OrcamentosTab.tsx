import { useQuery } from '@tanstack/react-query'
import { ExternalLink, FileText, Send } from 'lucide-react'
import { useState } from 'react'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { Skeleton } from '@/components/ui/skeleton'
import { Textarea } from '@/components/ui/textarea'
import { useToast } from '@/components/ui/toast'
import { abrirPdfOrcamento, useGerarPdfOrcamento, useOrcamentosDoPedido, useRegistrarPerda } from '@/hooks/orcamentos'
import { EnviarPdfDialog } from './EnviarPdfDialog'
import { formatBRL, formatPct } from '@/lib/money'
import { ARTE_LABEL, CONFIANCA_PRECO, MOTIVO_PERDA, type MotivoPerda, ORCAMENTO_STATUS, orcamentoNumero, REGRA_PRECO } from '@/lib/orcamentos'
import { metodoLabel, type OrderCard } from '@/lib/orders'
import { supabase } from '@/lib/supabase'
import { cn } from '@/lib/utils'

const dataHora = (iso: string | null) => (iso ? new Date(iso).toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit', timeZone: 'America/Sao_Paulo' }) : '')

/** Aba Orçamentos do pedido. Margem, regra e confiança do preço aparecem só aqui, para o dono; nunca no PDF nem para o agente. */
function LucroPorMetodo({ id }: { id: string }) {
  const [aberto, setAberto] = useState(false)
  const { data } = useQuery({
    queryKey: ['orcamento-lucro-metodo', id],
    enabled: aberto,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('orcamento_lucro_por_metodo', { p_orcamento: id })
      if (error) throw new Error(error.message)
      return data as { receita: number; pior_caso: string; metodos: { metodo: string; taxa_pct: number; taxa_valor: number; lucro_liquido: number }[] }
    },
  })
  return (
    <details className="mt-2 text-xs" onToggle={(e) => setAberto((e.target as HTMLDetailsElement).open)}>
      <summary className="cursor-pointer font-bold text-muted-foreground">Taxa e lucro por método (só o dono vê)</summary>
      {data && (
        <table className="mt-1 w-full max-w-md tabular">
          <thead><tr className="text-left text-muted-foreground"><th>Método</th><th>Taxa</th><th>Lucro líquido</th></tr></thead>
          <tbody>
            {data.metodos.map((m) => (
              <tr key={m.metodo} className={m.metodo === data.pior_caso ? 'font-bold' : ''}>
                <td>{metodoLabel(m.metodo === 'cartao_credito_2x' ? 'cartao_credito' : m.metodo)}{m.metodo === 'cartao_credito_2x' ? ' em 2x (pior caso)' : ''}</td>
                <td>{formatPct(m.taxa_pct)} · {formatBRL(m.taxa_valor)}</td>
                <td>{formatBRL(m.lucro_liquido)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </details>
  )
}

/** Marca o orçamento como perdido. Motivo é obrigatório; observação também quando o motivo é Outro. */
function MarcarPerdido({ id, numero }: { id: string; numero: string }) {
  const toast = useToast()
  const [aberto, setAberto] = useState(false)
  const [motivo, setMotivo] = useState<MotivoPerda | ''>('')
  const [obs, setObs] = useState('')
  const perda = useRegistrarPerda()

  if (!aberto) {
    return (
      <Button size="sm" variant="ghost" className="mt-2" onClick={() => setAberto(true)}>
        Marcar como perdido
      </Button>
    )
  }

  const precisaObs = motivo === 'outro'
  return (
    <div className="mt-3 space-y-2 rounded-md border border-brand-red/30 p-3">
      <Label htmlFor={`perda-${id}`}>Motivo da perda (obrigatório)</Label>
      <Select id={`perda-${id}`} value={motivo} onChange={(e) => setMotivo(e.target.value as MotivoPerda | '')}>
        <option value="">Escolha o motivo</option>
        {(Object.keys(MOTIVO_PERDA) as MotivoPerda[]).map((m) => (
          <option key={m} value={m}>{MOTIVO_PERDA[m]}</option>
        ))}
      </Select>
      <Label htmlFor={`perda-obs-${id}`}>{precisaObs ? 'Observação (obrigatória)' : 'Observação (opcional)'}</Label>
      <Textarea id={`perda-obs-${id}`} rows={2} maxLength={500} value={obs} onChange={(e) => setObs(e.target.value)} />
      <div className="flex flex-wrap gap-2">
        <Button
          size="sm"
          disabled={!motivo || (precisaObs && !obs.trim()) || perda.isPending}
          onClick={() =>
            perda.mutate(
              { orcamentoId: id, motivo, obs: obs.trim() || null },
              {
                onSuccess: () => {
                  toast('ok', `Orçamento ${numero} marcado como perdido.`)
                  setAberto(false)
                },
                onError: (e) => toast('error', e.message),
              },
            )
          }
        >
          {perda.isPending ? 'Salvando…' : 'Salvar motivo'}
        </Button>
        <Button size="sm" variant="ghost" onClick={() => setAberto(false)}>Cancelar</Button>
      </div>
    </div>
  )
}

export function OrcamentosTab({ order }: { order: OrderCard }) {
  const toast = useToast()
  const { data, isLoading } = useOrcamentosDoPedido(order.id, order.contact.id)
  const [paraEnviar, setParaEnviar] = useState<{ id: string; numero: number; pdf_enviado_em: string | null } | null>(null)
  const gerar = useGerarPdfOrcamento()


  if (isLoading) return <div className="space-y-2 p-4"><Skeleton className="h-24 w-full" /><Skeleton className="h-24 w-full" /></div>
  if (!data?.length) {
    return <p className="m-4 rounded-md border border-dashed p-4 text-center text-sm text-muted-foreground">Nenhum orçamento ainda. O agente de IA monta o orçamento quando o cliente pede preço.</p>
  }

  return (
    <>
    <ul className="space-y-3 p-4">
      {data.map((o) => {
        const st = ORCAMENTO_STATUS[o.status]
        const vencido = !!o.validade_ate && new Date(o.validade_ate).getTime() < Date.now() && ['rascunho', 'enviado', 'aceito'].includes(o.status)
        const encerrado = ['pago', 'cancelado', 'perdido'].includes(o.status)
        return (
          <li key={o.id} className="rounded-md border p-3">
            <div className="flex flex-wrap items-start justify-between gap-2">
              <div>
                <p className="font-black tabular">
                  {orcamentoNumero(o.numero)}
                  {o.origem_id && <span className="ml-1.5 text-xs font-semibold text-muted-foreground">nova versão</span>}
                </p>
                <p className="text-xs text-muted-foreground">Criado em {dataHora(o.criado_em)}{o.teste ? ' · teste' : ''}{o.order_id ? '' : ' · sem pedido ligado'}</p>
              </div>
              <div className="flex items-center gap-1.5">
                {vencido && <Badge className="bg-brand-red/10 text-brand-red">Vencido</Badge>}
                <Badge className={cn(st.chip)}>{st.label}</Badge>
              </div>
            </div>

            <dl className="mt-2 grid grid-cols-2 gap-x-4 gap-y-1 text-sm sm:grid-cols-3">
              <div><dt className="text-xs text-muted-foreground">Valor</dt><dd className="font-bold tabular">{formatBRL(o.total)}</dd></div>
              <div><dt className="text-xs text-muted-foreground">Válido até</dt><dd className={cn('tabular', vencido && 'font-bold text-brand-red')}>{dataHora(o.validade_ate) || 'sem validade'}</dd></div>
              <div><dt className="text-xs text-muted-foreground">Arte</dt><dd>{ARTE_LABEL[o.arte_modo]}{o.arte_valor > 0 ? ` (${formatBRL(o.arte_valor)})` : ''}</dd></div>
              <div><dt className="text-xs text-muted-foreground" title="Só o dono vê">Margem líquida</dt><dd className="tabular">{o.margem_liquida_pct != null ? `${formatPct(o.margem_liquida_pct)} · ${formatBRL(o.lucro_liquido ?? 0)}` : 'sem cálculo'}</dd></div>
              <div><dt className="text-xs text-muted-foreground" title="Só o dono vê">Regra do preço</dt><dd>{o.regra_preco ? (REGRA_PRECO[o.regra_preco] ?? o.regra_preco) : 'sem regra'}</dd></div>
              <div><dt className="text-xs text-muted-foreground" title="Só o dono vê">Confiança</dt><dd>{o.confianca_preco ? CONFIANCA_PRECO[o.confianca_preco] : 'sem dado'}</dd></div>
            </dl>
            <LucroPorMetodo id={o.id} />
            {o.status === 'perdido' && o.motivo_perda && (
              <p className="mt-2 text-sm"><strong>Motivo da perda:</strong> {MOTIVO_PERDA[o.motivo_perda]}{o.motivo_perda_obs ? ` · ${o.motivo_perda_obs}` : ''}</p>
            )}
            {!encerrado && !o.teste && <MarcarPerdido id={o.id} numero={orcamentoNumero(o.numero)} />}

            <div className="mt-3 flex flex-wrap items-center gap-2">
              {o.pdf_path ? (
                <Button size="sm" variant="outline" onClick={() => abrirPdfOrcamento(o.pdf_path!).catch((e: Error) => toast('error', e.message))}>
                  <FileText className="h-4 w-4" aria-hidden /> Abrir PDF
                </Button>
              ) : (
                <Button
                  size="sm"
                  variant="outline"
                  disabled={encerrado || gerar.isPending}
                  onClick={() => gerar.mutate(o.id, { onSuccess: (r) => toast('ok', `PDF do ${r.numero} gerado. Nada foi enviado ao cliente.`), onError: (e) => toast('error', e.message) })}
                >
                  <FileText className="h-4 w-4" aria-hidden /> {gerar.isPending ? 'Gerando…' : 'Gerar PDF (sem enviar)'}
                </Button>
              )}
              <Button size="sm" disabled={encerrado || !o.conversation_id} onClick={() => setParaEnviar({ id: o.id, numero: o.numero, pdf_enviado_em: o.pdf_enviado_em ?? null })} title={!o.conversation_id ? 'Orçamento sem conversa de WhatsApp' : undefined}>
                <Send className="h-4 w-4" aria-hidden /> {o.pdf_enviado_em ? 'Reenviar PDF' : 'Enviar PDF ao cliente'}
              </Button>
              {o.link_pagamento && (
                <a className="inline-flex items-center gap-1 text-xs font-semibold text-link underline" href={o.link_pagamento} target="_blank" rel="noopener noreferrer">
                  Link de pagamento <ExternalLink className="h-3 w-3" aria-hidden />
                </a>
              )}
              {o.pdf_enviado_em && <span className="text-xs text-muted-foreground">Enviado em {dataHora(o.pdf_enviado_em)}</span>}
            </div>
          </li>
        )
      })}
    </ul>
    <EnviarPdfDialog
      open={!!paraEnviar}
      onOpenChange={(o) => !o && setParaEnviar(null)}
      orcamento={paraEnviar}
      janelaAberta
    />
    </>
  )
}
