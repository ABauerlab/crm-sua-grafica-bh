import Link from 'next/link'
import { ChevronDown, SlidersHorizontal, X } from 'lucide-react'
import { FACETAS, ORDENS, hrefFiltros } from '@/lib/filtros'
import type { Facetas, Filtros } from '@/lib/vitrine'

/** Barra de filtros facetados com contadores e chips dos filtros ativos. Links simples (sem JavaScript); no celular vira gaveta. */
export function FiltrosLaterais({ base, facetas, filtros, q, ordem }: { base: string; facetas: Facetas; filtros: Filtros; q?: string; ordem: string }) {
  const ativos = FACETAS.flatMap((f) => (filtros[f.id] ?? []).map((v) => ({ faceta: f.id, valor: v, rotulo: facetas[f.id]?.find((i) => i.valor === v)?.rotulo ?? v })))
  const painel = (
    <div className="space-y-1">
      {FACETAS.map((f) => {
        const itens = facetas[f.id] ?? []
        if (!itens.length && !(filtros[f.id] ?? []).length) return null
        const aberto = f.id !== 'preco' && f.id !== 'formato' || (filtros[f.id] ?? []).length > 0
        return (
          <details key={f.id} open={aberto} className="group border-b border-black/5 pb-1">
            <summary className="flex min-h-11 cursor-pointer list-none items-center justify-between text-sm font-bold [&::-webkit-details-marker]:hidden">
              {f.titulo}<ChevronDown className="h-4 w-4 transition group-open:rotate-180" aria-hidden />
            </summary>
            <ul className="pb-2">
              {itens.map((i) => {
                const marcado = (filtros[f.id] ?? []).includes(i.valor)
                return (
                  <li key={i.valor}>
                    <Link href={hrefFiltros(base, filtros, { q, ordem }, { faceta: f.id, valor: i.valor })} rel="nofollow" aria-pressed={marcado}
                      className={`flex min-h-9 items-center justify-between gap-2 rounded-md px-2 text-sm hover:bg-papel ${marcado ? 'font-bold text-magenta' : 'text-black/75'}`}>
                      <span className="flex items-center gap-2"><span className={`h-4 w-4 shrink-0 rounded border ${marcado ? 'border-magenta bg-magenta' : 'border-black/30'}`} aria-hidden />{i.rotulo}</span>
                      <span className="text-xs text-black/45">({i.n})</span>
                    </Link>
                  </li>
                )
              })}
            </ul>
          </details>
        )
      })}
    </div>
  )
  return (
    <>
      <details className="mb-4 rounded-xl2 bg-white shadow-sm lg:hidden">
        <summary className="flex min-h-12 cursor-pointer list-none items-center gap-2 px-4 text-sm font-black [&::-webkit-details-marker]:hidden"><SlidersHorizontal className="h-4 w-4" aria-hidden />Filtros{ativos.length > 0 ? ` (${ativos.length})` : ''}</summary>
        <div className="max-h-[60vh] overflow-y-auto px-4 pb-3">{painel}</div>
      </details>
      <aside className="hidden w-60 shrink-0 lg:block" aria-label="Filtros">
        <div className="sticky top-36 max-h-[calc(100vh-10rem)] overflow-y-auto rounded-xl2 bg-white p-3 shadow-sm"><p className="mb-1 text-xs font-black uppercase tracking-wide text-black/50">Filtrar</p>{painel}</div>
      </aside>
    </>
  )
}

export function FiltrosChips({ base, facetas, filtros, q, ordem }: { base: string; facetas: Facetas; filtros: Filtros; q?: string; ordem: string }) {
  const ativos = FACETAS.flatMap((f) => (filtros[f.id] ?? []).map((v) => ({ faceta: f.id, valor: v, rotulo: facetas[f.id]?.find((i) => i.valor === v)?.rotulo ?? v })))
  return (
    <div className="mb-3 flex flex-wrap items-center gap-2" aria-label="Filtros ativos">
        {ativos.map((a) => (
          <Link key={a.faceta + a.valor} href={hrefFiltros(base, filtros, { q, ordem }, { faceta: a.faceta, valor: a.valor })} rel="nofollow"
            className="inline-flex min-h-9 items-center gap-1 rounded-full bg-tinta px-3 text-xs font-semibold text-white hover:bg-magenta">{a.rotulo}<X className="h-3 w-3" aria-label="Remover filtro" /></Link>
        ))}
        {ativos.length > 0 && <Link href={hrefFiltros(base, filtros, { q, ordem }, { limpar: true })} rel="nofollow" className="text-xs font-semibold text-magenta underline">Limpar tudo</Link>}
        <span className="ml-auto flex items-center gap-1 text-xs text-black/60">Ordenar:
          {ORDENS.map(([o, nome]) => <Link key={o} href={hrefFiltros(base, filtros, { q, ordem: o })} rel="nofollow" className={`rounded-full px-2 py-1 ${o === ordem ? 'bg-papel font-bold text-tinta' : 'hover:text-magenta'}`}>{nome}</Link>)}
        </span>
      </div>
  )
}
