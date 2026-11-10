import type { Metadata } from 'next'
import { FiltrosChips, FiltrosLaterais } from '@/components/Filtros'
import { ModeloCard } from '@/components/ModeloCard'
import { Paginacao } from '@/components/Paginacao'
import { lerFiltros, lerOrdem, type ParamsUrl } from '@/lib/filtros'
import { linkWhatsApp } from '@/lib/site'
import { facetas, interpretarBusca, modelosFiltrados, type Filtros } from '@/lib/vitrine'

export const metadata: Metadata = { title: 'Busca', robots: { index: false } }

export default async function Busca({ searchParams }: { searchParams: Promise<ParamsUrl> }) {
  const sp = await searchParams
  const bruto = (typeof sp.q === 'string' ? sp.q : '').trim().slice(0, 80)
  const manual = lerFiltros(sp)
  // Linguagem do cliente vira filtro: "papel grosso aveludado" -> gramatura encorpada + soft touch
  const sinonimo = bruto ? await interpretarBusca(bruto) : { termo: null, filtros: {} as Filtros }
  const filtros: Filtros = { ...sinonimo.filtros, ...manual }
  const termo = sinonimo.termo
  const ordem = lerOrdem(sp)
  const pg = Math.max(1, Number(sp.pagina) || 1)
  const [r, f] = bruto ? await Promise.all([modelosFiltrados(null, { termo, filtros, ordem, limite: 24, pagina: pg }), facetas(null, termo, filtros)]) : [{ total: 0, modelos: [] }, { total: 0, facetas: {} }]
  const params: Record<string, string | undefined> = { q: bruto, ordem: ordem !== 'relevancia' ? ordem : undefined }
  for (const [k, v] of Object.entries(manual)) if (v?.length) params[k] = v.join(',')
  const ajustes = Object.keys(sinonimo.filtros).length > 0
  return (
    <div className="mx-auto max-w-7xl px-4 py-8 lg:flex lg:gap-6">
      {bruto && <FiltrosLaterais base="/busca" facetas={f.facetas} filtros={filtros} q={bruto} ordem={ordem} />}
      <div className="min-w-0 flex-1">
        <h1 className="text-2xl font-black">{bruto ? `Resultados para "${bruto}"` : 'Busca'}</h1>
        <p className="mt-1 text-sm text-black/60">{r.total} {r.total === 1 ? 'modelo' : 'modelos'}{ajustes ? '. Entendemos o que você quis dizer e já aplicamos os filtros abaixo.' : ''}</p>
        {bruto && <div className="mt-4"><FiltrosChips base="/busca" facetas={f.facetas} filtros={filtros} q={bruto} ordem={ordem} /></div>}
        {r.total === 0 && bruto && (
          <p className="mt-6 rounded-xl2 bg-white p-6 text-sm">Não achamos esse item no site, mas fazemos sob medida.{' '}
            <a className="font-semibold text-magenta underline" href={linkWhatsApp(`Olá! Procurei "${bruto}" no site e não achei. Vocês fazem?`)} target="_blank" rel="noopener">Pergunte no WhatsApp</a>.</p>
        )}
        <div className="mt-6 grid grid-cols-2 gap-3 sm:grid-cols-3 xl:grid-cols-4">{r.modelos.map((m) => <ModeloCard key={m.produto_slug} m={m} />)}</div>
        <Paginacao base="/busca" pagina={pg} total={r.total} porPagina={24} params={params} />
      </div>
    </div>
  )
}
