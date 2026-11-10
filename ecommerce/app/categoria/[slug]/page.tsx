import type { Metadata } from 'next'
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { ChevronRight } from 'lucide-react'
import { CobrimosBanner } from '@/components/CobrimosBanner'
import { MenuLateral } from '@/components/MenuLateral'
import { ModeloCard } from '@/components/ModeloCard'
import { Paginacao } from '@/components/Paginacao'
import { categorias, modelos } from '@/lib/vitrine'

export const revalidate = 900

async function categoria(slug: string) {
  return (await categorias()).find((c) => c.slug === slug) ?? null
}

export async function generateMetadata({ params }: { params: Promise<{ slug: string }> }): Promise<Metadata> {
  const { slug } = await params
  const c = await categoria(slug)
  if (!c) return { title: 'Categoria não encontrada' }
  return { title: `${c.nome} personalizados`, description: `${c.nome} personalizados em Belo Horizonte: ${c.produtos} modelos a partir de R$ ${c.a_partir_de.toFixed(2).replace('.', ',')}. Pix ou 2x sem juros, retirada grátis na Praça Sete e envio para todo o Brasil.`, alternates: { canonical: `/categoria/${slug}` } }
}

export default async function PaginaCategoria({ params, searchParams }: { params: Promise<{ slug: string }>; searchParams: Promise<{ q?: string; pagina?: string }> }) {
  const { slug } = await params
  const { q, pagina } = await searchParams
  const todas = await categorias()
  const c = todas.find((x) => x.slug === slug) ?? null
  if (!c) notFound()
  const pg = Math.max(1, Number(pagina) || 1)
  const r = await modelos([slug], { termo: q?.trim() || null, limite: 24, pagina: pg })
  return (
    <div className="mx-auto max-w-7xl px-4 py-6 lg:flex lg:gap-6">
      <MenuLateral cats={todas} atual={slug} />
      <div className="min-w-0 flex-1">
      <nav aria-label="Caminho" className="mb-4 flex items-center gap-1 text-xs text-black/55">
        <Link href="/" className="hover:text-magenta">Início</Link><ChevronRight className="h-3 w-3" aria-hidden />
        <Link href="/categorias" className="hover:text-magenta">Produtos</Link><ChevronRight className="h-3 w-3" aria-hidden /><span className="text-tinta">{c.nome}</span>
      </nav>
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div><h1 className="text-3xl font-black">{c.nome}</h1><p className="mt-1 text-sm text-black/60">{r.total} {r.total === 1 ? 'modelo' : 'modelos'}{q ? ` para "${q}"` : ''}</p></div>
        <form className="flex w-full gap-2 sm:w-auto" role="search">
          <input name="q" defaultValue={q ?? ''} placeholder={`Filtrar em ${c.nome}`} aria-label="Filtrar produtos" className="h-11 flex-1 rounded-lg border border-black/15 bg-white px-3 sm:w-64" />
          <button className="h-11 rounded-lg bg-tinta px-4 text-sm font-bold text-white">Filtrar</button>
        </form>
      </div>
      <div className="mt-6 grid grid-cols-2 gap-3 sm:grid-cols-3 xl:grid-cols-4">{r.modelos.map((m) => <ModeloCard key={m.produto_slug} m={m} />)}</div>
      <Paginacao base={`/categoria/${slug}`} pagina={pg} total={r.total} porPagina={24} params={{ q: q?.trim() }} />
      <div className="mt-8"><CobrimosBanner /></div>
      </div>
    </div>
  )
}
