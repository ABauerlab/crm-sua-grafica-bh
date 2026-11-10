'use client'
import { useState } from 'react'
import Link from 'next/link'
import { Check, Plus } from 'lucide-react'
import { brl, carrinho } from '@/lib/carrinho'
import { fotoUrl, type Modelo } from '@/lib/vitrine'
import { ModalWhatsApp } from './ModalWhatsApp'

/** "Compre junto": 1 clique adiciona a menor tiragem do modelo sugerido ao carrinho. O preço é sempre recalculado no servidor. */
export function CompreJunto({ sugestoes }: { sugestoes: Modelo[] }) {
  const [feitos, setFeitos] = useState<string[]>([])
  const [pendente, setPendente] = useState<Modelo | null>(null)
  if (!sugestoes.length) return null
  function adicionar(m: Modelo) {
    carrinho.adicionar({ ref: m.ref, quantidade: 1, titulo: m.titulo, unidades: m.quantidade, preco: m.a_partir_de, foto: m.foto, slug: m.produto_slug })
    setFeitos((f) => [...f, m.ref])
  }
  return (
    <section className="mt-10" aria-labelledby="compre-junto">
      <h2 id="compre-junto" className="mb-1 text-xl font-black">Compre junto e aproveite a mesma entrega</h2>
      <p className="mb-4 text-sm text-black/60">Sugestões que combinam com o seu pedido. Você revisa tudo no carrinho antes de pagar.</p>
      <div className="grid gap-3 sm:grid-cols-2">
        {sugestoes.map((m) => {
          const f = fotoUrl(m.foto)
          const ok = feitos.includes(m.ref)
          return (
            <div key={m.ref} className="flex gap-3 rounded-xl2 bg-white p-3 shadow-sm">
              {f
                // eslint-disable-next-line @next/next/no-img-element
                ? <img src={f} alt="" loading="lazy" className="h-24 w-24 shrink-0 rounded-lg object-cover" />
                : <div className="h-24 w-24 shrink-0 rounded-lg bg-papel" />}
              <div className="flex min-w-0 flex-1 flex-col">
                <Link href={`/produto/${m.produto_slug}`} className="line-clamp-2 text-sm font-bold hover:text-magenta">{m.titulo}</Link>
                {m.sku && <span className="text-[11px] text-black/55">Ref. / SKU: <b className="font-mono">{m.sku}</b></span>}
                <span className="mt-auto text-sm">{m.quantidade ?? 1} un. por <b>{brl(m.a_partir_de)}</b></span>
                <button type="button" disabled={ok} onClick={() => (carrinho.cliente() ? adicionar(m) : setPendente(m))}
                  className="mt-1 inline-flex h-10 items-center justify-center gap-1 rounded-lg bg-tinta px-3 text-sm font-bold text-white hover:bg-magenta disabled:bg-[#0E8A3E]">
                  {ok ? <><Check className="h-4 w-4" aria-hidden />Adicionado</> : <><Plus className="h-4 w-4" aria-hidden />Adicionar com 1 clique</>}
                </button>
              </div>
            </div>
          )
        })}
      </div>
      <ModalWhatsApp aberto={!!pendente} onFechar={() => setPendente(null)} onConfirmar={() => { const m = pendente; setPendente(null); if (m) adicionar(m) }} />
    </section>
  )
}
