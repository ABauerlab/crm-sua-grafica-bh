import type { Metadata } from 'next'
import { ProdutoCard } from '@/components/ProdutoCard'
import { linkWhatsApp } from '@/lib/site'
import { buscar } from '@/lib/vitrine'

export const metadata: Metadata = { title: 'Busca', robots: { index: false } }

export default async function Busca({ searchParams }: { searchParams: Promise<{ q?: string }> }) {
  const { q } = await searchParams
  const termo = (q ?? '').trim().slice(0, 80)
  const r = termo ? await buscar(termo, null, 48) : { total: 0, produtos: [] }
  return (
    <div className="mx-auto max-w-7xl px-4 py-8">
      <h1 className="text-2xl font-black">{termo ? `Resultados para "${termo}"` : 'Busca'}</h1>
      <p className="mt-1 text-sm text-black/60">{r.total} {r.total === 1 ? 'produto' : 'produtos'}</p>
      {r.total === 0 && termo && (
        <p className="mt-6 rounded-xl2 bg-white p-6 text-sm">Não achamos esse item no site, mas fazemos sob medida.{' '}
          <a className="font-semibold text-magenta underline" href={linkWhatsApp(`Olá! Procurei "${termo}" no site e não achei. Vocês fazem?`)} target="_blank" rel="noopener">Pergunte no WhatsApp</a>.</p>
      )}
      <div className="mt-6 grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4">{r.produtos.map((p) => <ProdutoCard key={p.produto_slug} p={p} />)}</div>
    </div>
  )
}
