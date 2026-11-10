import type { Metadata } from 'next'
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { ChevronRight, ImageOff } from 'lucide-react'
import { brl } from '@/lib/site'
import { arvore, familia, fotoUrl, limparTitulo } from '@/lib/vitrine'

export const revalidate = 900

export async function generateMetadata({ params }: { params: Promise<{ familia: string }> }): Promise<Metadata> {
  const f = await familia((await params).familia)
  if (!f) return { title: 'Opção não encontrada' }
  const menor = Math.min(...f.tamanhos.map((t) => t.a_partir_de))
  return { title: `${limparTitulo(f.titulo)}: tamanhos e preços`, description: `${limparTitulo(f.titulo)} em ${f.tamanhos.length} tamanhos a partir de ${brl(menor)}. Pix ou 2x sem juros e retirada grátis na Praça Sete.`, alternates: { canonical: `/opcao/${f.familia}` } }
}

/** Nível 3 da navegação: escolhe o tamanho e segue para o produto. */
export default async function PaginaOpcao({ params }: { params: Promise<{ familia: string }> }) {
  const f = await familia((await params).familia)
  if (!f) notFound()
  const verticais = await arvore()
  const v = verticais.find((x) => x.categorias.some((c) => c.slug === f.categoria_slug))
  const foto = fotoUrl(f.foto)
  return (
    <div className="mx-auto max-w-5xl px-4 py-6">
      <nav aria-label="Caminho" className="mb-4 flex flex-wrap items-center gap-1 text-xs text-black/55">
        <Link href="/" className="hover:text-magenta">Início</Link><ChevronRight className="h-3 w-3" aria-hidden />
        {v && <><Link href={`/categorias?vertical=${v.id}`} className="hover:text-magenta">{v.nome}</Link><ChevronRight className="h-3 w-3" aria-hidden /></>}
        <Link href={`/categoria/${f.categoria_slug}`} className="hover:text-magenta">{f.categoria}</Link><ChevronRight className="h-3 w-3" aria-hidden />
        {f.sub && f.subcategoria && <><Link href={`/categoria/${f.categoria_slug}?sub=${f.sub}`} className="hover:text-magenta">{f.subcategoria}</Link><ChevronRight className="h-3 w-3" aria-hidden /></>}
        <span className="text-tinta">{limparTitulo(f.titulo)}</span>
      </nav>
      <div className="grid gap-6 md:grid-cols-[16rem_1fr]">
        <div className="aspect-square overflow-hidden rounded-xl2 bg-papel">
          {foto
            // eslint-disable-next-line @next/next/no-img-element
            ? <img src={foto} alt={limparTitulo(f.titulo)} width={512} height={512} className="h-full w-full object-cover" />
            : <div className="flex h-full items-center justify-center text-black/25"><ImageOff className="h-10 w-10" aria-hidden /></div>}
        </div>
        <div>
          <p className="text-xs font-semibold uppercase tracking-wide text-magenta">{f.categoria}{f.subcategoria ? ` · ${f.subcategoria}` : ''}</p>
          <h1 className="mt-1 text-3xl font-black leading-tight">{limparTitulo(f.titulo)}</h1>
          {f.tags && f.tags.length > 0 && <ul className="mt-3 flex flex-wrap gap-1.5">{f.tags.map((t) => <li key={t} className="rounded-full bg-papel px-2.5 py-1 text-xs font-medium">{t}</li>)}</ul>}
          <h2 className="mt-6 text-lg font-black">Escolha o tamanho</h2>
          <p className="text-sm text-black/60">{f.tamanhos.length} {f.tamanhos.length === 1 ? 'tamanho disponível' : 'tamanhos disponíveis'}. Na próxima tela você escolhe a quantidade e anexa o PDF.</p>
          <ul className="mt-3 divide-y divide-black/5 overflow-hidden rounded-xl2 bg-white shadow-sm">
            {f.tamanhos.map((t) => (
              <li key={t.produto_slug}>
                <Link href={`/produto/${t.produto_slug}`} className="flex min-h-14 flex-wrap items-center justify-between gap-x-4 gap-y-1 px-4 py-3 hover:bg-papel focus-visible:outline focus-visible:outline-2 focus-visible:outline-magenta">
                  <span><b className="block text-sm">{t.tamanho}</b>{t.impressao && <span className="text-xs text-black/55">{t.impressao}</span>}</span>
                  <span className="text-right"><span className="block text-xs text-black/55">A partir de</span><b className="text-base">{brl(t.a_partir_de)}</b> <span className="text-xs text-black/60">para {(t.quantidade ?? 1).toLocaleString('pt-BR')} {(t.quantidade ?? 1) === 1 ? 'unidade' : 'unidades'}</span></span>
                </Link>
              </li>
            ))}
          </ul>
        </div>
      </div>
    </div>
  )
}
