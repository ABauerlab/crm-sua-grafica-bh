'use client'
import { useEffect, useRef } from 'react'
import { Check, ChevronLeft, ChevronRight } from 'lucide-react'
import { brl } from '@/lib/site'
import type { Quantidade } from '@/lib/pagar'

/** Carrossel de tiragens: TODAS as opções ficam sempre na fila (nada some ao escolher), em linha única com rolagem lateral e encaixe.
 *  A troca atualiza o pedido na hora; o preço vem sempre do servidor. */
function Fila({ it, ocupado, onTrocar }: { it: Quantidade; ocupado: boolean; onTrocar: (item: string, ref: string) => void }) {
  const trilho = useRef<HTMLDivElement>(null)
  const atual = it.opcoes.find((o) => o.atual)
  const refAtual = atual?.ref

  // centraliza a opção escolhida ao abrir e quando ela muda
  useEffect(() => {
    const el = trilho.current?.querySelector<HTMLElement>('[aria-checked="true"]')
    el?.scrollIntoView({ inline: 'center', block: 'nearest', behavior: 'smooth' })
  }, [refAtual])

  const rolar = (d: 1 | -1) => trilho.current?.scrollBy({ left: d * Math.max(trilho.current.clientWidth * 0.8, 160), behavior: 'smooth' })

  return (
    <div>
      <div className="mb-2 flex items-end justify-between gap-2">
        <p className="min-w-0 break-words text-sm font-bold leading-snug">{it.descricao.replace(/\s·\s[\d.]+\sun\./, '')}</p>
        <div className="hidden shrink-0 gap-1 sm:flex">
          <button type="button" onClick={() => rolar(-1)} aria-label="Ver opções anteriores" className="flex h-9 w-9 items-center justify-center rounded-full border border-black/15 hover:border-magenta"><ChevronLeft className="h-4 w-4" aria-hidden /></button>
          <button type="button" onClick={() => rolar(1)} aria-label="Ver mais opções" className="flex h-9 w-9 items-center justify-center rounded-full border border-black/15 hover:border-magenta"><ChevronRight className="h-4 w-4" aria-hidden /></button>
        </div>
      </div>
      <div ref={trilho} role="radiogroup" aria-label="Quantidade" tabIndex={0}
        className="-mx-5 flex snap-x snap-mandatory gap-2.5 overflow-x-auto scroll-px-5 px-5 pb-2 pt-1 [scrollbar-width:thin]">
        {it.opcoes.map((o) => {
          const diff = atual ? o.preco - atual.preco : 0
          const economia = atual && o.quantidade > atual.quantidade && o.unitario < atual.unitario ? Math.round((1 - o.unitario / atual.unitario) * 100) : 0
          return (
            <button key={o.ref} type="button" role="radio" aria-checked={o.atual} disabled={ocupado} onClick={() => !o.atual && onTrocar(it.item_id, o.ref)}
              className={`relative flex min-h-[8.5rem] w-[8.25rem] shrink-0 snap-center flex-col items-start rounded-xl border-2 p-3 text-left transition-colors disabled:opacity-60 sm:w-40 ${o.atual ? 'border-magenta bg-magenta/5' : 'border-black/10 hover:border-magenta/50'}`}>
              {o.atual && <Check className="absolute right-2 top-2 h-4 w-4 text-magenta" aria-hidden />}
              <span className="text-lg font-black leading-none">{o.quantidade.toLocaleString('pt-BR')} un.</span>
              <span className="mt-1 text-sm font-semibold">{brl(o.preco)}</span>
              <span className="text-xs text-black/55">{brl(o.unitario)} cada</span>
              <span className="mt-auto flex w-full flex-col gap-1 pt-1.5">
                {economia > 0 && <span className="w-fit rounded-full bg-amarelo px-2 py-0.5 text-[10px] font-black leading-tight text-tinta">{economia}% mais barato por un.</span>}
                {!o.atual && <span className={`text-xs font-bold ${diff < 0 ? 'text-black/60' : 'text-magenta'}`}>{diff >= 0 ? '+' : '-'} {brl(Math.abs(diff))}</span>}
                {o.atual && <span className="text-xs font-bold text-magenta">No seu pedido</span>}
              </span>
            </button>
          )
        })}
      </div>
    </div>
  )
}

export function Quantidades({ itens, ocupado, onTrocar }: { itens: Quantidade[]; ocupado: boolean; onTrocar: (item: string, ref: string) => void }) {
  if (!itens.length) return null
  return (
    <section aria-labelledby="qtd-t" className="overflow-hidden rounded-xl2 bg-white p-5 shadow-sm">
      <h2 id="qtd-t" className="text-lg font-black">Leve mais e pague menos por unidade</h2>
      <p className="mb-3 text-sm text-black/65">Deslize para ver todas as quantidades. O seu pedido se atualiza na hora.</p>
      <div className="space-y-5">
        {itens.map((it) => <Fila key={it.item_id} it={it} ocupado={ocupado} onTrocar={onTrocar} />)}
      </div>
    </section>
  )
}
