import Link from 'next/link'
import { ChevronDown } from 'lucide-react'
import { agrupar } from '@/lib/departamentos'
import type { CategoriaResumo } from '@/lib/vitrine'

/** Menu lateral por departamento (abre com <details>, sem JavaScript). No celular vira uma barra "Categorias" que expande. */
export function MenuLateral({ cats, atual }: { cats: CategoriaResumo[]; atual?: string }) {
  const deptos = agrupar(cats)
  const lista = (
    <ul className="space-y-1">
      {deptos.map((d) => {
        const aberto = d.categorias.some((c) => c.slug === atual)
        return (
          <li key={d.id}>
            <details open={aberto} className="group rounded-lg">
              <summary className="flex min-h-11 cursor-pointer list-none items-center justify-between rounded-lg px-3 text-sm font-bold hover:bg-papel [&::-webkit-details-marker]:hidden">
                {d.nome}<ChevronDown className="h-4 w-4 transition group-open:rotate-180" aria-hidden />
              </summary>
              <ul className="mb-2 ml-3 border-l border-black/10 pl-2">
                {d.categorias.map((c) => (
                  <li key={c.slug}>
                    <Link href={`/categoria/${c.slug}`} className={`flex min-h-10 items-center rounded-md px-2 text-sm hover:text-magenta ${c.slug === atual ? 'font-bold text-magenta' : 'text-black/75'}`}>{c.nome}</Link>
                  </li>
                ))}
              </ul>
            </details>
          </li>
        )
      })}
    </ul>
  )
  return (
    <>
      <aside className="hidden w-64 shrink-0 lg:block" aria-label="Departamentos">
        <div className="sticky top-36 max-h-[calc(100vh-10rem)] overflow-y-auto rounded-xl2 bg-white p-2 shadow-sm">{lista}</div>
      </aside>
      <details className="mb-4 rounded-xl2 bg-white shadow-sm lg:hidden">
        <summary className="flex min-h-12 cursor-pointer list-none items-center justify-between px-4 text-sm font-black [&::-webkit-details-marker]:hidden">Departamentos e categorias<ChevronDown className="h-4 w-4" aria-hidden /></summary>
        <div className="max-h-[60vh] overflow-y-auto p-2">{lista}</div>
      </details>
    </>
  )
}
