import Link from 'next/link'
import { ChevronDown } from 'lucide-react'
import type { Vertical } from '@/lib/vitrine'

/** Menu lateral por vertical > categoria > subcategoria (abre com <details>, sem JavaScript). No celular vira uma barra que expande. */
export function ListaMenu({ verticais, atual, subAtual }: { verticais: Vertical[]; atual?: string; subAtual?: string }) {
  return (
    <ul className="space-y-1">
      {verticais.map((v) => {
        const aberto = v.categorias.some((c) => c.slug === atual)
        return (
          <li key={v.id}>
            <details open={aberto} className="group rounded-lg">
              <summary className="flex min-h-11 cursor-pointer list-none items-center justify-between rounded-lg px-3 text-sm font-bold hover:bg-papel [&::-webkit-details-marker]:hidden">
                <span>{v.nome}</span><ChevronDown className="h-4 w-4 shrink-0 transition group-open:rotate-180" aria-hidden />
              </summary>
              <ul className="mb-2 ml-3 border-l border-black/10 pl-2">
                <li><Link href={`/categorias?vertical=${v.id}`} className="flex min-h-9 items-center px-2 text-xs font-semibold text-magenta hover:underline">Ver tudo em {v.nome}</Link></li>
                {v.categorias.map((c) => (
                  <li key={c.slug}>
                    <Link href={`/categoria/${c.slug}`} className={`flex min-h-10 items-center justify-between rounded-md px-2 text-sm hover:text-magenta ${c.slug === atual && !subAtual ? 'font-bold text-magenta' : 'text-black/75'}`}>{c.nome}<span className="text-xs text-black/40">{c.modelos}</span></Link>
                    {c.slug === atual && c.subcategorias.length > 0 && (
                      <ul className="mb-1 ml-3 border-l border-black/10 pl-2">
                        {c.subcategorias.map((s) => (
                          <li key={s.slug}><Link href={`/categoria/${c.slug}?sub=${s.slug}`} rel="nofollow" className={`flex min-h-9 items-center justify-between rounded-md px-2 text-xs hover:text-magenta ${s.slug === subAtual ? 'font-bold text-magenta' : 'text-black/65'}`}>{s.nome}<span className="text-black/40">{s.modelos}</span></Link></li>
                        ))}
                      </ul>
                    )}
                  </li>
                ))}
              </ul>
            </details>
          </li>
        )
      })}
    </ul>
  )
}

export function MenuLateral({ verticais, atual, subAtual }: { verticais: Vertical[]; atual?: string; subAtual?: string }) {
  const lista = <ListaMenu verticais={verticais} atual={atual} subAtual={subAtual} />
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
