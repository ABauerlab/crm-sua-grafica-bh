'use client'
import { useState } from 'react'
import { Check, Tag, X } from 'lucide-react'
import type { Checkout } from '@/lib/pagar'

/** Cupom de desconto (ex.: o do panfleto de pós-venda). O servidor confere validade, uso e a trava de lucro. */
export function Cupom({ c, ocupado, onAplicar, onRemover }: { c: Checkout; ocupado: boolean; onAplicar: (codigo: string) => void; onRemover: () => void }) {
  const [aberto, setAberto] = useState(false)
  const [codigo, setCodigo] = useState('')
  if (c.cupom) {
    return (
      <div className="flex items-center justify-between gap-2 rounded-xl2 border-2 border-[#0E8A3E]/30 bg-[#0E8A3E]/5 p-3 text-sm">
        <span className="flex min-w-0 items-center gap-2"><Check className="h-4 w-4 shrink-0 text-[#0E8A3E]" aria-hidden /><span className="truncate"><b>Cupom {c.cupom.codigo}</b> aplicado ({String(c.cupom.percentual).replace('.', ',')}% de desconto)</span></span>
        <button type="button" disabled={ocupado} onClick={onRemover} aria-label="Remover cupom" className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full hover:bg-black/5"><X className="h-4 w-4" aria-hidden /></button>
      </div>
    )
  }
  return (
    <div className="rounded-xl2 bg-white p-4 shadow-sm">
      {!aberto ? (
        <button type="button" onClick={() => setAberto(true)} className="flex min-h-11 w-full items-center gap-2 text-left text-sm font-bold text-magenta"><Tag className="h-4 w-4" aria-hidden />Tem cupom de desconto?</button>
      ) : (
        <form onSubmit={(e) => { e.preventDefault(); if (codigo.trim()) onAplicar(codigo.trim()) }} className="flex gap-2">
          <label className="sr-only" htmlFor="cupom">Código do cupom</label>
          <input id="cupom" value={codigo} onChange={(e) => setCodigo(e.target.value.toUpperCase().replace(/[^A-Z0-9_-]/g, ''))} maxLength={30} autoCapitalize="characters" autoComplete="off" placeholder="Código do cupom"
            className="h-12 min-w-0 flex-1 rounded-lg border border-black/15 px-3 text-base uppercase" />
          <button type="submit" disabled={ocupado || !codigo.trim()} className="h-12 shrink-0 rounded-lg bg-tinta px-4 text-sm font-bold text-white hover:bg-magenta disabled:opacity-50">Aplicar</button>
        </form>
      )}
    </div>
  )
}
