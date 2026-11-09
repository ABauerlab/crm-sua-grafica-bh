import type { Metadata } from 'next'
import Link from 'next/link'
import { Newspaper } from 'lucide-react'
import { dataBR, listaBlog, POR_PAGINA } from '@/lib/blog'

export const revalidate = 1800

export async function generateMetadata({ searchParams }: { searchParams: Promise<{ pagina?: string }> }): Promise<Metadata> {
  const p = Number((await searchParams).pagina) || 1
  return {
    title: p > 1 ? `Blog: novidades de impressão e embalagens (página ${p})` : 'Blog: novidades de impressão, embalagens e comunicação visual',
    description: 'Notícias do mercado gráfico explicadas de um jeito simples, com dicas práticas de impressos, embalagens e comunicação visual para o seu negócio.',
    alternates: { canonical: p > 1 ? `/blog?pagina=${p}` : '/blog' },
  }
}

export default async function Blog({ searchParams }: { searchParams: Promise<{ pagina?: string }> }) {
  const pagina = Math.max(1, Number((await searchParams).pagina) || 1)
  const { total, posts } = await listaBlog(pagina)
  const paginas = Math.max(1, Math.ceil(total / POR_PAGINA))
  return (
    <div className="mx-auto max-w-7xl px-4 py-10">
      <h1 className="flex items-center gap-3 text-3xl font-black"><Newspaper className="h-8 w-8 text-magenta" aria-hidden />Blog da Sua Gráfica BH</h1>
      <p className="mt-2 max-w-2xl text-black/65">Novidades do mercado de impressão, embalagens, design e comunicação visual, explicadas de um jeito simples e com ideias para aplicar no seu negócio.</p>
      {posts.length === 0 ? (
        <p className="mt-10 rounded-xl2 bg-white p-6 text-sm shadow-sm">Os primeiros posts estão sendo preparados. Enquanto isso, dá uma olhada nos <Link href="/categorias" className="font-semibold text-magenta underline">nossos produtos</Link>.</p>
      ) : (
        <ul className="mt-8 grid gap-6 sm:grid-cols-2 lg:grid-cols-3">
          {posts.map((p) => (
            <li key={p.slug} className="flex flex-col rounded-xl2 bg-white shadow-sm transition hover:shadow-md">
              <div className="h-2 rounded-t-xl2 bg-gradient-to-r from-ciano via-magenta to-amarelo" aria-hidden />
              <div className="flex flex-1 flex-col p-5">
                <p className="text-xs text-black/50">{dataBR(p.publicado_em)}{p.categorias[0] ? ` · ${p.categorias[0].nome}` : ''}</p>
                <h2 className="mt-2 text-lg font-bold leading-snug"><Link href={`/blog/${p.slug}`} className="hover:text-magenta">{p.titulo}</Link></h2>
                <p className="mt-2 flex-1 text-sm text-black/65">{p.resumo}</p>
                <Link href={`/blog/${p.slug}`} className="mt-4 text-sm font-bold text-magenta">Ler mais</Link>
              </div>
            </li>
          ))}
        </ul>
      )}
      {paginas > 1 && (
        <nav aria-label="Páginas" className="mt-10 flex justify-center gap-2 text-sm">
          {pagina > 1 && <Link href={pagina === 2 ? '/blog' : `/blog?pagina=${pagina - 1}`} className="rounded-lg bg-white px-4 py-2 font-semibold shadow-sm">Anteriores</Link>}
          <span className="px-3 py-2 text-black/55">Página {pagina} de {paginas}</span>
          {pagina < paginas && <Link href={`/blog?pagina=${pagina + 1}`} className="rounded-lg bg-white px-4 py-2 font-semibold shadow-sm">Próximos</Link>}
        </nav>
      )}
    </div>
  )
}
