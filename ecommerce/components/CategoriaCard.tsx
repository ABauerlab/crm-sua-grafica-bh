import Link from 'next/link'
import { brl } from '@/lib/site'
import { fotoUrl, type CategoriaResumo } from '@/lib/vitrine'

const CORES = ['bg-ciano', 'bg-magenta', 'bg-amarelo']

export function CategoriaCard({ c, i }: { c: CategoriaResumo; i: number }) {
  const foto = fotoUrl(c.foto)
  return (
    <Link href={`/categoria/${c.slug}`} className="group flex flex-col overflow-hidden rounded-xl2 border border-black/5 bg-white shadow-sm transition hover:-translate-y-0.5 hover:shadow-md">
      <div className="relative aspect-[4/3] bg-papel">
        {foto
          // eslint-disable-next-line @next/next/no-img-element
          ? <img src={foto} alt="" loading="lazy" className="h-full w-full object-cover" />
          : <span className={`absolute left-3 top-3 h-1.5 w-10 rounded-full ${CORES[i % 3]}`} aria-hidden />}
      </div>
      <div className="flex flex-1 flex-col p-3">
        <span className="text-sm font-bold leading-snug group-hover:text-magenta">{c.nome}</span>
        <span className="mt-1 text-xs text-black/55">{c.produtos} {c.produtos === 1 ? 'produto' : 'produtos'} · a partir de <b className="text-tinta">{brl(c.a_partir_de)}</b></span>
      </div>
    </Link>
  )
}
