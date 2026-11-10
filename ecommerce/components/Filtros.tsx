import Link from 'next/link'
import { ChevronDown } from 'lucide-react'
import { FACETAS, hrefFiltros } from '@/lib/filtros'
import type { Facetas, Filtros } from '@/lib/vitrine'

/** Barra de filtros facetados com contadores e chips dos filtros ativos. Links simples (sem JavaScript); no celular vira gaveta. */
type PropsF = { base: string; facetas: Facetas; filtros: Filtros; q?: string; ordem: string }

export function PainelFiltros({ base, facetas, filtros, q, ordem }: PropsF) {
  return (
    <div className="space-y-1">
      {FACETAS.map((f) => {
        const itens = facetas[f.id] ?? []
        if (!itens.length && !(filtros[f.id] ?? []).length) return null
        const aberto = (filtros[f.id] ?? []).length > 0
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
}
