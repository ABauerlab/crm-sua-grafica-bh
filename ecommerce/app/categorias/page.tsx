import type { Metadata } from 'next'
import { CategoriaCard } from '@/components/CategoriaCard'
import { categorias } from '@/lib/vitrine'

export const revalidate = 3600
export const metadata: Metadata = { title: 'Todos os produtos', description: 'Todas as categorias de impressos da Sua Gráfica BH com preço a partir de.', alternates: { canonical: '/categorias' } }

export default async function Categorias({ searchParams }: { searchParams: Promise<{ q?: string }> }) {
  const { q } = await searchParams
  const termo = (q ?? '').trim().toLowerCase()
  const todas = await categorias()
  const lista = termo ? todas.filter((c) => c.nome.toLowerCase().includes(termo)) : todas
  return (
    <section className="mx-auto max-w-7xl px-4 py-10">
      <h1 className="text-3xl font-black">Todos os produtos</h1>
      <p className="mt-1 text-sm text-black/60">{lista.length} categorias{termo ? ` para "${q}"` : ''}. As páginas de cada produto com configurador chegam na próxima etapa.</p>
      <div className="mt-6 grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-5">{lista.map((c, i) => <CategoriaCard key={c.slug} c={c} i={i} />)}</div>
    </section>
  )
}
