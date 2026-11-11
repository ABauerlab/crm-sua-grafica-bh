'use client'
import { useEffect, useRef, useState } from 'react'
import { ModeloCard } from './ModeloCard'
import type { Modelo } from '@/lib/vitrine'

const LOTE = 60

/** Todos os SKUs em uma página só: mostra 60 e revela o resto sozinho conforme a rolagem (sem "próxima"). */
export function ListaModelos({ modelos }: { modelos: Modelo[] }) {
  const [n, setN] = useState(LOTE)
  const fim = useRef<HTMLDivElement>(null)
  useEffect(() => {
    const el = fim.current
    if (!el || n >= modelos.length) return
    const io = new IntersectionObserver((e) => { if (e[0].isIntersecting) setN((x) => Math.min(x + LOTE, modelos.length)) }, { rootMargin: '1200px' })
    io.observe(el)
    return () => io.disconnect()
  }, [n, modelos.length])
  return (
    <>
      <div className="grid grid-cols-2 gap-2 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-6 2xl:grid-cols-7">{modelos.slice(0, n).map((m) => <ModeloCard key={m.ref} m={m} />)}</div>
      {n < modelos.length && (
        <div ref={fim} className="mt-6 flex justify-center">
          <button type="button" onClick={() => setN((x) => Math.min(x + LOTE, modelos.length))} className="min-h-11 rounded-lg border border-black/15 bg-white px-5 text-sm font-semibold hover:border-magenta">Mostrar mais ({modelos.length - n} restantes)</button>
        </div>
      )}
    </>
  )
}
