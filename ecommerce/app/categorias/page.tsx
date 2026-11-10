import type { Metadata } from 'next'
import { redirect } from 'next/navigation'
import { MenuLateral } from '@/components/MenuLateral'
import { ModeloCard } from '@/components/ModeloCard'
import { Paginacao } from '@/components/Paginacao'
import { arvore, modelosFiltrados } from '@/lib/vitrine'

export const revalidate = 900
export const metadata: Metadata = { title: 'Todos os produtos', description: 'Todos os modelos de impressos da Sua Gráfica BH organizados por departamento, com foto, referência e preço a partir de.', alternates: { canonical: '/categorias' } }
const POR_PAGINA = 24

export default async function Produtos({ searchParams }: { searchParams: Promise<{ q?: string; vertical?: string; depto?: string; pagina?: string }> }) {
  const { q, vertical, pagina } = await searchParams
  if (q?.trim()) redirect(`/busca?q=${encodeURIComponent(q.trim().toLowerCase())}`)
  const verticais = await arvore()
  const v = verticais.find((x) => x.id === vertical)
  const pg = Math.max(1, Number(pagina) || 1)
  const r = await modelosFiltrados(v ? v.categorias.map((c) => c.slug) : null, { limite: POR_PAGINA, pagina: pg })
  return (
    <div className="mx-auto max-w-7xl px-4 py-6 lg:flex lg:gap-6">
      <MenuLateral verticais={verticais} />
      <section className="min-w-0 flex-1">
        <h1 className="text-3xl font-black">{v ? v.nome : 'Todos os produtos'}</h1>
        <p className="mt-1 text-sm text-black/60">{v?.descricao ?? 'Escolha um departamento ou use a busca.'} {r.total.toLocaleString('pt-BR')} modelos com preço fechado.</p>
        {v && (
          <ul className="mt-4 flex flex-wrap gap-2">
            {v.categorias.slice(0, 24).map((c) => <li key={c.slug}><a href={`/categoria/${c.slug}`} className="inline-flex min-h-9 items-center rounded-full border border-black/15 bg-white px-3 text-xs font-semibold hover:border-magenta hover:text-magenta">{c.nome} ({c.modelos})</a></li>)}
          </ul>
        )}
        <div className="mt-5 grid grid-cols-2 gap-3 sm:grid-cols-3 xl:grid-cols-4">{r.modelos.map((m) => <ModeloCard key={m.produto_slug} m={m} />)}</div>
        <Paginacao base="/categorias" pagina={pg} total={r.total} porPagina={POR_PAGINA} params={{ vertical }} />
      </section>
    </div>
  )
}
