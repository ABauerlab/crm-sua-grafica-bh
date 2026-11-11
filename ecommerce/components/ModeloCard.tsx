import Link from 'next/link'
import { ImageOff } from 'lucide-react'
import { brl } from '@/lib/site'
import { fotoUrl, impressaoCurta, limparTitulo, type Modelo } from '@/lib/vitrine'

/** Card compacto de UM SKU (um SKU = um produto): foto, nome, impressão, quantidade, preço, prazo e Ref. */
export function ModeloCard({ m }: { m: Modelo }) {
  const foto = fotoUrl(m.foto)
  const href = `/produto/${m.sku_slug ?? m.produto_slug}`
  const qtd = m.quantidade ?? 1
  const tamanho = m.formato?.split(' (')[0]
  const detalhe = [impressaoCurta(m.impressao), tamanho].filter(Boolean).join(' · ')
  return (
    <Link href={href} className="group flex flex-col overflow-hidden rounded-lg border border-black/5 bg-white shadow-sm transition hover:shadow-md focus-visible:outline focus-visible:outline-2 focus-visible:outline-magenta">
      <div className="relative aspect-[4/3] bg-papel">
        {foto
          // eslint-disable-next-line @next/next/no-img-element
          ? <img src={foto} alt={limparTitulo(m.titulo)} width={240} height={180} loading="lazy" className="h-full w-full object-cover" />
          : <div className="flex h-full items-center justify-center text-black/25"><ImageOff className="h-7 w-7" aria-hidden /></div>}
      </div>
      <div className="flex flex-1 flex-col gap-0.5 p-2">
        <span className="line-clamp-2 text-[12px] font-bold leading-snug">{limparTitulo(m.titulo)}</span>
        {detalhe && <span className="line-clamp-1 text-[11px] leading-snug text-black/60">{detalhe}</span>}
        <div className="mt-auto flex flex-wrap items-center gap-x-1.5 pt-1">
          <span className="text-sm font-black leading-tight">{brl(m.a_partir_de)}</span>
          <span className="text-[11px] font-semibold text-black/60">/ {qtd.toLocaleString('pt-BR')} un.</span>
          {m.variante && <span className="rounded bg-amarelo/60 px-1 py-px text-[10px] font-semibold text-tinta">{m.variante}</span>}
        </div>
        <div className="flex flex-wrap items-center justify-between gap-x-2 text-[10px] text-black/50">
          {m.sku && <span>Ref. <b className="font-mono text-tinta/80">{m.sku}</b></span>}
          {m.prazo_dias_uteis ? <span>Produção: {m.prazo_dias_uteis} {m.prazo_dias_uteis === 1 ? 'dia útil' : 'dias úteis'}</span> : null}
        </div>
      </div>
    </Link>
  )
}
