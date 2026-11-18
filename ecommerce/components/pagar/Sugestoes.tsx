'use client'
import { Plus } from 'lucide-react'
import { brl } from '@/lib/site'
import { fotoUrl } from '@/lib/vitrine'
import type { Sugestao } from '@/lib/pagar'

/** Cross-sell: combina o que o cliente já leva, a conversa e o histórico. O preço é sempre recalculado no servidor. */
export function Sugestoes({ itens, ocupado, onAdicionar }: { itens: Sugestao[]; ocupado: boolean; onAdicionar: (ref: string) => void }) {
  if (!itens.length) return null
  return (
    <section aria-labelledby="sug-t" className="rounded-xl2 bg-white p-5 shadow-sm">
      <h2 id="sug-t" className="text-lg font-black">Aproveite e leve junto</h2>
      <p className="mb-3 text-sm text-black/65">Sugestões que combinam com o seu pedido, na mesma entrega e sem frete.</p>
      <div className="-mx-5 flex snap-x snap-mandatory gap-3 overflow-x-auto px-5 pb-2 md:mx-0 md:grid md:grid-cols-3 md:overflow-visible md:px-0">
        {itens.map((s) => {
          const f = fotoUrl(s.foto)
          return (
            <article key={s.ref} className="flex w-[78%] shrink-0 snap-start flex-col rounded-xl border border-black/10 p-3 sm:w-[46%] md:w-auto">
              <span className="mb-2 w-fit rounded-full bg-ciano/15 px-2 py-0.5 text-[11px] font-bold text-[#00708f]">{s.selo}</span>
              {f
                // eslint-disable-next-line @next/next/no-img-element
                ? <img src={f} alt="" loading="lazy" className="mb-2 aspect-[4/3] w-full rounded-lg bg-papel object-cover" />
                : <div className="mb-2 aspect-[4/3] w-full rounded-lg bg-papel" />}
              <h3 className="line-clamp-2 text-sm font-bold leading-snug">{s.titulo}</h3>
              <p className="mt-0.5 line-clamp-3 text-xs text-black/60">{s.motivo}</p>
              <p className="mt-2 text-sm">{s.quantidade ?? 1} un. por <b>{brl(s.preco)}</b></p>
              <p className="text-xs text-black/55">ou 2x de {brl(s.parcela_2x)} sem juros</p>
              <button type="button" disabled={ocupado} onClick={() => onAdicionar(s.ref)} className="mt-3 inline-flex h-11 items-center justify-center gap-1 rounded-lg bg-tinta px-3 text-sm font-bold text-white hover:bg-magenta disabled:opacity-60">
                <Plus className="h-4 w-4" aria-hidden />Adicionar ao pedido
              </button>
            </article>
          )
        })}
      </div>
    </section>
  )
}
