'use client'
import { useMemo, useState } from 'react'
import Link from 'next/link'
import { Search } from 'lucide-react'
import { buscarItens, type ItemBusca } from '@/lib/menu'

/** Campo de busca do cabeçalho com sugestões de categorias e tipos enquanto digita (antes do Enter). */
export function BuscaHeader({ itens, className = '', placeholder }: { itens: ItemBusca[]; className?: string; placeholder: string }) {
  const [q, setQ] = useState('')
  const [foco, setFoco] = useState(false)
  const sugestoes = useMemo(() => buscarItens(itens, q, 7), [itens, q])
  return (
    <form action="/busca" role="search" className={`relative ${className}`} onFocus={() => setFoco(true)} onBlur={(e) => { if (!e.currentTarget.contains(e.relatedTarget)) setFoco(false) }}>
      <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-black/40" aria-hidden />
      <input name="q" value={q} onChange={(e) => setQ(e.target.value)} placeholder={placeholder} aria-label="Buscar produto" autoComplete="off" enterKeyHint="search"
        className="h-11 w-full rounded-lg bg-white pl-9 pr-3 text-base text-tinta outline-none ring-amarelo focus:ring-2" />
      {foco && sugestoes.length > 0 && (
        <ul className="absolute inset-x-0 top-full z-50 mt-1 overflow-hidden rounded-lg bg-white text-tinta shadow-xl" aria-label="Sugestões">
          {sugestoes.map((s) => (
            <li key={s.href}><Link href={s.href} className="flex min-h-11 flex-col justify-center px-3 py-1 hover:bg-papel">
              <span className="text-sm font-semibold">{s.nome}</span><span className="text-xs text-black/55">{s.tipo === 'categoria' ? `Departamento: ${s.contexto}` : `em ${s.contexto}`}</span></Link></li>
          ))}
          <li><button className="flex min-h-11 w-full items-center px-3 text-left text-sm font-semibold text-magenta hover:bg-papel">Buscar por "{q}" em todo o site</button></li>
        </ul>
      )}
    </form>
  )
}
