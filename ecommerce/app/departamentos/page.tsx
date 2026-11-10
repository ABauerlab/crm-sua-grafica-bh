import type { Metadata } from 'next'
import Link from 'next/link'
import { arvore } from '@/lib/vitrine'

export const revalidate = 3600
export const metadata: Metadata = {
  title: 'Todos os departamentos',
  description: 'Veja todos os departamentos da Sua Gráfica BH e o que cada um tem: papelaria, embalagens, rótulos, editorial, comunicação visual, brindes e festas.',
  alternates: { canonical: '/departamentos' },
}

/** Índice de todos os departamentos, cada um com suas categorias e exemplos do que tem dentro. */
export default async function Departamentos() {
  const verticais = await arvore()
  return (
    <div className="mx-auto max-w-7xl px-4 py-8">
      <h1 className="text-3xl font-black">Todos os departamentos</h1>
      <p className="mt-1 max-w-2xl text-sm text-black/60">Escolha o departamento, depois a categoria. Em cada categoria você escolhe o tipo, a opção, o tamanho e a quantidade.</p>
      <nav aria-label="Ir para o departamento" className="mt-4 flex flex-wrap gap-2">
        {verticais.map((v) => <a key={v.id} href={`#${v.id}`} className="inline-flex min-h-11 items-center rounded-full border border-black/15 bg-white px-4 text-sm font-semibold hover:border-magenta hover:text-magenta">{v.nome}</a>)}
      </nav>
      <div className="mt-8 space-y-10">
        {verticais.map((v) => (
          <section key={v.id} id={v.id} aria-labelledby={`t-${v.id}`} className="scroll-mt-40">
            <div className="flex flex-wrap items-end justify-between gap-2 border-b border-black/10 pb-2">
              <div><h2 id={`t-${v.id}`} className="text-xl font-black">{v.nome}</h2><p className="text-sm text-black/60">{v.descricao}</p></div>
              <Link href={`/categorias?vertical=${v.id}`} className="text-sm font-semibold text-magenta hover:underline">Ver tudo ({v.modelos.toLocaleString('pt-BR')} opções)</Link>
            </div>
            <ul className="mt-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">
              {v.categorias.map((c) => (
                <li key={c.slug}>
                  <Link href={`/categoria/${c.slug}`} className="block h-full rounded-xl2 border border-black/5 bg-white p-4 shadow-sm transition hover:-translate-y-0.5 hover:shadow-md focus-visible:outline focus-visible:outline-2 focus-visible:outline-magenta">
                    <b className="block text-sm leading-snug">{c.nome}</b>
                    <span className="text-xs text-black/55">{c.modelos} {c.modelos === 1 ? 'opção' : 'opções'}</span>
                    {c.subcategorias.length > 0 && <span className="mt-2 block text-xs text-black/65">{c.subcategorias.slice(0, 4).map((s) => s.nome).join(', ')}{c.subcategorias.length > 4 ? '…' : ''}</span>}
                  </Link>
                </li>
              ))}
            </ul>
          </section>
        ))}
      </div>
    </div>
  )
}
