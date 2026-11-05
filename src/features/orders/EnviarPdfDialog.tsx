import { useEffect, useState } from 'react'
import { Button } from '@/components/ui/button'
import { Sheet } from '@/components/ui/sheet'
import { useToast } from '@/components/ui/toast'
import { usePreverOrcamento, useReenviarOrcamento } from '@/hooks/orcamentos'
import { orcamentoNumero } from '@/lib/orcamentos'

/** Legenda que vai junto do PDF no WhatsApp. Única fonte: o que aparece aqui é exatamente o que é enviado. */
export const legendaOrcamento = (numero: number) => `Orçamento ${orcamentoNumero(numero)} em PDF. Qualquer dúvida, é só responder por aqui.`

interface Props {
  open: boolean
  onOpenChange: (o: boolean) => void
  orcamento: { id: string; numero: number; pdf_enviado_em: string | null } | null
  /** a janela de 24 h precisa estar aberta; se não, o envio é recusado pelo servidor */
  janelaAberta: boolean
}

/** Confirmação antes de mandar o PDF: mostra o arquivo e a mensagem exata, e só envia com autorização explícita. */
export function EnviarPdfDialog({ open, onOpenChange, orcamento, janelaAberta }: Props) {
  const toast = useToast()
  const preparar = usePreverOrcamento()
  const enviar = useReenviarOrcamento()
  const [pdfUrl, setPdfUrl] = useState<string | null>(null)
  const [erro, setErro] = useState<string | null>(null)
  const [autorizado, setAutorizado] = useState(false)
  const legenda = orcamento ? legendaOrcamento(orcamento.numero) : ''

  useEffect(() => {
    if (!open || !orcamento) return
    setPdfUrl(null)
    setErro(null)
    setAutorizado(false)
    preparar.mutate(orcamento.id, {
      onSuccess: (r) => setPdfUrl(r.pdf_url ?? null),
      onError: (e) => setErro(e.message),
    })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, orcamento?.id])

  function confirmar() {
    if (!orcamento || !autorizado) return
    enviar.mutate(
      { orcamentoId: orcamento.id, texto: legenda },
      {
        onSuccess: () => {
          toast('ok', `Orçamento ${orcamentoNumero(orcamento.numero)} enviado no WhatsApp.`)
          onOpenChange(false)
        },
        onError: (e) => setErro(e.message),
      },
    )
  }

  const pronto = !!pdfUrl && !preparar.isPending && !erro
  return (
    <Sheet open={open} onOpenChange={onOpenChange} title="Conferir antes de enviar" description={orcamento ? `Orçamento ${orcamentoNumero(orcamento.numero)}` : undefined} className="sm:max-w-lg">
      <div className="min-h-0 flex-1 space-y-4 overflow-y-auto p-4 text-sm">
        <section className="space-y-1">
          <p className="text-xs font-bold uppercase text-muted-foreground">1. PDF que o cliente vai receber</p>
          {preparar.isPending && <p className="text-muted-foreground">Gerando o PDF…</p>}
          {pdfUrl && (
            <a href={pdfUrl} target="_blank" rel="noopener noreferrer" className="inline-flex min-h-11 items-center font-semibold text-link underline">
              Abrir o PDF para conferir
            </a>
          )}
        </section>

        <section className="space-y-1">
          <p className="text-xs font-bold uppercase text-muted-foreground">2. Mensagem que vai junto (exatamente esta)</p>
          <p className="whitespace-pre-wrap break-words rounded-md border bg-secondary/60 p-3">{legenda}</p>
        </section>

        {orcamento?.pdf_enviado_em && (
          <p className="rounded-md border border-brand-yellow bg-brand-yellow/20 px-3 py-2">
            Este PDF já foi enviado ao cliente. Enviar de novo gera outra mensagem no WhatsApp.
          </p>
        )}
        {!janelaAberta && (
          <p className="rounded-md border border-destructive/30 bg-destructive/5 px-3 py-2">
            A janela de atendimento está fechada. O WhatsApp só deixa enviar o PDF nas 24 h depois da última mensagem do cliente.
          </p>
        )}
        {erro && <p role="alert" className="rounded-md border border-destructive/30 bg-destructive/5 px-3 py-2 text-destructive">{erro}</p>}

        <section className="space-y-3 border-t pt-4">
          <label className="flex min-h-11 items-start gap-2">
            <input type="checkbox" className="mt-1 h-5 w-5" checked={autorizado} onChange={(e) => setAutorizado(e.target.checked)} />
            <span>Li o PDF e a mensagem e autorizo o envio ao cliente agora.</span>
          </label>
          <div className="flex flex-wrap justify-end gap-2">
            <Button variant="outline" onClick={() => onOpenChange(false)}>Cancelar</Button>
            <Button onClick={confirmar} disabled={!pronto || !autorizado || !janelaAberta || enviar.isPending}>
              {enviar.isPending ? 'Enviando…' : 'Enviar ao cliente'}
            </Button>
          </div>
        </section>
      </div>
    </Sheet>
  )
}
