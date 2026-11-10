import Link from 'next/link'
import { ImageOff } from 'lucide-react'
import { brl } from '@/lib/site'
import { fotoUrl, type Modelo } from '@/lib/vitrine'

/** Card de um modelo comercial real: foto, nome do papel/acabamento, SKU, preço e botão. Nunca um cartão de contagem. */
const SELOS: Record<string, string> = { 'hot-stamping': 'Hot Stamping', 'soft-touch': 'Soft Touch', uv: 'Verniz UV', relevo: 'Relevo seco', holografica: 'Holográfico', fosca: 'Laminação fosca', brilho: 'Laminação brilho' }

export function ModeloCard({ m }: { m: Modelo }) {
  const foto = fotoUrl(m.foto)
  const selos = (m.acab ?? []).filter((a) => SELOS[a]).slice(0, 2).map((a) => SELOS[a])
  if (m.prazo_dias_uteis && m.prazo_dias_uteis <= 1) selos.push('Produção 24h')
  return (
    <Link href={`/produto/${m.produto_slug}`} className="group flex flex-col overflow-hidden rounded-xl2 border border-black/5 bg-white shadow-sm transition hover:-translate-y-0.5 hover:shadow-md">
      <div className="relative aspect-square bg-papel">
        {foto
          // eslint-disable-next-line @next/next/no-img-element
          ? <img src={foto} alt={m.titulo} loading="lazy" className="h-full w-full object-cover transition group-hover:scale-[1.03]" />
          : <div className="flex h-full items-center justify-center text-black/25"><ImageOff className="h-10 w-10" aria-hidden /></div>}
        {selos.length > 0 && <span className="absolute right-2 top-2 flex flex-col items-end gap-1">{selos.map((x) => <span key={x} className="rounded-full bg-tinta/90 px-2 py-0.5 text-[10px] font-semibold text-white shadow-sm">{x}</span>)}</span>}
        {m.variacoes > 1 && <span className="absolute left-2 top-2 rounded-full bg-white/90 px-2 py-0.5 text-[11px] font-semibold text-tinta shadow-sm">{m.variacoes} opções de impressão</span>}
      </div>
      <div className="flex flex-1 flex-col gap-1 p-3">
        <span className="text-[11px] font-semibold uppercase tracking-wide text-magenta">{m.subcategoria ? `${m.categoria} · ${m.subcategoria}` : m.categoria}</span>
        <span className="line-clamp-3 text-sm font-bold leading-snug">{m.titulo}</span>
        {m.sku && <span className="text-[11px] text-black/55">Ref. / SKU: <b className="font-mono text-tinta">{m.sku}</b></span>}
        <span className="mt-auto pt-2 text-xs text-black/55">A partir de</span>
        <span className="text-lg font-black leading-none">{brl(m.a_partir_de)}</span>
        <span className="text-[11px] text-black/55">ou 2x de {brl(m.parcela_2x_a_partir_de)} sem juros</span>
        <span className="mt-2 rounded-lg bg-tinta px-3 py-2 text-center text-xs font-bold text-white group-hover:bg-magenta">Personalizar / Ver opções</span>
      </div>
    </Link>
  )
}
