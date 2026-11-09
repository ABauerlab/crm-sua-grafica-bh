import type { Metadata } from 'next'
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { ChevronRight, ExternalLink, MessageCircle } from 'lucide-react'
import { PostCorpo } from '@/components/PostCorpo'
import { dataBR, postBlog } from '@/lib/blog'
import { linkWhatsApp, MENSAGENS_WHATSAPP, SITE } from '@/lib/site'

export const revalidate = 1800

export async function generateMetadata({ params }: { params: Promise<{ slug: string }> }): Promise<Metadata> {
  const p = await postBlog((await params).slug)
  if (!p) return { title: 'Post não encontrado' }
  return {
    title: p.titulo, description: p.resumo, alternates: { canonical: `/blog/${p.slug}` },
    openGraph: { type: 'article', title: p.titulo, description: p.resumo, publishedTime: p.publicado_em, modifiedTime: p.atualizado_em },
  }
}

export default async function PostPagina({ params }: { params: Promise<{ slug: string }> }) {
  const p = await postBlog((await params).slug)
  if (!p) notFound()
  const ld = {
    '@context': 'https://schema.org', '@type': 'BlogPosting', headline: p.titulo, description: p.resumo,
    datePublished: p.publicado_em, dateModified: p.atualizado_em, mainEntityOfPage: `${SITE.url}/blog/${p.slug}`, inLanguage: 'pt-BR',
    author: { '@type': 'Organization', name: SITE.nome, url: SITE.url },
    publisher: { '@type': 'Organization', name: SITE.nome, logo: { '@type': 'ImageObject', url: `${SITE.url}/marca/simbolo.svg` } },
    citation: p.fonte_url, about: p.categorias.map((c) => c.nome),
  }
  return (
    <article className="mx-auto max-w-3xl px-4 py-8">
      <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: JSON.stringify(ld).replace(/</g, '\\u003c') }} />
      <nav aria-label="Caminho" className="mb-4 flex items-center gap-1 text-xs text-black/55">
        <Link href="/" className="hover:text-magenta">Início</Link><ChevronRight className="h-3 w-3" aria-hidden />
        <Link href="/blog" className="hover:text-magenta">Blog</Link>
      </nav>
      <p className="text-sm text-black/50">{dataBR(p.publicado_em)}</p>
      <h1 className="mt-2 text-3xl font-black leading-tight md:text-4xl">{p.titulo}</h1>
      <p className="mt-3 text-lg text-black/65">{p.resumo}</p>
      <div className="my-6 h-1.5 w-24 rounded-full bg-gradient-to-r from-ciano via-magenta to-amarelo" aria-hidden />
      <PostCorpo md={p.corpo} />
      <p className="mt-8 rounded-lg bg-white p-4 text-sm text-black/65 shadow-sm">
        Pauta: <a href={p.fonte_url} target="_blank" rel="nofollow noopener" className="inline-flex items-center gap-1 font-semibold text-tinta underline">{p.fonte_nome}<ExternalLink className="h-3 w-3" aria-hidden /></a>.
        {' '}Texto e comentários da equipe da {SITE.nome}.
      </p>
      {p.categorias.length > 0 && (
        <section className="mt-8">
          <h2 className="text-lg font-bold">Produtos relacionados</h2>
          <ul className="mt-3 flex flex-wrap gap-2">
            {p.categorias.map((c) => <li key={c.slug}><Link href={`/categoria/${c.slug}`} className="inline-block rounded-full bg-tinta px-4 py-2 text-sm font-semibold text-white hover:bg-magenta">{c.nome}</Link></li>)}
          </ul>
        </section>
      )}
      <div className="mt-8 flex flex-col items-start gap-3 rounded-xl2 bg-tinta p-6 text-white sm:flex-row sm:items-center sm:justify-between">
        <p className="font-semibold">Quer colocar essa ideia em prática? A gente te ajuda a escolher o material certo.</p>
        <a href={linkWhatsApp(MENSAGENS_WHATSAPP.home)} target="_blank" rel="noopener" className="inline-flex shrink-0 items-center gap-2 rounded-lg bg-amarelo px-4 py-2.5 text-sm font-bold text-tinta"><MessageCircle className="h-4 w-4" aria-hidden />Falar no WhatsApp</a>
      </div>
      {p.relacionados.length > 0 && (
        <section className="mt-10">
          <h2 className="text-lg font-bold">Leia também</h2>
          <ul className="mt-3 space-y-3">
            {p.relacionados.map((r) => <li key={r.slug}><Link href={`/blog/${r.slug}`} className="block rounded-lg bg-white p-4 shadow-sm hover:shadow-md"><span className="font-semibold">{r.titulo}</span><span className="mt-1 block text-sm text-black/60">{r.resumo}</span></Link></li>)}
          </ul>
        </section>
      )}
    </article>
  )
}
