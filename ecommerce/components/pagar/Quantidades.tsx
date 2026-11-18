'use client'
import { Check } from 'lucide-react'
import { brl } from '@/lib/site'
import type { Quantidade } from '@/lib/pagar'

/** Upsell de quantidade: quanto maior a tiragem, menor o valor por unidade. A troca atualiza o pedido na hora (preço sempre do servidor). */
export function Quantidades({ itens, ocupado, onTrocar }: { itens: Quantidade[]; ocupado: boolean; onTrocar: (item: string, ref: string) => void }) {
  if (!itens.length) return null
  return (
    <section aria-labelledby="qtd-t" className="rounded-xl2 bg-white p-5 shadow-sm">
      <h2 id="qtd-t" className="text-lg font-black">Leve mais e pague menos por unidade</h2>
      <p className="mb-3 text-sm text-black/65">Mudou de ideia sobre a quantidade? Escolha abaixo e o seu pedido se atualiza na hora.</p>
      <div className="space-y-4">
        {itens.map((it) => {
          const atual = it.opcoes.find((o) => o.atual)
          return (
            <div key={it.item_id}>
              <p className="mb-2 line-clamp-2 text-sm font-bold">{it.descricao.replace(/\s·\s[\d.]+\sun\./, '')}</p>
              <div role="radiogroup" aria-label="Quantidade" className="grid grid-cols-2 gap-2 sm:grid-cols-3 lg:grid-cols-4">
                {it.opcoes.map((o) => {
                  const diff = atual ? o.preco - atual.preco : 0
                  const economia = atual && o.quantidade > atual.quantidade && o.unitario < atual.unitario ? Math.round((1 - o.unitario / atual.unitario) * 100) : 0
                  return (
                    <button key={o.ref} type="button" role="radio" aria-checked={o.atual} disabled={ocupado} onClick={() => !o.atual && onTrocar(it.item_id, o.ref)}
                      className={`relative flex min-h-[5.5rem] flex-col items-start rounded-xl border-2 p-3 text-left transition-colors disabled:opacity-60 ${o.atual ? 'border-magenta bg-magenta/5' : 'border-black/10 hover:border-magenta/50'}`}>
                      {o.atual && <Check className="absolute right-2 top-2 h-4 w-4 text-magenta" aria-hidden />}
                      <span className="text-lg font-black leading-none">{o.quantidade.toLocaleString('pt-BR')} un.</span>
                      <span className="mt-1 text-sm font-semibold">{brl(o.preco)}</span>
                      <span className="text-xs text-black/55">{brl(o.unitario)} cada</span>
                      {!o.atual && <span className={`mt-auto pt-1 text-xs font-bold ${diff < 0 ? 'text-black/60' : 'text-magenta'}`}>{diff >= 0 ? '+' : '-'} {brl(Math.abs(diff))}</span>}
                      {economia > 0 && <span className="absolute -top-2 left-2 rounded-full bg-amarelo px-2 py-0.5 text-[10px] font-black text-tinta">{economia}% mais barato por un.</span>}
                    </button>
                  )
                })}
              </div>
            </div>
          )
        })}
      </div>
    </section>
  )
}
