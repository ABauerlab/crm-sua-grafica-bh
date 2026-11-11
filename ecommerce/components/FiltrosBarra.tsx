'use client'
import { useEffect, useRef, useState } from 'react'
import Link from 'next/link'
import { useRouter } from 'next/navigation'
import { ChevronDown, SlidersHorizontal, X } from 'lucide-react'
import { PainelFiltros } from './Filtros'
import { FACETAS, ORDENS, hrefFiltros } from '@/lib/filtros'
import type { Facetas, Filtros } from '@/lib/vitrine'

/** Barra de filtros logo acima da lista: um botão por filtro (computador) ou "Filtros" em gaveta (celular), ordenação e filtros ativos com remoção rápida. */
export function FiltrosBarra({ base, facetas, filtros, q, ordem, total }: { base: string; facetas: Facetas; filtros: Filtros; q?: string; ordem: string; total?: number }) {
  const router = useRouter()
  const [aberto, setAberto] = useState<string | null>(null)
  const raiz = useRef<HTMLDivElement>(null)
  const gaveta = useRef<HTMLDialogElement>(null)
  useEffect(() => {
    const fora = (e: MouseEvent) => { if (raiz.current && !raiz.current.contains(e.target as Node)) setAberto(null) }
    const esc = (e: KeyboardEvent) => { if (e.key === 'Escape') setAberto(null) }
    document.addEventListener('mousedown', fora); document.addEventListener('keydown', esc)
    return () => { document.removeEventListener('mousedown', fora); document.removeEventListener('keydown', esc) }
  }, [])
  const ativos = FACETAS.flatMap((f) => (filtros[f.id] ?? []).map((v) => ({ faceta: f.id, valor: v, rotulo: facetas[f.id]?.find((i) => i.valor === v)?.rotulo ?? v })))
  const grupos = FACETAS.filter((f) => (facetas[f.id]?.length ?? 0) > 0 || (filtros[f.id]?.length ?? 0) > 0)

  return (
    <div ref={raiz} className="sticky top-0 z-30 -mx-4 mt-3 border-b border-black/5 bg-papel/95 px-4 py-2 backdrop-blur md:top-[6.25rem]">
      <div className="flex flex-wrap items-center gap-2">
        <button type="button" onClick={() => gaveta.current?.showModal()} className="flex min-h-9 items-center gap-2 rounded-lg bg-tinta px-3 text-[13px] font-bold text-white md:hidden">
          <SlidersHorizontal className="h-4 w-4" aria-hidden />Filtros{ativos.length ? ` (${ativos.length})` : ''}
        </button>
        <div className="hidden flex-wrap items-center gap-1.5 md:flex">
          {grupos.map((f) => {
            const n = filtros[f.id]?.length ?? 0
            const abre = aberto === f.id
            return (
              <div key={f.id} className="relative">
                <button type="button" onClick={() => setAberto(abre ? null : f.id)} aria-expanded={abre} aria-haspopup="true"
                  className={`flex min-h-9 items-center gap-1 rounded-lg border px-2.5 text-[13px] font-semibold ${n ? 'border-magenta bg-magenta/5 text-magenta' : 'border-black/15 bg-white hover:border-black/40'}`}>
                  {f.titulo.split(' / ')[0]}{n ? ` (${n})` : ''}<ChevronDown className={`h-3.5 w-3.5 transition ${abre ? 'rotate-180' : ''}`} aria-hidden />
                </button>
                {abre && (
                  <ul className="absolute left-0 top-full z-40 mt-1 max-h-80 w-72 overflow-y-auto rounded-lg bg-white p-1 shadow-xl ring-1 ring-black/10">
                    {(facetas[f.id] ?? []).map((i) => {
                      const marcado = (filtros[f.id] ?? []).includes(i.valor)
                      return (
                        <li key={i.valor}><Link href={hrefFiltros(base, filtros, { q, ordem }, { faceta: f.id, valor: i.valor })} rel="nofollow" onClick={() => setAberto(null)}
                          className={`flex min-h-10 items-center justify-between gap-2 rounded-md px-2 text-sm hover:bg-papel ${marcado ? 'font-bold text-magenta' : ''}`}>
                          <span className="flex items-center gap-2"><span className={`h-4 w-4 shrink-0 rounded border ${marcado ? 'border-magenta bg-magenta' : 'border-black/30'}`} aria-hidden />{i.rotulo}</span><span className="text-xs text-black/45">({i.n})</span></Link></li>
                      )
                    })}
                  </ul>
                )}
              </div>
            )
          })}
        </div>
        <span className="ml-auto text-xs text-black/55">{total != null ? `${total.toLocaleString('pt-BR')} ${total === 1 ? 'produto' : 'produtos'}` : ''}</span>
        <label className="flex items-center gap-1.5 text-xs text-black/60">Ordenar
          <select value={ordem} onChange={(e) => router.push(hrefFiltros(base, filtros, { q, ordem: e.target.value }))} className="h-9 rounded-lg border border-black/15 bg-white px-2 text-[13px] text-tinta">
            {ORDENS.map(([o, nome]) => <option key={o} value={o}>{nome}</option>)}
          </select>
        </label>
      </div>
      {ativos.length > 0 && (
        <div className="mt-2 flex flex-wrap items-center gap-1.5" aria-label="Filtros ativos">
          {ativos.map((a) => (
            <Link key={a.faceta + a.valor} href={hrefFiltros(base, filtros, { q, ordem }, { faceta: a.faceta, valor: a.valor })} rel="nofollow"
              className="inline-flex min-h-8 items-center gap-1 rounded-full bg-tinta px-2.5 text-xs font-semibold text-white hover:bg-magenta">{a.rotulo}<X className="h-3 w-3" aria-label="Remover filtro" /></Link>
          ))}
          {ativos.length > 0 && <Link href={hrefFiltros(base, filtros, { q, ordem }, { limpar: true })} rel="nofollow" className="text-xs font-semibold text-magenta underline">Limpar tudo</Link>}
        </div>
      )}
      <dialog ref={gaveta} onClick={(e) => { if (e.target === gaveta.current) gaveta.current?.close() }} aria-label="Filtros"
        className="m-0 mt-auto max-h-[85dvh] w-full max-w-none rounded-t-2xl bg-white p-0 text-tinta backdrop:bg-black/50 md:hidden">
        <div className="flex items-center justify-between border-b border-black/10 px-4 py-3"><b>Filtros</b>
          <button type="button" onClick={() => gaveta.current?.close()} aria-label="Fechar filtros" className="flex h-11 w-11 items-center justify-center rounded-lg hover:bg-papel"><X className="h-5 w-5" aria-hidden /></button></div>
        <div className="max-h-[70dvh] overflow-y-auto px-4 pb-4" onClick={(e) => { if ((e.target as HTMLElement).closest('a')) gaveta.current?.close() }}>
          <PainelFiltros base={base} facetas={facetas} filtros={filtros} q={q} ordem={ordem} />
        </div>
      </dialog>
    </div>
  )
}
