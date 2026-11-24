import { useMemo, useState } from 'react'
import { BellRing, CheckCircle2, Inbox, XCircle } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { EmptyState } from '@/components/ui/empty-state'
import { Modal } from '@/components/ui/sheet'
import { Skeleton } from '@/components/ui/skeleton'
import { useToast } from '@/components/ui/toast'
import { usePagamentosPendentes, type PagamentoPendente } from '@/hooks/orders'
import { useTemplates } from '@/hooks/queries'
import { invokeFunction } from '@/lib/api'
import { formatPhone } from '@/lib/format'
import { formatBRL } from '@/lib/money'
import { orcamentoNumero } from '@/lib/orcamentos'
import { cn } from '@/lib/utils'

/** Qual template de utilidade (verdadeiro, sem precisar de opt-in de marketing) serve cada etapa do card. */
const TEMPLATE_POR_ETAPA: Record<PagamentoPendente['stage'], { template: string; rotulo: string }> = {
  cotando: { template: 'orcamento_pronto', rotulo: 'Cotando (orçamento enviado)' },
  aguardando_pagamento: { template: 'pagamento_pendente', rotulo: 'Aguardando pagamento' },
}

function montarVariaveis(p: PagamentoPendente): string[] {
  const nome = p.contact_name?.trim() || formatPhone(p.wa_id)
  if (p.stage === 'aguardando_pagamento') return [nome, orcamentoNumero(p.number), p.payment_link ?? '']
  return [nome, p.title?.trim() || orcamentoNumero(p.number), formatBRL(p.total)]
}

type Resultado = 'enviando' | 'ok' | 'erro'
type FiltroEtapa = 'todos' | PagamentoPendente['stage']

/** Botão + modal: lista quem está "cotando" (orçamento já enviado) ou "aguardando pagamento" (link ativo),
 * não orçado hoje, e dispara o template de utilidade certo para cada card em lote, selecionando quais quer. */
export function ReativarPagamentosPendentes() {
  const [open, setOpen] = useState(false)
  const toast = useToast()
  const { data: pendentes, isLoading } = usePagamentosPendentes()
  const { data: templates } = useTemplates()
  const [filtro, setFiltro] = useState<FiltroEtapa>('todos')
  const [selecionados, setSelecionados] = useState<Set<string>>(new Set())
  const [resultados, setResultados] = useState<Map<string, Resultado>>(new Map())
  const [enviando, setEnviando] = useState(false)

  const templatesProntos = useMemo(() => {
    const aprovados = new Map((templates ?? []).filter((t) => t.status === 'APPROVED').map((t) => [t.name, t]))
    return {
      cotando: aprovados.get(TEMPLATE_POR_ETAPA.cotando.template) ?? null,
      aguardando_pagamento: aprovados.get(TEMPLATE_POR_ETAPA.aguardando_pagamento.template) ?? null,
    }
  }, [templates])

  const visiveis = useMemo(() => (pendentes ?? []).filter((p) => filtro === 'todos' || p.stage === filtro), [pendentes, filtro])
  const contagem = { cotando: (pendentes ?? []).filter((p) => p.stage === 'cotando').length, aguardando_pagamento: (pendentes ?? []).filter((p) => p.stage === 'aguardando_pagamento').length }

  function abrir() {
    setFiltro('todos')
    setResultados(new Map())
    setSelecionados(new Set((pendentes ?? []).filter((p) => templatesProntos[p.stage]).map((p) => p.order_id)))
    setOpen(true)
  }

  function toggle(id: string) {
    setSelecionados((s) => {
      const next = new Set(s)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  function marcarTodosVisiveis(marcar: boolean) {
    setSelecionados((s) => {
      const next = new Set(s)
      for (const p of visiveis) {
        if (!templatesProntos[p.stage]) continue
        if (marcar) next.add(p.order_id)
        else next.delete(p.order_id)
      }
      return next
    })
  }

  async function disparar() {
    const alvos = (pendentes ?? []).filter((p) => selecionados.has(p.order_id) && templatesProntos[p.stage])
    setEnviando(true)
    let ok = 0
    let falhas = 0
    for (const p of alvos) {
      const tpl = templatesProntos[p.stage]!
      setResultados((r) => new Map(r).set(p.order_id, 'enviando'))
      try {
        await invokeFunction('whatsapp-send', {
          conversation_id: p.conversation_id,
          template_name: tpl.name,
          language: tpl.language,
          variables: montarVariaveis(p),
        })
        setResultados((r) => new Map(r).set(p.order_id, 'ok'))
        ok++
      } catch {
        setResultados((r) => new Map(r).set(p.order_id, 'erro'))
        falhas++
      }
    }
    setEnviando(false)
    toast(falhas ? 'error' : 'ok', falhas ? `${ok} enviado(s), ${falhas} falhou(aram).` : `${ok} mensagem(ns) enviada(s).`)
  }

  return (
    <>
      <Button variant="outline" size="sm" onClick={abrir}>
        <BellRing className="h-4 w-4" /> Reativar pagamentos pendentes
        {!!pendentes?.length && <span className="rounded-sm bg-secondary px-1.5 py-0.5 text-[11px] tabular">{pendentes.length}</span>}
      </Button>

      <Modal
        open={open}
        onOpenChange={setOpen}
        title="Reativar pedidos parados"
        description='Pedidos "cotando" (orçamento enviado) ou "aguardando pagamento" (link ativo), que não orçaram hoje. Cada card recebe o template de utilidade certo, sem precisar de opt-in de marketing.'
      >
        {isLoading && <Skeleton className="h-32" />}

        {!isLoading && !pendentes?.length && <EmptyState icon={Inbox} title="Nenhum pedido parado para reativar." />}

        {!isLoading && !!pendentes?.length && (
          <>
            <div className="mb-2 flex flex-wrap gap-1.5">
              {([
                ['todos', `Todos (${pendentes.length})`],
                ['cotando', `Cotando (${contagem.cotando})`],
                ['aguardando_pagamento', `Aguardando pagamento (${contagem.aguardando_pagamento})`],
              ] as [FiltroEtapa, string][]).map(([v, label]) => (
                <button
                  key={v}
                  type="button"
                  onClick={() => setFiltro(v)}
                  className={cn('rounded-sm px-2.5 py-1 text-xs font-semibold', filtro === v ? 'bg-primary text-primary-foreground' : 'bg-secondary text-muted-foreground hover:text-foreground')}
                >
                  {label}
                </button>
              ))}
            </div>

            {(['cotando', 'aguardando_pagamento'] as const).some((st) => !templatesProntos[st] && (pendentes ?? []).some((p) => p.stage === st)) && (
              <p className="mb-2 rounded-md border border-amber-300 bg-amber-50 p-2.5 text-xs text-amber-800">
                {(['cotando', 'aguardando_pagamento'] as const)
                  .filter((st) => !templatesProntos[st] && (pendentes ?? []).some((p) => p.stage === st))
                  .map((st) => `O template "${TEMPLATE_POR_ETAPA[st].template}" não está aprovado ou não foi sincronizado: os cards de "${TEMPLATE_POR_ETAPA[st].rotulo}" ficam sem envio até sincronizar em Templates.`)
                  .join(' ')}
              </p>
            )}

            <div className="mb-1.5 flex justify-end gap-3 text-xs">
              <button type="button" className="font-semibold text-primary hover:underline" onClick={() => marcarTodosVisiveis(true)}>Marcar visíveis</button>
              <button type="button" className="font-semibold text-muted-foreground hover:underline" onClick={() => marcarTodosVisiveis(false)}>Desmarcar visíveis</button>
            </div>

            <ul className="max-h-96 space-y-2 overflow-y-auto">
              {visiveis.map((p: PagamentoPendente) => {
                const r = resultados.get(p.order_id)
                const tpl = templatesProntos[p.stage]
                return (
                  <li key={p.order_id} className={cn('flex items-center gap-2 rounded-md border p-2.5 text-sm', !tpl && 'opacity-50', r === 'erro' && 'border-destructive/50 bg-destructive/5')}>
                    <input
                      type="checkbox"
                      className="h-4 w-4 accent-[var(--brand-blue)]"
                      checked={selecionados.has(p.order_id)}
                      disabled={enviando || !tpl}
                      onChange={() => toggle(p.order_id)}
                    />
                    <div className="min-w-0 flex-1">
                      <p className="truncate font-semibold">{p.contact_name?.trim() || formatPhone(p.wa_id)} · {orcamentoNumero(p.number)}</p>
                      <p className="truncate text-xs text-muted-foreground">
                        {TEMPLATE_POR_ETAPA[p.stage].rotulo} · {formatPhone(p.wa_id)} · parado há {p.dias_aberto} dia(s)
                        {p.stage === 'cotando' && ` · ${formatBRL(p.total)}`}
                      </p>
                    </div>
                    {r === 'enviando' && <span className="text-xs text-muted-foreground">enviando…</span>}
                    {r === 'ok' && <CheckCircle2 className="h-4 w-4 text-brand-green" />}
                    {r === 'erro' && <XCircle className="h-4 w-4 text-destructive" />}
                  </li>
                )
              })}
            </ul>
            <div className="mt-3 flex justify-end gap-2">
              <Button variant="outline" onClick={() => setOpen(false)} disabled={enviando}>Fechar</Button>
              <Button onClick={disparar} disabled={enviando || selecionados.size === 0}>
                {enviando ? 'Enviando…' : `Disparar para ${selecionados.size}`}
              </Button>
            </div>
          </>
        )}
      </Modal>
    </>
  )
}
