import Link from 'next/link'
import { ImageOff } from 'lucide-react'
import { brl } from '@/lib/site'
import { fotoUrl, limparTitulo, type Modelo } from '@/lib/vitrine'

/** Card compacto de uma opção: foto, nome completo (sem corte), etiquetas, quantidade e preço "a partir de". */
export function ModeloCard({ m }: { m: Modelo }) {
  const foto = fotoUrl(m.foto)
  const varios = (m.tamanhos ?? 1) > 1
  const href = varios && m.familia ? `/opcao/${m.familia}` : `/produto/${m.produto_slug}`
  const tags = (m.tags ?? []).slice(0, 3)
  const qtd = m.quantidade ?? 1
  return (
    <Link href={href} className="group flex flex-col overflow-hidden rounded-lg border border-black/5 bg-white shadow-sm transition hover:shadow-md focus-visible:outline focus-visible:outline-2 focus-visible:outline-magenta">
      <div className="relative aspect-[5/4] bg-papel">
        {foto
          // eslint-disable-next-line @next/next/no-img-element
          ? <img src={foto} alt={limparTitulo(m.titulo)} width={320} height={256} loading="lazy" className="h-full w-full object-cover" />
          : <div className="flex h-full items-center justify-center text-black/25"><ImageOff className="h-8 w-8" aria-hidden /></div>}
        {varios && <span className="absolute left-1.5 top-1.5 rounded-full bg-white/95 px-1.5 py-0.5 text-[10px] font-semibold text-tinta shadow-sm">{m.tamanhos} tamanhos</span>}
      </div>
      <div className="flex flex-1 flex-col gap-1 p-2.5">
        <span className="text-[10px] font-semibold uppercase leading-tight tracking-wide text-magenta">{m.subcategoria && m.subcategoria !== m.categoria ? m.subcategoria : m.categoria}</span>
        <span className="text-[13px] font-bold leading-snug">{limparTitulo(m.titulo)}</span>
        {tags.length > 0 && <ul className="flex flex-wrap gap-1" aria-label="Características">{tags.map((t) => <li key={t} className="rounded bg-papel px-1.5 py-0.5 text-[10px] font-medium leading-tight text-tinta/80">{t}</li>)}</ul>}
        <div className="mt-auto pt-1.5">
          <span className="text-[10px] text-black/55">A partir de</span>
          <div className="flex flex-wrap items-baseline gap-x-1.5"><span className="text-base font-black leading-tight">{brl(m.a_partir_de)}</span><span className="text-[11px] font-semibold text-black/60">/ {qtd.toLocaleString('pt-BR')} {qtd === 1 ? 'un.' : 'un.'}</span></div>
          {m.sku && <span className="mt-0.5 block text-[10px] text-black/45">Ref. <b className="font-mono text-tinta/80">{m.sku}</b></span>}
        </div>
      </div>
    </Link>
  )
}
