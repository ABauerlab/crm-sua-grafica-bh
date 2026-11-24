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
import { orcamentoNumero } from '@/lib/orcamentos'
import { cn } from '@/lib/utils'

const TEMPLATE = 'pagamento_pendente'

type Resultado = 'enviando' | 'ok' | 'erro'

/** Botão + modal: lista quem está com pagamento pendente (link ativo, não orçado hoje) e dispara
 * o template de utilidade "pagamento_pendente" (nome, nº do pedido, link) em lote, um clique por envio. */
export function ReativarPagamentosPendentes() {
  const [open, setOpen] = useState(false)
  const toast = useToast()
  const { data: pendentes, isLoading } = usePagamentosPendentes()
  const { data: templates } = useTemplates()
  const [selecionados, setSelecionados] = useState<Set<string>>(new Set())
  const [resultados, setResultados] = useState<Map<string, Resultado>>(new Map())
  const [enviando, setEnviando] = useState(false)

  const tpl = useMemo(() => (templates ?? []).find((t) => t.name === TEMPLATE && t.status === 'APPROVED') ?? null, [templates])

  function abrir() {
    setResultados(new Map())
    setSelecionados(new Set((pendentes ?? []).map((p) => p.order_id)))
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

  async function disparar() {
    if (!tpl) return
    const alvos = (pendentes ?? []).filter((p) => selecionados.has(p.order_id))
    setEnviando(true)
    let ok = 0
    let falhas = 0
    for (const p of alvos) {
      setResultados((r) => new Map(r).set(p.order_id, 'enviando'))
      try {
        await invokeFunction('whatsapp-send', {
          conversation_id: p.conversation_id,
          template_name: tpl.name,
          language: tpl.language,
          variables: [p.contact_name?.trim() || formatPhone(p.wa_id), orcamentoNumero(p.number), p.payment_link],
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
        title="Reativar pagamentos pendentes"
        description='Pedidos com link de pagamento ativo, sem pagar, que não orçaram hoje. Envia o template de utilidade "pagamento_pendente" (não precisa de opt-in de marketing).'
      >
        {isLoading && <Skeleton className="h-32" />}

        {!isLoading && !tpl && (
          <p className="rounded-md border border-amber-300 bg-amber-50 p-3 text-sm text-amber-800">
            O template "pagamento_pendente" não está aprovado ou não foi sincronizado. Sincronize em Templates e tente de novo.
          </p>
        )}

        {!isLoading && tpl && (pendentes?.length ?? 0) === 0 && <EmptyState icon={Inbox} title="Nenhum pagamento pendente para reativar." />}

        {!isLoading && tpl && !!pendentes?.length && (
          <>
            <ul className="max-h-96 space-y-2 overflow-y-auto">
              {pendentes.map((p: PagamentoPendente) => {
                const r = resultados.get(p.order_id)
                return (
                  <li key={p.order_id} className={cn('flex items-center gap-2 rounded-md border p-2.5 text-sm', r === 'erro' && 'border-destructive/50 bg-destructive/5')}>
                    <input
                      type="checkbox"
                      className="h-4 w-4 accent-[var(--brand-blue)]"
                      checked={selecionados.has(p.order_id)}
                      disabled={enviando}
                      onChange={() => toggle(p.order_id)}
                    />
                    <div className="min-w-0 flex-1">
                      <p className="truncate font-semibold">{p.contact_name?.trim() || formatPhone(p.wa_id)} · {orcamentoNumero(p.number)}</p>
                      <p className="truncate text-xs text-muted-foreground">{formatPhone(p.wa_id)} · parado há {p.dias_aberto} dia(s)</p>
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
