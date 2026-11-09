import Link from 'next/link'
import { brl } from '@/lib/site'
import type { CategoriaResumo } from '@/lib/vitrine'

const CORES = ['bg-ciano', 'bg-magenta', 'bg-amarelo']

export function CategoriaCard({ c, i }: { c: CategoriaResumo; i: number }) {
  return (
    <Link id={c.slug} href={`/categorias#${c.slug}`} className="group flex flex-col justify-between rounded-xl2 border border-black/5 bg-white p-4 shadow-sm transition hover:-translate-y-0.5 hover:shadow-md">
      <span className={`mb-4 h-1.5 w-10 rounded-full ${CORES[i % 3]}`} aria-hidden />
      <span className="text-sm font-bold leading-snug group-hover:text-magenta">{c.nome}</span>
      <span className="mt-3 text-xs text-black/55">{c.produtos} {c.produtos === 1 ? 'produto' : 'produtos'}</span>
      <span className="text-xs text-black/55">a partir de <b className="text-base text-tinta">{brl(c.aPartirDe)}</b></span>
    </Link>
  )
}
