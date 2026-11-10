import { ChevronDown, SlidersHorizontal } from 'lucide-react'
import { PainelFiltros } from './Filtros'
import { MenuDepartamentos } from './MenuDepartamentos'
import type { Facetas, Filtros, Vertical } from '@/lib/vitrine'

/** Coluna da esquerda: departamentos (vertical > categoria > subcategoria) e filtros. No celular vira duas gavetas. Usada na home, em /categorias e nas categorias. */
export function BarraLateral({ verticais, facetas, filtros, base, q, ordem, atual, subAtual }: { verticais: Vertical[]; facetas: Facetas; filtros: Filtros; base: string; q?: string; ordem: string; atual?: string; subAtual?: string }) {
  const nAtivos = Object.values(filtros).reduce((n, v) => n + (v?.length ?? 0), 0)
  const menu = <MenuDepartamentos verticais={verticais} atual={atual} subAtual={subAtual} />
  const filtrosUi = <PainelFiltros base={base} facetas={facetas} filtros={filtros} q={q} ordem={ordem} />
  return (
    <>
      <aside className="hidden w-64 shrink-0 space-y-4 lg:block" aria-label="Departamentos e filtros">
        <div className="sticky top-36 max-h-[calc(100vh-10rem)] space-y-4 overflow-y-auto pr-1">
          <div className="rounded-xl2 bg-white p-2 shadow-sm"><p className="px-3 pb-1 pt-2 text-xs font-black uppercase tracking-wide text-black/50">Departamentos</p>{menu}</div>
          <div className="rounded-xl2 bg-white p-3 shadow-sm"><p className="mb-1 text-xs font-black uppercase tracking-wide text-black/50">Filtrar</p>{filtrosUi}</div>
        </div>
      </aside>
      <div className="mb-4 space-y-2 lg:hidden">
        <details className="rounded-xl2 bg-white shadow-sm">
          <summary className="flex min-h-12 cursor-pointer list-none items-center justify-between px-4 text-sm font-black [&::-webkit-details-marker]:hidden">Departamentos e categorias<ChevronDown className="h-4 w-4" aria-hidden /></summary>
          <div className="max-h-[60vh] overflow-y-auto p-2">{menu}</div>
        </details>
        <details className="rounded-xl2 bg-white shadow-sm">
          <summary className="flex min-h-12 cursor-pointer list-none items-center gap-2 px-4 text-sm font-black [&::-webkit-details-marker]:hidden"><SlidersHorizontal className="h-4 w-4" aria-hidden />Filtros{nAtivos > 0 ? ` (${nAtivos})` : ''}</summary>
          <div className="max-h-[60vh] overflow-y-auto px-4 pb-3">{filtrosUi}</div>
        </details>
      </div>
    </>
  )
}
