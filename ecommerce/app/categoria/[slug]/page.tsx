import type { Metadata } from 'next'
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { ChevronRight, ImageOff } from 'lucide-react'
import { BarraLateral } from '@/components/BarraLateral'
import { CobrimosBanner } from '@/components/CobrimosBanner'
import { FiltrosBarra } from '@/components/FiltrosBarra'
import { ListaModelos } from '@/components/ListaModelos'
import { lerFiltros, lerOrdem, type ParamsUrl } from '@/lib/filtros'
import { arvore, facetas, fotoUrl, modelosFiltrados } from '@/lib/vitrine'

export const revalidate = 900
const LIMITE = 2000

async function achar(slug: string) {
  const verticais = await arvore()
  for (const v of verticais) { const c = v.categorias.find((x) => x.slug === slug); if (c) return { v, c, verticais } }
  return null
}

export async function generateMetadata({ params }: { params: Promise<{ slug: string }> }): Promise<Metadata> {
  const { slug } = await params
  const a = await achar(slug)
  if (!a) return { title: 'Categoria não encontrada' }
  const { c } = a
  return { title: `${c.nome} personalizados`, description: `${c.nome} personalizados em Belo Horizonte: ${c.modelos} opções a partir de R$ ${c.a_partir_de.toFixed(2).replace('.', ',')}. Pix ou 2x sem juros, retirada grátis na Praça Sete e envio para todo o Brasil.`, alternates: { canonical: `/categoria/${slug}` } }
}

export default async function PaginaCategoria({ params, searchParams }: { params: Promise<{ slug: string }>; searchParams: Promise<ParamsUrl> }) {
  const { slug } = await params
  const sp = await searchParams
  const a = await achar(slug)
  if (!a) notFound()
  const { v, c, verticais } = a
  const q = typeof sp.q === 'string' ? sp.q.trim().slice(0, 80) : ''
  const filtros = lerFiltros(sp)
  const ordem = lerOrdem(sp)
  const base = `/categoria/${slug}`
  const semFiltro = !q && Object.keys(filtros).length === 0 && sp.todos !== '1'
  // Nível 2: quando a categoria tem subcategorias reais do fornecedor, o cliente escolhe uma antes de ver as opções
  const somaSubs = c.subcategorias.reduce((n, s) => n + s.modelos, 0)
  const mostrarSubs = semFiltro && c.subcategorias.length >= 2 && somaSubs >= c.modelos * 0.9

  const [r, f] = mostrarSubs ? [null, null] : await Promise.all([
    modelosFiltrados([slug], { termo: q || null, filtros, ordem, limite: LIMITE }),
    facetas([slug], q || null, filtros),
  ])
  const subAtiva = c.subcategorias.find((s) => s.slug === filtros.sub?.[0])
  return (
    <div className="mx-auto max-w-[1440px] px-4 py-6 lg:flex lg:gap-5">
      <BarraLateral verticais={verticais} atual={slug} subAtual={filtros.sub?.[0]} />
      <div className="min-w-0 flex-1">
        <nav aria-label="Caminho" className="mb-4 flex flex-wrap items-center gap-1 text-xs text-black/55">
          <Link href="/" className="hover:text-magenta">Início</Link><ChevronRight className="h-3 w-3" aria-hidden />
          <Link href={`/categorias?vertical=${v.id}`} className="hover:text-magenta">{v.nome}</Link><ChevronRight className="h-3 w-3" aria-hidden />
          {subAtiva ? <><Link href={base} className="hover:text-magenta">{c.nome}</Link><ChevronRight className="h-3 w-3" aria-hidden /><span className="text-tinta">{subAtiva.nome}</span></> : <span className="text-tinta">{c.nome}</span>}
        </nav>
        <div className="flex flex-wrap items-end justify-between gap-4">
          <div>
            <h1 className="text-2xl font-black md:text-3xl">{subAtiva ? `${c.nome}: ${subAtiva.nome}` : c.nome}</h1>
            <p className="mt-1 text-sm text-black/60">
              {mostrarSubs ? `Escolha o tipo de ${c.nome.toLowerCase()}. ${c.modelos} opções no total.` : `${(r?.total ?? 0).toLocaleString('pt-BR')} ${(r?.total ?? 0) === 1 ? 'produto' : 'produtos'}${q ? ` para "${q}"` : ''}. Cada produto já traz a quantidade, a impressão e o preço.`}
            </p>
          </div>
          <form className="flex w-full gap-2 sm:w-auto" role="search">
            <input name="q" defaultValue={q} placeholder={`Buscar em ${c.nome}`} aria-label="Buscar nesta categoria" className="h-11 flex-1 rounded-lg border border-black/15 bg-white px-3 sm:w-64" />
            <button className="h-11 rounded-lg bg-tinta px-4 text-sm font-bold text-white">Buscar</button>
          </form>
        </div>

        {mostrarSubs ? (
          <>
            <ul className="mt-4 grid grid-cols-2 gap-2.5 sm:grid-cols-3 xl:grid-cols-5 2xl:grid-cols-6">
              {c.subcategorias.map((s) => {
                const foto = fotoUrl(s.foto)
                return (
                  <li key={s.slug}>
                    <Link href={`${base}?sub=${s.slug}`} className="group flex h-full flex-col overflow-hidden rounded-lg border border-black/5 bg-white shadow-sm transition hover:shadow-md focus-visible:outline focus-visible:outline-2 focus-visible:outline-magenta">
                      <div className="aspect-[3/2] bg-papel">
                        {foto
                          // eslint-disable-next-line @next/next/no-img-element
                          ? <img src={foto} alt="" width={400} height={300} loading="lazy" className="h-full w-full object-cover transition group-hover:scale-[1.03]" />
                          : <div className="flex h-full items-center justify-center text-black/25"><ImageOff className="h-8 w-8" aria-hidden /></div>}
                      </div>
                      <div className="p-2.5"><b className="block text-[13px] leading-snug">{s.nome}</b><span className="text-xs text-black/55">{s.modelos} {s.modelos === 1 ? 'opção' : 'opções'}</span></div>
                    </Link>
                  </li>
                )
              })}
            </ul>
            <p className="mt-4 text-sm"><Link href={`${base}?todos=1`} className="font-semibold text-magenta underline">Ver todas as {c.modelos} opções de {c.nome} de uma vez</Link></p>
          </>
        ) : (
          <>
            <FiltrosBarra base={base} facetas={f!.facetas} filtros={filtros} q={q || undefined} ordem={ordem} total={r!.total} />
            {r!.total === 0
              ? <p className="mt-8 rounded-xl2 bg-white p-6 text-sm">Nenhuma opção com essa combinação. Remova algum filtro acima ou fale com a gente: fazemos sob medida.</p>
              : <ListaModelos modelos={r!.modelos} />}
          </>
        )}
        <div className="mt-8"><CobrimosBanner /></div>
      </div>
    </div>
  )
}
