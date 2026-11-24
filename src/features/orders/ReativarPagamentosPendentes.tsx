import { useMemo, useState } from 'react'
import { BellRing, CheckCircle2, Inbox, XCircle } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { EmptyState } from '@/components/ui/empty-state'
import { Modal } from '@/components/ui/sheet'
import { Skeleton } from '@/components/ui/skeleton'
import { useToast } from '@/components/ui/toast'
import { usePagamentosPendentes, useRegistrarReativacao, type PagamentoPendente } from '@/hooks/orders'
import { useTemplates } from '@/hooks/queries'
import { invokeFunction } from '@/lib/api'
import { formatPhone } from '@/lib/format'
import { formatBRL } from '@/lib/money'
import { MOTIVO_PERDA, orcamentoNumero, type MotivoPerda } from '@/lib/orcamentos'
import { cn } from '@/lib/utils'

const COOLDOWN_DIAS = 7
const DIA_MS = 86_400_000

const ROTULO_ETAPA: Record<PagamentoPendente['stage'], string> = {
  cotando: 'Cotando (orçamento enviado)',
  aguardando_pagamento: 'Aguardando pagamento',
  perdido: 'Perdido',
}

type Acao = { tipo: 'template'; nome: string; linguagem: string; variaveis: string[] } | { tipo: 'livre'; texto: string }

function textoLivrePerdido(nome: string, produto: string): string {
  return `Oi, ${nome}! Vi aqui que ficamos sem retomar o seu pedido de ${produto}. Ainda tem interesse? Posso ver isso com você agora.`
}

function diasDesde(iso: string): number {
  return Math.floor((Date.now() - new Date(iso).getTime()) / DIA_MS)
}

type Resultado = 'enviando' | 'ok' | 'erro'
type FiltroEtapa = 'todos' | PagamentoPendente['stage']

/** Botão + modal: lista quem está "cotando", "aguardando pagamento" ou "perdido", não orçado hoje e sem
 * reativação recente, e dispara a ação certa por card: template de utilidade, mensagem livre (perdido com
 * janela aberta) ou template de marketing (perdido com opt-in), selecionando quais quer. */
export function ReativarPagamentosPendentes() {
  const [open, setOpen] = useState(false)
  const toast = useToast()
  const { data: pendentes, isLoading } = usePagamentosPendentes()
  const { data: templates } = useTemplates()
  const registrar = useRegistrarReativacao()
  const [filtro, setFiltro] = useState<FiltroEtapa>('todos')
  const [selecionados, setSelecionados] = useState<Set<string>>(new Set())
  const [resultados, setResultados] = useState<Map<string, Resultado>>(new Map())
  const [enviando, setEnviando] = useState(false)

  const tplPorNome = useMemo(() => new Map((templates ?? []).filter((t) => t.status === 'APPROVED').map((t) => [t.name, t])), [templates])

  function acaoPara(p: PagamentoPendente): { acao?: Acao; bloqueado?: string } {
    const nome = p.contact_name?.trim() || formatPhone(p.wa_id)
    if (p.stage === 'aguardando_pagamento') {
      const tpl = tplPorNome.get('pagamento_pendente')
      if (!tpl) return { bloqueado: 'Template "pagamento_pendente" não aprovado/sincronizado.' }
      return { acao: { tipo: 'template', nome: tpl.name, linguagem: tpl.language, variaveis: [nome, orcamentoNumero(p.number), p.payment_link ?? ''] } }
    }
    if (p.stage === 'cotando') {
      const tpl = tplPorNome.get('orcamento_pronto')
      if (!tpl) return { bloqueado: 'Template "orcamento_pronto" não aprovado/sincronizado.' }
      return { acao: { tipo: 'template', nome: tpl.name, linguagem: tpl.language, variaveis: [nome, p.title?.trim() || orcamentoNumero(p.number), formatBRL(p.total)] } }
    }
    // perdido: janela aberta manda texto livre (não depende de opt-in); fechada, só com opt-in de promoção
    const produto = p.title?.trim() || orcamentoNumero(p.number)
    if (p.janela_aberta) return { acao: { tipo: 'livre', texto: textoLivrePerdido(nome, produto) } }
    if (p.marketing_consent === 'opted_in') {
      const tpl = tplPorNome.get('retomar_orcamento')
      if (!tpl) return { bloqueado: 'Template "retomar_orcamento" não aprovado/sincronizado.' }
      return { acao: { tipo: 'template', nome: tpl.name, linguagem: tpl.language, variaveis: [nome, produto] } }
    }
    return { bloqueado: 'Janela de 24h fechada e sem opt-in de promoção: não dá para reativar sem falar com a pessoa.' }
  }

  function cooldownAtivo(p: PagamentoPendente): number | null {
    if (!p.ultima_reativacao_em) return null
    const dias = diasDesde(p.ultima_reativacao_em)
    return dias < COOLDOWN_DIAS ? dias : null
  }

  const visiveis = useMemo(() => (pendentes ?? []).filter((p) => filtro === 'todos' || p.stage === filtro), [pendentes, filtro])
  const contagem = {
    cotando: (pendentes ?? []).filter((p) => p.stage === 'cotando').length,
    aguardando_pagamento: (pendentes ?? []).filter((p) => p.stage === 'aguardando_pagamento').length,
    perdido: (pendentes ?? []).filter((p) => p.stage === 'perdido').length,
  }

  function podeMarcar(p: PagamentoPendente): boolean {
    return !acaoPara(p).bloqueado && cooldownAtivo(p) === null
  }

  function abrir() {
    setFiltro('todos')
    setResultados(new Map())
    setSelecionados(new Set((pendentes ?? []).filter(podeMarcar).map((p) => p.order_id)))
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

  function marcarVisiveis(marcar: boolean) {
    setSelecionados((s) => {
      const next = new Set(s)
      for (const p of visiveis) {
        if (!podeMarcar(p)) continue
        if (marcar) next.add(p.order_id)
        else next.delete(p.order_id)
      }
      return next
    })
  }

  async function disparar() {
    const alvos = (pendentes ?? []).filter((p) => selecionados.has(p.order_id) && podeMarcar(p))
    setEnviando(true)
    let ok = 0
    let falhas = 0
    for (const p of alvos) {
      const acao = acaoPara(p).acao!
      setResultados((r) => new Map(r).set(p.order_id, 'enviando'))
      try {
        await invokeFunction(
          'whatsapp-send',
          acao.tipo === 'template'
            ? { conversation_id: p.conversation_id, template_name: acao.nome, language: acao.linguagem, variables: acao.variaveis }
            : { conversation_id: p.conversation_id, text: acao.texto },
        )
        await registrar.mutateAsync({
          orderId: p.order_id,
          conversationId: p.conversation_id,
          stage: p.stage,
          canal: acao.tipo,
          templateName: acao.tipo === 'template' ? acao.nome : undefined,
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
        description='Pedidos "cotando", "aguardando pagamento" ou "perdido" que não orçaram hoje. Cada card recebe a ação certa (template de utilidade, mensagem livre ou template de marketing com opt-in).'
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
                ['perdido', `Perdido (${contagem.perdido})`],
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

            <div className="mb-1.5 flex justify-end gap-3 text-xs">
              <button type="button" className="font-semibold text-primary hover:underline" onClick={() => marcarVisiveis(true)}>Marcar visíveis</button>
              <button type="button" className="font-semibold text-muted-foreground hover:underline" onClick={() => marcarVisiveis(false)}>Desmarcar visíveis</button>
            </div>

            <ul className="max-h-96 space-y-2 overflow-y-auto">
              {visiveis.map((p: PagamentoPendente) => {
                const r = resultados.get(p.order_id)
                const { acao, bloqueado } = acaoPara(p)
                const diasCooldown = cooldownAtivo(p)
                const motivo = bloqueado ?? (diasCooldown !== null ? `Já reativado há ${diasCooldown} dia(s); espera ${COOLDOWN_DIAS - diasCooldown} dia(s) para reenviar.` : null)
                return (
                  <li key={p.order_id} className={cn('flex items-center gap-2 rounded-md border p-2.5 text-sm', !!motivo && 'opacity-60', r === 'erro' && 'border-destructive/50 bg-destructive/5')}>
                    <input
                      type="checkbox"
                      className="h-4 w-4 accent-[var(--brand-blue)]"
                      checked={selecionados.has(p.order_id)}
                      disabled={enviando || !!motivo}
                      onChange={() => toggle(p.order_id)}
                    />
                    <div className="min-w-0 flex-1">
                      <p className="truncate font-semibold">{p.contact_name?.trim() || formatPhone(p.wa_id)} · {orcamentoNumero(p.number)}</p>
                      <p className="truncate text-xs text-muted-foreground">
                        {ROTULO_ETAPA[p.stage]} · {formatPhone(p.wa_id)} · parado há {p.dias_aberto} dia(s)
                        {p.stage === 'cotando' && ` · ${formatBRL(p.total)}`}
                        {p.stage === 'perdido' && p.motivo_perda && ` · ${MOTIVO_PERDA[p.motivo_perda as MotivoPerda] ?? p.motivo_perda}`}
                      </p>
                      {motivo && <p className="truncate text-xs font-semibold text-amber-700">{motivo}</p>}
                      {!motivo && acao?.tipo === 'livre' && <p className="truncate text-xs text-muted-foreground">Mensagem livre (janela de 24h aberta)</p>}
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
