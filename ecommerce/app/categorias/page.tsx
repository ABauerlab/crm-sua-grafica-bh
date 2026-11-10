import type { Metadata } from 'next'
import { redirect } from 'next/navigation'
import { MenuLateral } from '@/components/MenuLateral'
import { ModeloCard } from '@/components/ModeloCard'
import { Paginacao } from '@/components/Paginacao'
import { agrupar } from '@/lib/departamentos'
import { categorias, modelos } from '@/lib/vitrine'

export const revalidate = 900
export const metadata: Metadata = { title: 'Todos os produtos', description: 'Todos os modelos de impressos da Sua Gráfica BH com foto, referência e preço a partir de.', alternates: { canonical: '/categorias' } }
const POR_PAGINA = 24

export default async function Produtos({ searchParams }: { searchParams: Promise<{ q?: string; depto?: string; pagina?: string }> }) {
  const { q, depto, pagina } = await searchParams
  if (q?.trim()) redirect(`/busca?q=${encodeURIComponent(q.trim().toLowerCase())}`)
  const cats = await categorias()
  const d = agrupar(cats).find((x) => x.id === depto)
  const pg = Math.max(1, Number(pagina) || 1)
  const r = await modelos(d ? d.categorias.map((c) => c.slug) : null, { limite: POR_PAGINA, pagina: pg })
  return (
    <div className="mx-auto max-w-7xl px-4 py-6 lg:flex lg:gap-6">
      <MenuLateral cats={cats} />
      <section className="min-w-0 flex-1">
        <h1 className="text-3xl font-black">{d ? d.nome : 'Todos os produtos'}</h1>
        <p className="mt-1 text-sm text-black/60">{r.total.toLocaleString('pt-BR')} modelos com preço fechado. Escolha o modelo, a tiragem e a arte na página do produto.</p>
        <div className="mt-5 grid grid-cols-2 gap-3 sm:grid-cols-3 xl:grid-cols-4">{r.modelos.map((m) => <ModeloCard key={m.produto_slug} m={m} />)}</div>
        <Paginacao base="/categorias" pagina={pg} total={r.total} porPagina={POR_PAGINA} params={{ depto }} />
      </section>
    </div>
  )
}
