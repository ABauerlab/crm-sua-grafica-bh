'use client'
import { useState } from 'react'
import { Check, Copy, Loader2, QrCode } from 'lucide-react'
import { brl } from '@/lib/site'
import { chamar, dataHora } from '@/lib/pagar'

interface PixPronto { copia_e_cola: string; qr_base64: string | null; expira_em: string | null }

/** Pix dentro do nosso site: QR Code e copia e cola, sem abrir o app do Mercado Pago. O valor é calculado no servidor. */
export function PagamentoPix({ token, total, onErro }: { token: string; total: number; onErro: (m: string) => void }) {
  const [pix, setPix] = useState<PixPronto | null>(null)
  const [gerando, setGerando] = useState(false)
  const [copiado, setCopiado] = useState(false)

  async function gerar() {
    setGerando(true)
    const r = await chamar<{ ok?: boolean; mensagem?: string; pix?: PixPronto }>('processar', { token, form: { payment_method_id: 'pix' } })
    setGerando(false)
    if (r.dados.ok && r.dados.pix) setPix(r.dados.pix)
    else onErro(r.dados.mensagem ?? 'Não conseguimos gerar o Pix agora. Tente de novo ou pague no cartão.')
  }
  async function copiar() {
    if (!pix) return
    try { await navigator.clipboard.writeText(pix.copia_e_cola) } catch {
      const t = document.getElementById('pix-codigo') as HTMLTextAreaElement | null
      t?.select(); document.execCommand('copy')
    }
    setCopiado(true); setTimeout(() => setCopiado(false), 2500)
  }

  if (!pix) {
    return (
      <div className="text-center">
        <p className="mb-1 text-sm text-black/70">Aprovação na hora, de qualquer banco, todos os dias.</p>
        <button type="button" onClick={gerar} disabled={gerando} className="inline-flex h-14 w-full items-center justify-center gap-2 rounded-xl bg-[#0E8A3E] px-6 text-lg font-black text-white shadow-md hover:brightness-110 disabled:opacity-70">
          {gerando ? <><Loader2 className="h-5 w-5 animate-spin" aria-hidden />Gerando o Pix...</> : <><QrCode className="h-5 w-5" aria-hidden />Pagar {brl(total)} no Pix</>}
        </button>
      </div>
    )
  }
  return (
    <div className="entra text-center">
      <p className="text-sm font-bold">Pague {brl(total)} no Pix</p>
      {pix.qr_base64 && (
        // eslint-disable-next-line @next/next/no-img-element
        <img src={`data:image/png;base64,${pix.qr_base64}`} alt="QR Code do Pix" className="mx-auto my-3 h-52 w-52 rounded-lg border border-black/10 bg-white p-2" />
      )}
      <ol className="mx-auto mb-3 max-w-sm space-y-1 text-left text-sm text-black/75">
        <li><b>1.</b> Abra o app do seu banco e escolha pagar com Pix.</li>
        <li><b>2.</b> Leia o QR Code ou use o código copia e cola abaixo.</li>
        <li><b>3.</b> Confirme. Esta tela atualiza sozinha quando o pagamento cair.</li>
      </ol>
      <textarea id="pix-codigo" readOnly value={pix.copia_e_cola} rows={3} onFocus={(e) => e.currentTarget.select()} className="w-full resize-none rounded-lg border border-black/20 bg-papel p-2 font-mono text-xs" aria-label="Código Pix copia e cola" />
      <button type="button" onClick={copiar} className="mt-2 inline-flex h-12 w-full items-center justify-center gap-2 rounded-xl bg-tinta px-5 font-bold text-white hover:bg-magenta">
        {copiado ? <><Check className="h-5 w-5" aria-hidden />Código copiado!</> : <><Copy className="h-5 w-5" aria-hidden />Copiar código Pix</>}
      </button>
      <p className="mt-3 flex items-center justify-center gap-2 text-sm font-semibold text-black/70"><Loader2 className="h-4 w-4 animate-spin" aria-hidden />Aguardando o pagamento{pix.expira_em ? ` (vale até ${dataHora(pix.expira_em)})` : ''}</p>
    </div>
  )
}
