import type { Metadata } from 'next'
import { BarraLateral } from '@/components/BarraLateral'
import { FiltrosBarra } from '@/components/FiltrosBarra'
import { ListaModelos } from '@/components/ListaModelos'
import { lerFiltros, lerOrdem, type ParamsUrl } from '@/lib/filtros'
import { linkWhatsApp } from '@/lib/site'
import { arvore, facetas, interpretarBusca, modelosFiltrados, type Filtros } from '@/lib/vitrine'

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
  const verticais = await arvore()
  const [r, f] = bruto ? await Promise.all([modelosFiltrados(null, { termo, filtros, ordem, limite: 2000 }), facetas(null, termo, filtros)]) : [{ total: 0, modelos: [] }, { total: 0, facetas: {} }]
  const ajustes = Object.keys(sinonimo.filtros).length > 0
  return (
    <div className="mx-auto max-w-[1440px] px-4 py-8 lg:flex lg:gap-5">
      <BarraLateral verticais={verticais} />
      <div className="min-w-0 flex-1">
        <h1 className="text-2xl font-black">{bruto ? `Resultados para "${bruto}"` : 'Busca'}</h1>
        <p className="mt-1 text-sm text-black/60">{r.total.toLocaleString('pt-BR')} {r.total === 1 ? 'produto' : 'produtos'}{ajustes ? '. Entendemos o que você quis dizer e já aplicamos os filtros abaixo.' : ''}</p>
        {bruto && <FiltrosBarra base="/busca" facetas={f.facetas} filtros={filtros} q={bruto} ordem={ordem} total={r.total} />}
        {r.total === 0 && bruto && (
          <p className="mt-6 rounded-xl2 bg-white p-6 text-sm">Não achamos esse item no site, mas fazemos sob medida.{' '}
            <a className="font-semibold text-magenta underline" href={linkWhatsApp(`Olá! Procurei "${bruto}" no site e não achei. Vocês fazem?`)} target="_blank" rel="noopener">Pergunte no WhatsApp</a>.</p>
        )}
        <ListaModelos modelos={r.modelos} />
      </div>
    </div>
  )
}
