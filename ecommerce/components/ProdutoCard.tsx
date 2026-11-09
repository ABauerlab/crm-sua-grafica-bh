import Link from 'next/link'
import { ImageOff } from 'lucide-react'
import { brl } from '@/lib/site'
import { fotoUrl, type ProdutoResumo } from '@/lib/vitrine'

export function ProdutoCard({ p }: { p: ProdutoResumo }) {
  const foto = fotoUrl(p.foto)
  return (
    <Link href={`/produto/${p.produto_slug}`} className="group flex flex-col overflow-hidden rounded-xl2 border border-black/5 bg-white shadow-sm transition hover:-translate-y-0.5 hover:shadow-md">
      <div className="relative aspect-square bg-papel">
        {foto ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img src={foto} alt={p.titulo} loading="lazy" className="h-full w-full object-cover transition group-hover:scale-[1.03]" />
        ) : (
          <div className="flex h-full items-center justify-center text-black/25"><ImageOff className="h-10 w-10" aria-hidden /></div>
        )}
      </div>
      <div className="flex flex-1 flex-col gap-1 p-3">
        <span className="text-[11px] font-semibold uppercase tracking-wide text-magenta">{p.categoria}</span>
        <span className="line-clamp-2 text-sm font-bold leading-snug">{p.titulo}</span>
        {p.impressao && <span className="text-xs text-black/55">{p.impressao}</span>}
        <span className="mt-auto pt-2 text-xs text-black/55">a partir de</span>
        <span className="text-lg font-black leading-none">{brl(Number(p.a_partir_de))}</span>
        <span className="text-[11px] text-black/55">ou 2x de {brl(Number(p.parcela_2x_a_partir_de))} sem juros</span>
      </div>
    </Link>
  )
}
