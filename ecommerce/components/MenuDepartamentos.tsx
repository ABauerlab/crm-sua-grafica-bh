'use client'
import { useMemo, useState } from 'react'
import Link from 'next/link'
import { ChevronDown, Search } from 'lucide-react'
import { buscarItens, itensDeBusca } from '@/lib/menu'
import type { Vertical } from '@/lib/vitrine'

/** Menu de departamentos em etapas: tudo fechado ao abrir; o cliente abre o departamento, depois a categoria, depois o tipo. A busca encontra categorias e tipos de qualquer departamento. */
export function MenuDepartamentos({ verticais, atual, subAtual, aoNavegar }: { verticais: Vertical[]; atual?: string; subAtual?: string; aoNavegar?: () => void }) {
  const [q, setQ] = useState('')
  const [aberto, setAberto] = useState<Record<string, boolean>>({})
  const itens = useMemo(() => itensDeBusca(verticais), [verticais])
  const achados = useMemo(() => buscarItens(itens, q), [itens, q])
  const alterna = (id: string) => setAberto((a) => ({ ...a, [id]: !a[id] }))
  const cls = (ativo: boolean) => (ativo ? 'font-bold text-magenta' : 'text-tinta/80')

  return (
    <nav aria-label="Departamentos">
      <div className="relative mb-2 px-1">
        <Search className="pointer-events-none absolute left-4 top-1/2 h-4 w-4 -translate-y-1/2 text-black/40" aria-hidden />
        <input type="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder="Achar categoria" aria-label="Achar categoria ou tipo de produto"
          className="h-11 w-full rounded-lg border border-black/15 bg-white pl-9 pr-3 text-base outline-none focus:border-magenta" />
      </div>

      {q.trim().length >= 2 ? (
        achados.length === 0
          ? <p className="px-3 py-4 text-sm text-black/60">Nada encontrado para "{q}". Tente outra palavra ou veja <Link href="/departamentos" onClick={aoNavegar} className="font-semibold text-magenta underline">todos os departamentos</Link>.</p>
          : <ul className="space-y-0.5">{achados.map((i) => (
              <li key={i.href}><Link href={i.href} onClick={aoNavegar} className="flex min-h-11 flex-col justify-center rounded-md px-3 py-1 hover:bg-papel">
                <span className="text-sm font-semibold">{i.nome}</span><span className="text-xs text-black/55">{i.tipo === 'categoria' ? `Departamento: ${i.contexto}` : `em ${i.contexto}`}</span></Link></li>
            ))}</ul>
      ) : (
        <ul className="space-y-1">
          {verticais.map((v) => {
            const dentro = v.categorias.some((c) => c.slug === atual)
            const abertoV = !!aberto[v.id]
            return (
              <li key={v.id}>
                <button type="button" onClick={() => alterna(v.id)} aria-expanded={abertoV} aria-controls={`painel-${v.id}`}
                  className="flex min-h-11 w-full items-center justify-between gap-2 rounded-lg px-3 text-left text-sm font-bold hover:bg-papel">
                  <span className={dentro ? 'text-magenta' : ''}>{v.nome}</span>
                  <ChevronDown className={`h-4 w-4 shrink-0 transition ${abertoV ? 'rotate-180' : ''}`} aria-hidden />
                </button>
                <ul id={`painel-${v.id}`} hidden={!abertoV} className="mb-2 ml-3 border-l border-black/10 pl-2">
                  <li><Link href={`/categorias?vertical=${v.id}`} onClick={aoNavegar} className="flex min-h-10 items-center px-2 text-xs font-semibold text-magenta hover:underline">Ver tudo em {v.nome}</Link></li>
                  {v.categorias.map((c) => {
                    const idC = `${v.id}/${c.slug}`
                    const abertoC = !!aberto[idC]
                    const temSubs = c.subcategorias.length > 0
                    return (
                      <li key={c.slug}>
                        <div className="flex items-center">
                          <Link href={`/categoria/${c.slug}`} onClick={aoNavegar} aria-current={c.slug === atual && !subAtual ? 'page' : undefined}
                            className={`flex min-h-10 flex-1 items-center rounded-md px-2 text-sm hover:text-magenta ${cls(c.slug === atual)}`}>{c.nome}</Link>
                          {temSubs && (
                            <button type="button" onClick={() => alterna(idC)} aria-expanded={abertoC} aria-label={`Tipos de ${c.nome}`}
                              className="flex h-10 w-10 shrink-0 items-center justify-center rounded-md hover:bg-papel"><ChevronDown className={`h-4 w-4 transition ${abertoC ? 'rotate-180' : ''}`} aria-hidden /></button>
                          )}
                        </div>
                        {temSubs && (
                          <ul hidden={!abertoC} className="mb-1 ml-3 border-l border-black/10 pl-2">
                            {c.subcategorias.map((s) => (
                              <li key={s.slug}><Link href={`/categoria/${c.slug}?sub=${s.slug}`} onClick={aoNavegar} rel="nofollow"
                                className={`flex min-h-10 items-center rounded-md px-2 text-xs hover:text-magenta ${cls(c.slug === atual && s.slug === subAtual)}`}>{s.nome}</Link></li>
                            ))}
                          </ul>
                        )}
                      </li>
                    )
                  })}
                </ul>
              </li>
            )
          })}
          <li><Link href="/departamentos" onClick={aoNavegar} className="flex min-h-11 items-center px-3 text-sm font-semibold text-magenta underline">Ver todos os departamentos em uma lista</Link></li>
        </ul>
      )}
    </nav>
  )
}
