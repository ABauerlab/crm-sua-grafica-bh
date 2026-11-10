import type { Metadata } from 'next'
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { ChevronRight } from 'lucide-react'
import { CobrimosBanner } from '@/components/CobrimosBanner'
import { FiltrosChips, FiltrosLaterais } from '@/components/Filtros'
import { ModeloCard } from '@/components/ModeloCard'
import { Paginacao } from '@/components/Paginacao'
import { lerFiltros, lerOrdem, type ParamsUrl } from '@/lib/filtros'
import { arvore, facetas, modelosFiltrados } from '@/lib/vitrine'

export const revalidate = 900

async function achar(slug: string) {
  const verticais = await arvore()
  for (const v of verticais) { const c = v.categorias.find((x) => x.slug === slug); if (c) return { v, c } }
  return null
}

export async function generateMetadata({ params }: { params: Promise<{ slug: string }> }): Promise<Metadata> {
  const { slug } = await params
  const a = await achar(slug)
  if (!a) return { title: 'Categoria não encontrada' }
  const { c } = a
  return { title: `${c.nome} personalizados`, description: `${c.nome} personalizados em Belo Horizonte: ${c.modelos} modelos a partir de R$ ${c.a_partir_de.toFixed(2).replace('.', ',')}. Pix ou 2x sem juros, retirada grátis na Praça Sete e envio para todo o Brasil.`, alternates: { canonical: `/categoria/${slug}` } }
}

export default async function PaginaCategoria({ params, searchParams }: { params: Promise<{ slug: string }>; searchParams: Promise<ParamsUrl> }) {
  const { slug } = await params
  const sp = await searchParams
  const a = await achar(slug)
  if (!a) notFound()
  const { v, c } = a
  const q = typeof sp.q === 'string' ? sp.q.trim().slice(0, 80) : ''
  const filtros = lerFiltros(sp)
  const ordem = lerOrdem(sp)
  const pg = Math.max(1, Number(sp.pagina) || 1)
  const [r, f] = await Promise.all([
    modelosFiltrados([slug], { termo: q || null, filtros, ordem, limite: 24, pagina: pg }),
    facetas([slug], q || null, filtros),
  ])
  const base = `/categoria/${slug}`
  const subAtiva = c.subcategorias.find((s) => s.slug === filtros.sub?.[0])
  const params2: Record<string, string | undefined> = { q: q || undefined, ordem: ordem !== 'relevancia' ? ordem : undefined }
  for (const [k, val] of Object.entries(filtros)) if (val?.length) params2[k] = val.join(',')
  return (
    <div className="mx-auto max-w-7xl px-4 py-6 lg:flex lg:gap-6">
      <FiltrosLaterais base={base} facetas={f.facetas} filtros={filtros} q={q || undefined} ordem={ordem} />
      <div className="min-w-0 flex-1">
        <nav aria-label="Caminho" className="mb-4 flex flex-wrap items-center gap-1 text-xs text-black/55">
          <Link href="/" className="hover:text-magenta">Início</Link><ChevronRight className="h-3 w-3" aria-hidden />
          <Link href={`/categorias?vertical=${v.id}`} className="hover:text-magenta">{v.nome}</Link><ChevronRight className="h-3 w-3" aria-hidden />
          <span className="text-tinta">{c.nome}</span>
        </nav>
        <div className="flex flex-wrap items-end justify-between gap-4">
          <div>
            <h1 className="text-3xl font-black">{subAtiva ? `${c.nome}: ${subAtiva.nome}` : c.nome}</h1>
            <p className="mt-1 text-sm text-black/60">{r.total} {r.total === 1 ? 'modelo' : 'modelos'}{q ? ` para "${q}"` : ''}. Preço fechado, escolha a tiragem na página do produto.</p>
          </div>
          <form className="flex w-full gap-2 sm:w-auto" role="search">
            <input name="q" defaultValue={q} placeholder={`Buscar em ${c.nome}`} aria-label="Buscar nesta categoria" className="h-11 flex-1 rounded-lg border border-black/15 bg-white px-3 sm:w-64" />
            {Object.entries(params2).filter(([k, val]) => k !== 'q' && val).map(([k, val]) => <input key={k} type="hidden" name={k} value={val} />)}
            <button className="h-11 rounded-lg bg-tinta px-4 text-sm font-bold text-white">Buscar</button>
          </form>
        </div>
        <div className="mt-4"><FiltrosChips base={base} facetas={f.facetas} filtros={filtros} q={q || undefined} ordem={ordem} /></div>
        {r.total === 0
          ? <p className="mt-8 rounded-xl2 bg-white p-6 text-sm">Nenhum modelo com essa combinação. Remova algum filtro acima ou fale com a gente: fazemos sob medida.</p>
          : <div className="mt-6 grid grid-cols-2 gap-3 sm:grid-cols-3 xl:grid-cols-4">{r.modelos.map((m) => <ModeloCard key={m.produto_slug} m={m} />)}</div>}
        <Paginacao base={base} pagina={pg} total={r.total} porPagina={24} params={params2} />
        <div className="mt-8"><CobrimosBanner /></div>
      </div>
    </div>
  )
}
