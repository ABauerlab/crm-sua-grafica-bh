import { Calendar, Truck } from 'lucide-react'
import { brl } from '@/lib/site'
import { dataCurta, dataHora, type Checkout } from '@/lib/pagar'

/** Resumo completo do pedido: itens, descontos, total, entrega, prazo e como pagar. Sem custo, fornecedor nem SKU. */
export function Resumo({ c, onRemover, ocupado }: { c: Checkout; onRemover: (id: string) => void; ocupado: boolean }) {
  const data = dataCurta(c.prazo.data_prevista)
  return (
    <section aria-labelledby="resumo" className="rounded-xl2 bg-white p-5 shadow-sm">
      <div className="mb-3 flex items-baseline justify-between gap-2">
        <h2 id="resumo" className="text-lg font-black">Resumo do pedido</h2>
        <span className="rounded-full bg-tinta px-3 py-1 text-xs font-bold text-white">{c.pedido.numero}</span>
      </div>
      <ul className="divide-y divide-black/10">
        {c.itens.map((i, k) => (
          <li key={i.id ?? k} className="flex gap-3 py-3 text-sm">
            <div className="min-w-0 flex-1">
              <p className="font-semibold leading-snug">{i.descricao}</p>
              <p className="text-black/60">{i.quantidade} x {brl(i.unitario)}</p>
              {i.extra && i.id && (
                <button type="button" disabled={ocupado} onClick={() => onRemover(i.id!)} className="mt-1 text-xs font-semibold text-magenta underline disabled:opacity-50">Remover do pedido</button>
              )}
            </div>
            <p className="shrink-0 font-bold">{brl(i.subtotal)}</p>
          </li>
        ))}
      </ul>
      <dl className="mt-2 space-y-1.5 border-t border-black/10 pt-3 text-sm">
        <div className="flex justify-between"><dt className="text-black/70">Subtotal</dt><dd>{brl(c.subtotal)}</dd></div>
        {c.desconto_valor > 0 && <div className="flex justify-between text-[#0E8A3E]"><dt>Desconto{c.desconto_pct ? ` (${String(c.desconto_pct).replace('.', ',')}%)` : ''}</dt><dd>- {brl(c.desconto_valor)}</dd></div>}
        <div className="flex justify-between"><dt className="text-black/70">Frete</dt><dd className="font-semibold text-[#0E8A3E]">Grátis</dd></div>
        <div className="flex items-baseline justify-between border-t border-black/10 pt-2 text-base"><dt className="font-black">Total</dt><dd className="text-2xl font-black">{brl(c.total)}</dd></div>
      </dl>
      <div className="mt-4 rounded-lg bg-papel p-3 text-sm">
        <p className="font-bold">Como você pode pagar</p>
        <ul className="mt-1 space-y-0.5 text-black/75">
          <li><b>Pix</b> de qualquer banco: {brl(c.pagamento.pix)}</li>
          <li><b>Cartão de crédito</b>: 1x de {brl(c.pagamento.parcelas[0].valor)} ou {c.pagamento.max_parcelas}x de {brl(c.pagamento.parcelas[1].valor)} <b>sem juros</b></li>
        </ul>
      </div>
      <ul className="mt-3 space-y-2 text-sm text-black/75">
        <li className="flex gap-2"><Truck className="mt-0.5 h-4 w-4 shrink-0 text-magenta" aria-hidden />{c.entrega.texto}. Sem custo de frete.</li>
        <li className="flex gap-2"><Calendar className="mt-0.5 h-4 w-4 shrink-0 text-magenta" aria-hidden /><span>{data ? <>Previsão de entrega: <b>{data}</b>. </> : null}{c.prazo.texto}</span></li>
      </ul>
      {c.validade_ate && <p className="mt-3 text-xs text-black/55">Este link vale até {dataHora(c.validade_ate)}.</p>}
    </section>
  )
}
