'use client'
import { useState } from 'react'
import { Loader2, MapPin, Store, Truck } from 'lucide-react'
import { brl } from '@/lib/site'
import { chamar, dataCurta, type Checkout, type CotacaoFrete } from '@/lib/pagar'

const mascara = (v: string) => v.replace(/\D/g, '').slice(0, 8).replace(/^(\d{5})(\d)/, '$1-$2')

/** Entrega opcional: o cliente digita o CEP, vê as opções do SuperFrete (ou a entrega grátis nos bairros centrais) e o total e o orçamento se atualizam. */
export function FreteCep({ token, c, ocupado, onMudou }: { token: string; c: Checkout; ocupado: boolean; onMudou: () => void }) {
  const [cep, setCep] = useState('')
  const [cot, setCot] = useState<CotacaoFrete | null>(null)
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState<string | null>(null)
  const comFrete = !!c.frete && c.frete.valor > 0

  async function calcular(e?: React.FormEvent) {
    e?.preventDefault()
    if (cep.replace(/\D/g, '').length !== 8) return setMsg('Digite os 8 números do CEP.')
    setBusy(true); setMsg(null)
    const r = await chamar<CotacaoFrete>('dados', { acao: 'frete_cotar', token, cep })
    setBusy(false)
    if (!r.dados.ok) { setCot(null); return setMsg(r.dados.mensagem ?? 'Não conseguimos calcular o frete agora.') }
    setCot(r.dados)
  }

  async function escolher(servico: string) {
    setBusy(true); setMsg(null)
    const r = await chamar('dados', { acao: 'frete_definir', token, cep, servico })
    setBusy(false)
    if (!r.dados.ok) return setMsg(String(r.dados.mensagem ?? 'Não foi possível atualizar a entrega.'))
    onMudou()
  }

  const opc = 'flex min-h-14 w-full items-center gap-3 rounded-xl border-2 border-black/10 p-3 text-left text-sm hover:border-magenta/50 disabled:opacity-60'
  return (
    <section aria-labelledby="frete-t" className="rounded-xl2 bg-white p-5 shadow-sm">
      <h2 id="frete-t" className="text-lg font-black">Entrega (opcional)</h2>
      <p className="mb-3 text-sm text-black/65">Quer receber em casa? Digite o CEP e escolha. Se preferir, retire no balcão da Praça Sete sem custo.</p>
      {comFrete && (
        <div className="mb-3 flex items-center justify-between gap-2 rounded-lg bg-[#0E8A3E]/5 p-3 text-sm">
          <span className="flex min-w-0 items-center gap-2"><Truck className="h-4 w-4 shrink-0 text-[#0E8A3E]" aria-hidden /><span className="min-w-0 break-words font-semibold">{c.frete!.descricao} · {brl(c.frete!.valor)}</span></span>
          <button type="button" disabled={busy || ocupado} onClick={() => void escolher('retirada')} className="shrink-0 text-xs font-bold text-magenta underline">Retirar no balcão</button>
        </div>
      )}
      <form onSubmit={calcular} className="flex gap-2">
        <label className="sr-only" htmlFor="cep">CEP</label>
        <input id="cep" inputMode="numeric" autoComplete="postal-code" placeholder="CEP (00000-000)" value={cep} onChange={(e) => setCep(mascara(e.target.value))} className="h-12 min-w-0 flex-1 rounded-lg border border-black/15 px-3 text-base" />
        <button type="submit" disabled={busy || ocupado} className="inline-flex h-12 shrink-0 items-center gap-1.5 rounded-lg bg-tinta px-4 text-sm font-bold text-white hover:bg-magenta disabled:opacity-60">
          {busy ? <Loader2 className="h-4 w-4 animate-spin" aria-hidden /> : <MapPin className="h-4 w-4" aria-hidden />}Calcular
        </button>
      </form>
      {msg && <p role="alert" className="mt-3 rounded-lg bg-red-50 p-3 text-sm font-semibold text-red-700">{msg}</p>}
      {cot?.ok && (
        <div className="entra mt-3 space-y-2">
          <p className="text-sm text-black/65">{[cot.endereco?.bairro, cot.endereco?.cidade && `${cot.endereco.cidade}/${cot.endereco.uf}`].filter(Boolean).join(' · ')}</p>
          {cot.frete_gratis && <button type="button" disabled={busy} onClick={() => void escolher('gratis')} className={opc}><Truck className="h-5 w-5 shrink-0 text-[#0E8A3E]" aria-hidden /><span className="flex-1"><b>Entrega grátis</b><br /><span className="text-black/60">Na sua região, combinada pelo WhatsApp</span></span><b className="text-[#0E8A3E]">Grátis</b></button>}
          {(cot.envio?.opcoes ?? []).map((o) => (
            <button key={o.servico} type="button" disabled={busy} onClick={() => void escolher(o.servico)} className={opc}>
              <Truck className="h-5 w-5 shrink-0 text-magenta" aria-hidden />
              <span className="min-w-0 flex-1"><b>{o.nome}</b><br /><span className="text-black/60">{o.prazo_dias ? `até ${o.prazo_dias} dias úteis depois de pronto` : 'prazo informado na postagem'}</span></span>
              <b className="shrink-0">{brl(o.valor)}</b>
            </button>
          ))}
          {!cot.frete_gratis && !(cot.envio?.opcoes?.length) && <p className="rounded-lg bg-papel p-3 text-sm text-black/70">Não conseguimos cotar o envio para este CEP agora. Retire no balcão ou fale com a gente no WhatsApp.</p>}
          <button type="button" disabled={busy} onClick={() => void escolher('retirada')} className={opc}><Store className="h-5 w-5 shrink-0 text-black/55" aria-hidden /><span className="flex-1"><b>Retirar no balcão</b><br /><span className="text-black/60">Praça Sete, com hora marcada</span></span><b className="text-[#0E8A3E]">Grátis</b></button>
        </div>
      )}
      {c.prazo.data_prevista && <p className="mt-3 text-xs text-black/55">Previsão de produção: {dataCurta(c.prazo.data_prevista)}. O envio soma o prazo da transportadora.</p>}
    </section>
  )
}
