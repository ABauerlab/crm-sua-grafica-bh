'use client'
import { useEffect, useRef, useState } from 'react'
import { initMercadoPago, Payment } from '@mercadopago/sdk-react'
import { chamar } from '@/lib/pagar'
import { brl } from '@/lib/site'

declare global { interface Window { MP_DEVICE_SESSION_ID?: string } }
let iniciado: string | null = null

interface Props { token: string; total: number; email: string | null; chavePublica: string; maxParcelas: number; onAprovado: () => void; onAnalise: () => void; onErro: (m: string | null) => void }

/** Payment Brick oficial só com cartão de crédito (o Pix é nosso, acima). Parcelas limitadas a 2x; valor e cobrança são do servidor. */
export default function PagamentoCartao({ token, total, email, chavePublica, maxParcelas, onAprovado, onAnalise, onErro }: Props) {
  const [pronto, setPronto] = useState(false)
  const montado = useRef(true)
  useEffect(() => {
    montado.current = true
    if (iniciado !== chavePublica) { initMercadoPago(chavePublica, { locale: 'pt-BR' }); iniciado = chavePublica }
    return () => { montado.current = false }
  }, [chavePublica])

  return (
    <div>
      {!pronto && <p className="py-6 text-center text-sm text-black/60">Carregando o formulário seguro do cartão...</p>}
      {/* o Brick refaz o formulário quando o total muda (arte ou item acrescentado) */}
      <Payment
        key={Math.round(total * 100)}
        initialization={{ amount: total, payer: email ? { email } : undefined }}
        customization={{
          paymentMethods: { creditCard: 'all', maxInstallments: maxParcelas },
          visual: { hideFormTitle: true, style: { theme: 'default', customVariables: { baseColor: '#E6007E', formBackgroundColor: '#ffffff', borderRadiusMedium: '10px', borderRadiusLarge: '12px' } } },
        }}
        onReady={() => setPronto(true)}
        onError={() => onErro('Não conseguimos carregar o formulário do cartão. Atualize a página ou pague no Pix.')}
        onSubmit={async ({ formData }) => {
          onErro(null)
          const r = await chamar<{ ok?: boolean; status?: string; mensagem?: string }>('processar', { token, form: formData, device_id: window.MP_DEVICE_SESSION_ID })
          if (!r.dados.ok) { onErro(r.dados.mensagem ?? 'Não foi possível processar o cartão. Tente de novo.'); throw new Error('falhou') }
          if (r.dados.status === 'approved') { onAprovado(); return }
          if (r.dados.status === 'in_process') { onAnalise(); return }
          onErro(r.dados.mensagem ?? 'O cartão foi recusado. Tente outro cartão ou pague no Pix.')
          throw new Error('recusado')
        }}
      />
      <p className="mt-3 text-center text-xs text-black/55">À vista {brl(total)} ou {maxParcelas}x de {brl(Math.round((total / maxParcelas) * 100) / 100)} sem juros.</p>
    </div>
  )
}
