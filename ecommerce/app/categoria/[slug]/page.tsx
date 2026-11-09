import type { Metadata } from 'next'
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { ChevronRight } from 'lucide-react'
import { CobrimosBanner } from '@/components/CobrimosBanner'
import { ProdutoCard } from '@/components/ProdutoCard'
import { buscar, categorias } from '@/lib/vitrine'

export const revalidate = 900

async function categoria(slug: string) {
  return (await categorias()).find((c) => c.slug === slug) ?? null
}

export async function generateMetadata({ params }: { params: Promise<{ slug: string }> }): Promise<Metadata> {
  const { slug } = await params
  const c = await categoria(slug)
  if (!c) return { title: 'Categoria não encontrada' }
  return { title: `${c.nome} personalizados`, description: `${c.nome} personalizados em Belo Horizonte: ${c.produtos} opções a partir de R$ ${c.a_partir_de.toFixed(2).replace('.', ',')}. Pix ou 2x sem juros, retirada grátis na Praça Sete e envio para todo o Brasil.`, alternates: { canonical: `/categoria/${slug}` } }
}

export default async function PaginaCategoria({ params, searchParams }: { params: Promise<{ slug: string }>; searchParams: Promise<{ q?: string }> }) {
  const { slug } = await params
  const { q } = await searchParams
  const c = await categoria(slug)
  if (!c) notFound()
  const r = await buscar(q?.trim() || null, slug, 48)
  return (
    <div className="mx-auto max-w-7xl px-4 py-6">
      <nav aria-label="Caminho" className="mb-4 flex items-center gap-1 text-xs text-black/55">
        <Link href="/" className="hover:text-magenta">Início</Link><ChevronRight className="h-3 w-3" aria-hidden />
        <Link href="/categorias" className="hover:text-magenta">Produtos</Link><ChevronRight className="h-3 w-3" aria-hidden /><span className="text-tinta">{c.nome}</span>
      </nav>
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div><h1 className="text-3xl font-black">{c.nome}</h1><p className="mt-1 text-sm text-black/60">{r.total} {r.total === 1 ? 'opção' : 'opções'}{q ? ` para "${q}"` : ''}</p></div>
        <form className="flex w-full gap-2 sm:w-auto" role="search">
          <input name="q" defaultValue={q ?? ''} placeholder={`Filtrar em ${c.nome}`} aria-label="Filtrar produtos" className="h-11 flex-1 rounded-lg border border-black/15 bg-white px-3 sm:w-64" />
          <button className="h-11 rounded-lg bg-tinta px-4 text-sm font-bold text-white">Filtrar</button>
        </form>
      </div>
      <div className="mt-6 grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4">{r.produtos.map((p) => <ProdutoCard key={p.produto_slug} p={p} />)}</div>
      {r.total > r.produtos.length && <p className="mt-4 text-center text-sm text-black/60">Mostrando {r.produtos.length} de {r.total}. Use o filtro para achar a opção exata.</p>}
      <div className="mt-8"><CobrimosBanner /></div>
    </div>
  )
}
