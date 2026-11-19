'use client'
import { useEffect, useRef, useState } from 'react'
import { Loader2, Plus, Search } from 'lucide-react'
import { brl } from '@/lib/site'
import { fotoUrl } from '@/lib/vitrine'
import type { ProdutoBusca } from '@/lib/pagar'

/** Busca de outro produto dentro do checkout. O cliente escolhe a quantidade (qualquer tiragem do catálogo) e adiciona; o preço é recalculado no servidor. */
export function BuscaProdutos({ ocupado, onAdicionar }: { ocupado: boolean; onAdicionar: (ref: string) => void }) {
  const [q, setQ] = useState('')
  const [lista, setLista] = useState<ProdutoBusca[] | null>(null)
  const [busy, setBusy] = useState(false)
  const [escolha, setEscolha] = useState<Record<string, string>>({})
  const seq = useRef(0)

  useEffect(() => {
    const termo = q.trim()
    if (termo.length < 2) { setLista(null); return }
    const n = ++seq.current
    const t = setTimeout(async () => {
      setBusy(true)
      try {
        const r = await fetch(`/api/v1/products/search?q=${encodeURIComponent(termo)}&limite=6`)
        const d = await r.json()
        if (n === seq.current) setLista(Array.isArray(d.produtos) ? d.produtos : [])
      } catch { if (n === seq.current) setLista([]) } finally { if (n === seq.current) setBusy(false) }
    }, 350)
    return () => clearTimeout(t)
  }, [q])

  return (
    <section aria-labelledby="busca-t" className="rounded-xl2 bg-white p-5 shadow-sm">
      <h2 id="busca-t" className="text-lg font-black">Procurando outro produto?</h2>
      <p className="mb-3 text-sm text-black/65">Pesquise, escolha a quantidade e adicione ao mesmo pedido, na mesma entrega.</p>
      <div className="relative">
        <Search className="pointer-events-none absolute left-3 top-1/2 h-5 w-5 -translate-y-1/2 text-black/40" aria-hidden />
        <label className="sr-only" htmlFor="busca-prod">Pesquisar produto</label>
        <input id="busca-prod" type="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder="Ex.: cartão de visita, adesivo, banner" className="h-12 w-full rounded-lg border border-black/15 pl-10 pr-3 text-base" />
        {busy && <Loader2 className="absolute right-3 top-1/2 h-4 w-4 -translate-y-1/2 animate-spin text-black/40" aria-hidden />}
      </div>
      {lista && lista.length === 0 && !busy && <p className="mt-3 text-sm text-black/65">Nenhum produto encontrado. Tente outra palavra ou fale com a gente no WhatsApp.</p>}
      {lista && lista.length > 0 && (
        <ul className="mt-3 space-y-3">
          {lista.map((p) => {
            const f = fotoUrl(p.foto)
            const ref = escolha[p.produto_slug] ?? p.opcoes[0]?.ref
            const op = p.opcoes.find((o) => o.ref === ref) ?? p.opcoes[0]
            return (
              <li key={p.produto_slug} className="flex gap-3 rounded-xl border border-black/10 p-3">
                {/* eslint-disable-next-line @next/next/no-img-element */}
                {f ? <img src={f} alt="" loading="lazy" className="h-16 w-16 shrink-0 rounded-lg bg-papel object-cover sm:h-20 sm:w-20" /> : <div className="h-16 w-16 shrink-0 rounded-lg bg-papel sm:h-20 sm:w-20" />}
                <div className="min-w-0 flex-1">
                  <h3 className="line-clamp-2 text-sm font-bold leading-snug">{p.titulo}</h3>
                  <div className="mt-2 flex flex-col gap-2 sm:flex-row sm:items-center">
                    <label className="sr-only" htmlFor={`q-${p.produto_slug}`}>Quantidade</label>
                    <select id={`q-${p.produto_slug}`} value={ref} onChange={(e) => setEscolha((x) => ({ ...x, [p.produto_slug]: e.target.value }))} className="h-11 min-w-0 flex-1 rounded-lg border border-black/15 bg-white px-2 text-sm">
                      {p.opcoes.map((o) => <option key={o.ref} value={o.ref}>{o.quantidade.toLocaleString('pt-BR')} un. · {brl(o.preco)}</option>)}
                    </select>
                    <button type="button" disabled={ocupado || !op} onClick={() => op && onAdicionar(op.ref)} className="inline-flex h-11 shrink-0 items-center justify-center gap-1 rounded-lg bg-tinta px-3 text-sm font-bold text-white hover:bg-magenta disabled:opacity-60"><Plus className="h-4 w-4" aria-hidden />Adicionar</button>
                  </div>
                </div>
              </li>
            )
          })}
        </ul>
      )}
    </section>
  )
}
