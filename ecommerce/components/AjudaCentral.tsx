'use client'
import { useMemo, useState } from 'react'
import { ChevronDown, Search } from 'lucide-react'
import { AJUDA, semAcento } from '@/lib/ajuda'

export function AjudaCentral() {
  const [q, setQ] = useState('')
  const termos = semAcento(q).split(/\s+/).filter((t) => t.length > 1)
  const cats = useMemo(() => AJUDA.map((c) => ({
    ...c, perguntas: termos.length ? c.perguntas.filter((x) => { const t = semAcento(`${c.titulo} ${x.p} ${x.r}`); return termos.every((k) => t.includes(k)) }) : c.perguntas,
  })).filter((c) => c.perguntas.length), [q]) // eslint-disable-line react-hooks/exhaustive-deps
  return (
    <div>
      <div className="relative">
        <Search className="pointer-events-none absolute left-4 top-1/2 h-5 w-5 -translate-y-1/2 text-black/40" aria-hidden />
        <input value={q} onChange={(e) => setQ(e.target.value)} type="search" placeholder="Busque sua dúvida: prazo, Pix, arquivo, retirada..." aria-label="Buscar na central de ajuda"
          className="h-14 w-full rounded-xl2 border border-black/10 bg-white pl-12 pr-4 text-base shadow-sm outline-none ring-magenta focus:ring-2" />
      </div>
      {!termos.length && (
        <nav aria-label="Categorias da ajuda" className="mt-6 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {AJUDA.map((c) => <a key={c.id} href={`#${c.id}`} className="rounded-xl2 bg-white p-4 shadow-sm hover:shadow-md"><span className="font-bold">{c.titulo}</span><span className="mt-1 block text-sm text-black/60">{c.resumo}</span></a>)}
        </nav>
      )}
      {cats.length === 0 && <p className="mt-8 text-sm text-black/60">Nada encontrado para &quot;{q}&quot;. Chama a gente no WhatsApp que a gente responde.</p>}
      <div className="mt-8 space-y-8">
        {cats.map((c) => (
          <section key={c.id} id={c.id} className="scroll-mt-40">
            <h2 className="text-xl font-black">{c.titulo}</h2>
            <div className="mt-3 divide-y divide-black/5 rounded-xl2 bg-white shadow-sm">
              {c.perguntas.map((x) => (
                <details key={x.p} className="group p-4" open={termos.length > 0}>
                  <summary className="flex cursor-pointer list-none items-center justify-between gap-4 font-semibold">{x.p}<ChevronDown className="h-4 w-4 shrink-0 transition group-open:rotate-180" aria-hidden /></summary>
                  <p className="mt-2 text-sm leading-relaxed text-black/70">{x.r}</p>
                </details>
              ))}
            </div>
          </section>
        ))}
      </div>
    </div>
  )
}
