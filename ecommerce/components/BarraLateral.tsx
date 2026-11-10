import { MenuDepartamentos } from './MenuDepartamentos'
import type { Vertical } from '@/lib/vitrine'

/** Coluna fixa da esquerda (computador): lista de departamentos que acompanha a rolagem e tem rolagem própria. No celular o menu fica na gaveta "Departamentos" do cabeçalho. */
export function BarraLateral({ verticais, atual, subAtual }: { verticais: Vertical[]; atual?: string; subAtual?: string }) {
  return (
    <aside className="hidden w-60 shrink-0 lg:block" aria-label="Departamentos">
      <div className="sticky top-[6.25rem] h-[calc(100dvh-7rem)] overflow-y-auto overscroll-contain rounded-xl2 bg-white p-2 shadow-sm">
        <p className="px-3 pb-1 pt-1 text-[11px] font-black uppercase tracking-wide text-black/50">Departamentos</p>
        <MenuDepartamentos verticais={verticais} atual={atual} subAtual={subAtual} />
      </div>
    </aside>
  )
}
