import type { Metadata } from 'next'
import { redirect } from 'next/navigation'
import { BarraLateral } from '@/components/BarraLateral'
import { FiltrosBarra } from '@/components/FiltrosBarra'
import { ListaModelos } from '@/components/ListaModelos'
import { lerFiltros, lerOrdem, type ParamsUrl } from '@/lib/filtros'
import { arvore, facetas, facetasHome, modelosFiltrados } from '@/lib/vitrine'

export const revalidate = 900
export const metadata: Metadata = { title: 'Todos os produtos', description: 'Todos os produtos da Sua Gráfica BH organizados por departamento, com foto, referência e preço a partir de.', alternates: { canonical: '/categorias' } }

const CATEGORIAS_PRINCIPAIS = [
  { slug: 'cartoes-de-visita', nome: 'Cartões de Visita' },
  { slug: 'panfletos-flyers-e-folhetos', nome: 'Panfletos' },
  { slug: 'banners-faixas-lonas-e-tecidos', nome: 'Banners' },
  { slug: 'adesivos', nome: 'Adesivos' },
  { slug: 'pastas', nome: 'Pastas' },
]

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
    <div className="mx-auto max-w-[1440px] px-4 py-6 lg:flex lg:gap-5">
      <BarraLateral verticais={verticais} />
      <section className="min-w-0 flex-1">
        <h1 className="text-2xl font-black md:text-3xl">{v ? v.nome : 'Todos os produtos'}</h1>
        <p className="mt-1 text-sm text-black/60">{v?.descricao ?? 'Escolha um departamento na lateral ou use os filtros.'} {r.total.toLocaleString('pt-BR')} produtos com preço fechado.</p>
        {!v && <nav aria-label="Categorias principais" className="mt-4 flex flex-wrap gap-2">
          {CATEGORIAS_PRINCIPAIS.map((c) => <a key={c.slug} href={`/categoria/${c.slug}`} className="inline-flex min-h-10 items-center rounded-full border border-black/15 bg-white px-3.5 text-sm font-semibold hover:border-magenta hover:text-magenta">{c.nome}</a>)}
        </nav>}
        {v && (
          <ul className="mt-4 flex flex-wrap gap-2">
            {v.categorias.map((c) => <li key={c.slug}><a href={`/categoria/${c.slug}`} className="inline-flex min-h-9 items-center rounded-full border border-black/15 bg-white px-3 text-xs font-semibold hover:border-magenta hover:text-magenta">{c.nome} ({c.modelos})</a></li>)}
          </ul>
        )}
        <FiltrosBarra base={base} facetas={f.facetas} filtros={filtros} ordem={ordem} total={r.total} />
        <ListaModelos modelos={r.modelos} />
      </section>
    </div>
  )
}
