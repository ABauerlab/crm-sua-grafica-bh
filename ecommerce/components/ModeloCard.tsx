import Link from 'next/link'
import { ImageOff } from 'lucide-react'
import { brl } from '@/lib/site'
import { fotoUrl, limparTitulo, type Modelo } from '@/lib/vitrine'

/** Card de uma opção de produto: foto, nome completo (sem corte), etiquetas de acabamento, quantidade e preço "a partir de". */
export function ModeloCard({ m }: { m: Modelo }) {
  const foto = fotoUrl(m.foto)
  const varios = (m.tamanhos ?? 1) > 1
  const href = varios && m.familia ? `/opcao/${m.familia}` : `/produto/${m.produto_slug}`
  const tags = (m.tags ?? []).slice(0, 4)
  const qtd = m.quantidade ?? 1
  return (
    <Link href={href} className="group flex flex-col overflow-hidden rounded-xl2 border border-black/5 bg-white shadow-sm transition hover:-translate-y-0.5 hover:shadow-md focus-visible:outline focus-visible:outline-2 focus-visible:outline-magenta">
      <div className="relative aspect-square bg-papel">
        {foto
          // eslint-disable-next-line @next/next/no-img-element
          ? <img src={foto} alt={limparTitulo(m.titulo)} width={400} height={400} loading="lazy" className="h-full w-full object-cover transition group-hover:scale-[1.03]" />
          : <div className="flex h-full items-center justify-center text-black/25"><ImageOff className="h-10 w-10" aria-hidden /></div>}
        {varios && <span className="absolute left-2 top-2 rounded-full bg-white/95 px-2 py-0.5 text-[11px] font-semibold text-tinta shadow-sm">{m.tamanhos} tamanhos</span>}
      </div>
      <div className="flex flex-1 flex-col gap-1.5 p-3">
        <span className="text-[11px] font-semibold uppercase tracking-wide text-magenta">{m.subcategoria && m.subcategoria !== m.categoria ? `${m.categoria} · ${m.subcategoria}` : m.categoria}</span>
        <span className="text-sm font-bold leading-snug">{limparTitulo(m.titulo)}</span>
        {tags.length > 0 && <ul className="flex flex-wrap gap-1" aria-label="Características">{tags.map((t) => <li key={t} className="rounded-full bg-papel px-2 py-0.5 text-[11px] font-medium text-tinta/80">{t}</li>)}</ul>}
        {m.sku && <span className="text-[11px] text-black/55">Ref. / SKU: <b className="font-mono text-tinta">{m.sku}</b></span>}
        <span className="mt-auto pt-2 text-xs text-black/55">A partir de</span>
        <span className="text-lg font-black leading-none">{brl(m.a_partir_de)} <span className="text-xs font-semibold text-black/60">para {qtd.toLocaleString('pt-BR')} {qtd === 1 ? 'unidade' : 'unidades'}</span></span>
        <span className="text-[11px] text-black/55">ou 2x de {brl(m.parcela_2x_a_partir_de)} sem juros</span>
        <span className="mt-2 rounded-lg bg-tinta px-3 py-2 text-center text-xs font-bold text-white group-hover:bg-magenta">{varios ? 'Ver tamanhos' : 'Personalizar / Ver opções'}</span>
      </div>
    </Link>
  )
}
