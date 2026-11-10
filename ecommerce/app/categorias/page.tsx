import type { Metadata } from 'next'
import { redirect } from 'next/navigation'
import { BarraLateral } from '@/components/BarraLateral'
import { FiltrosChips } from '@/components/Filtros'
import { ListaModelos } from '@/components/ListaModelos'
import { lerFiltros, lerOrdem, type ParamsUrl } from '@/lib/filtros'
import { arvore, facetas, facetasHome, modelosFiltrados } from '@/lib/vitrine'

export const revalidate = 900
export const metadata: Metadata = { title: 'Todos os produtos', description: 'Todos os produtos da Sua Gráfica BH organizados por departamento, com foto, referência e preço a partir de.', alternates: { canonical: '/categorias' } }

export default async function Produtos({ searchParams }: { searchParams: Promise<ParamsUrl> }) {
  const sp = await searchParams
  if (typeof sp.q === 'string' && sp.q.trim()) redirect(`/busca?q=${encodeURIComponent(sp.q.trim().toLowerCase())}`)
  const vertical = typeof sp.vertical === 'string' ? sp.vertical : undefined
  const filtros = lerFiltros(sp)
  const ordem = lerOrdem(sp)
  const verticais = await arvore()
  const v = verticais.find((x) => x.id === vertical)
  const slugs = v ? v.categorias.map((c) => c.slug) : null
  const [r, f] = await Promise.all([modelosFiltrados(slugs, { filtros, ordem, limite: 2000 }), slugs === null && Object.keys(filtros).length === 0 ? facetasHome() : facetas(slugs, null, filtros)])
  const base = v ? `/categorias?vertical=${v.id}` : '/categorias'
  return (
    <div className="mx-auto max-w-7xl px-4 py-6 lg:flex lg:gap-6">
      <BarraLateral verticais={verticais} facetas={f.facetas} filtros={filtros} base={base} ordem={ordem} />
      <section className="min-w-0 flex-1">
        <h1 className="text-3xl font-black">{v ? v.nome : 'Todos os produtos'}</h1>
        <p className="mt-1 text-sm text-black/60">{v?.descricao ?? 'Escolha um departamento na lateral ou use os filtros.'} {r.total.toLocaleString('pt-BR')} opções com preço fechado.</p>
        {v && (
          <ul className="mt-4 flex flex-wrap gap-2">
            {v.categorias.map((c) => <li key={c.slug}><a href={`/categoria/${c.slug}`} className="inline-flex min-h-9 items-center rounded-full border border-black/15 bg-white px-3 text-xs font-semibold hover:border-magenta hover:text-magenta">{c.nome} ({c.modelos})</a></li>)}
          </ul>
        )}
        <div className="mt-4"><FiltrosChips base={base} facetas={f.facetas} filtros={filtros} ordem={ordem} /></div>
        <ListaModelos modelos={r.modelos} />
      </section>
    </div>
  )
}
