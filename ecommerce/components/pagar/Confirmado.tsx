import { MessageCircle } from 'lucide-react'
import { brl, linkWhatsApp } from '@/lib/site'
import { dataCurta, type Checkout } from '@/lib/pagar'

/** Tela de pagamento confirmado: valor, forma de pagamento (com parcelas) e o que fazer com a arte. */
export function Confirmado({ c }: { c: Checkout }) {
  const parcelas = c.pagamento.parcelas_pagas ?? 1
  const semJuros = c.pagamento.parcelas_sem_juros ?? 2
  const metodo = c.pagamento.metodo_pago === 'pix' ? 'Pix' : parcelas > semJuros ? `Cartão de crédito em ${parcelas}x (com juros do Mercado Pago)` : parcelas > 1 ? `Cartão de crédito em ${parcelas}x de ${brl(Math.round((c.total / parcelas) * 100) / 100)} sem juros` : 'Cartão de crédito à vista'
  const arte = c.arte.atual
  const passo = arte === 'criacao'
    ? 'Nossa equipe vai chamar você no WhatsApp para entender a sua marca e criar a arte. Se já tiver logo, cores ou referências, é só mandar lá.'
    : arte === 'conferencia'
      ? 'Envie o seu arquivo pelo WhatsApp. A gente confere medidas, sangria e resolução e ajusta o que for preciso antes de imprimir.'
      : 'Envie o arquivo da sua arte pelo WhatsApp. Vamos conferir se está nos gabaritos antes de imprimir.'
  const data = dataCurta(c.prazo.data_prevista)
  const msg = `Olá! Acabei de pagar o pedido ${c.pedido.numero} no site e quero ${arte === 'criacao' ? 'começar a criação da minha arte' : 'enviar o arquivo da minha arte'}.`
  return (
    <div className="entra mx-auto max-w-xl rounded-xl2 bg-white p-6 text-center shadow-sm sm:p-8">
      <svg viewBox="0 0 64 64" className="pop mx-auto h-24 w-24" aria-hidden>
        <circle cx="32" cy="32" r="30" fill="#0E8A3E" />
        <path className="check-traco" d="M18 33l10 10 19-21" fill="none" stroke="#fff" strokeWidth="6" strokeLinecap="round" strokeLinejoin="round" />
      </svg>
      <h1 className="mt-4 text-3xl font-black">Pagamento confirmado!</h1>
      <p className="mt-1 text-black/70">Obrigado pela confiança. Já mandamos a confirmação no seu WhatsApp (final {c.cliente.whatsapp_final}).</p>
      <dl className="mx-auto mt-5 max-w-sm space-y-1.5 rounded-lg bg-papel p-4 text-left text-sm">
        <div className="flex justify-between gap-3"><dt className="text-black/60">Pedido</dt><dd className="font-bold">{c.pedido.numero}</dd></div>
        <div className="flex justify-between gap-3"><dt className="text-black/60">Valor pago</dt><dd className="font-bold">{brl(c.total)}</dd></div>
        <div className="flex justify-between gap-3"><dt className="text-black/60">Forma</dt><dd className="text-right font-bold">{metodo}</dd></div>
        {data && <div className="flex justify-between gap-3"><dt className="text-black/60">Previsão</dt><dd className="text-right font-bold">{data}</dd></div>}
      </dl>
      <div className="mt-5 rounded-xl border-2 border-magenta/30 bg-magenta/5 p-4 text-left">
        <p className="font-black">Próximo passo: a sua arte</p>
        <p className="mt-1 text-sm text-black/75">{passo}</p>
        <p className="mt-1 text-xs text-black/55">O prazo de produção conta a partir da aprovação da arte.</p>
      </div>
      <a href={linkWhatsApp(msg)} target="_blank" rel="noopener" className="mt-5 inline-flex h-14 w-full items-center justify-center gap-2 rounded-xl bg-[#25d366] px-6 text-lg font-black text-white shadow-md hover:brightness-105">
        <MessageCircle className="h-6 w-6" aria-hidden />Falar com a gente no WhatsApp
      </a>
    </div>
  )
}
