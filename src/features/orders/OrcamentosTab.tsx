import { useQuery } from '@tanstack/react-query'
import { ExternalLink, FileText, Send } from 'lucide-react'
import { useState } from 'react'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Skeleton } from '@/components/ui/skeleton'
import { useToast } from '@/components/ui/toast'
import { abrirPdfOrcamento, useOrcamentosDoPedido, useReenviarOrcamento } from '@/hooks/orcamentos'
import { formatBRL, formatPct } from '@/lib/money'
import { ARTE_LABEL, CONFIANCA_PRECO, ORCAMENTO_STATUS, orcamentoNumero, REGRA_PRECO } from '@/lib/orcamentos'
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

export function OrcamentosTab({ order }: { order: OrderCard }) {
  const toast = useToast()
  const { data, isLoading } = useOrcamentosDoPedido(order.id, order.contact.id)
  const reenviar = useReenviarOrcamento()

  const enviar = (id: string) =>
    reenviar.mutate(id, {
      onSuccess: (r) => toast('ok', r.renovado ? `O orçamento tinha vencido. Gerei o ${r.numero} com tudo recalculado e enviei.` : `Orçamento ${r.numero} enviado no WhatsApp.`),
      onError: (e) => toast('error', e.message),
    })

  if (isLoading) return <div className="space-y-2 p-4"><Skeleton className="h-24 w-full" /><Skeleton className="h-24 w-full" /></div>
  if (!data?.length) {
    return <p className="m-4 rounded-md border border-dashed p-4 text-center text-sm text-muted-foreground">Nenhum orçamento ainda. O agente de IA monta o orçamento quando o cliente pede preço.</p>
  }

  return (
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

            <div className="mt-3 flex flex-wrap items-center gap-2">
              <Button size="sm" variant="outline" disabled={!o.pdf_path} onClick={() => abrirPdfOrcamento(o.pdf_path!).catch((e: Error) => toast('error', e.message))}>
                <FileText className="h-4 w-4" aria-hidden /> {o.pdf_path ? 'Abrir PDF' : 'PDF ainda não gerado'}
              </Button>
              <Button size="sm" disabled={encerrado || !o.conversation_id || reenviar.isPending} onClick={() => enviar(o.id)} title={!o.conversation_id ? 'Orçamento sem conversa de WhatsApp' : undefined}>
                <Send className="h-4 w-4" aria-hidden /> {reenviar.isPending ? 'Enviando…' : o.pdf_enviado_em ? 'Reenviar' : 'Enviar'}
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
  )
}
