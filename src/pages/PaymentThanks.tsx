import { CheckCircle2, Clock, XCircle } from 'lucide-react'
import { useSearchParams } from 'react-router-dom'

const TEXTOS = {
  ok: { icon: CheckCircle2, tom: 'text-brand-green', titulo: 'Pagamento recebido, obrigado!', texto: 'Recebemos o retorno do seu pagamento. A confirmação e os próximos passos do seu pedido chegam pelo WhatsApp.' },
  pendente: { icon: Clock, tom: 'text-ink', titulo: 'Pagamento em processamento', texto: 'Assim que o pagamento for confirmado, avisamos você pelo WhatsApp.' },
  falhou: { icon: XCircle, tom: 'text-brand-red', titulo: 'O pagamento não foi concluído', texto: 'Nenhum valor foi cobrado. Você pode tentar de novo pelo mesmo link ou falar com a gente pelo WhatsApp.' },
} as const

// Página pública de retorno do Mercado Pago. Não confirma pagamento: quem confirma é o servidor.
export default function PaymentThanks() {
  const [params] = useSearchParams()
  const r = params.get('r')
  const t = TEXTOS[r === 'pendente' || r === 'falhou' ? r : 'ok']
  const Icon = t.icon
  return (
    <main className="mx-auto flex min-h-screen max-w-md flex-col items-center justify-center px-6 text-center">
      <Icon className={`mb-4 h-14 w-14 ${t.tom}`} aria-hidden />
      <h1 className="text-2xl font-black">{t.titulo}</h1>
      <p className="mt-3 text-sm text-muted-foreground">{t.texto}</p>
      <p className="mt-8 text-xs text-muted-foreground">Sua Gráfica BH</p>
    </main>
  )
}
