'use client'
import { useRef } from 'react'
import { Menu, X } from 'lucide-react'
import { MenuDepartamentos } from './MenuDepartamentos'
import type { Vertical } from '@/lib/vitrine'

/** Botão "Departamentos" do cabeçalho: abre o menu completo numa gaveta (celular e computador). */
export function BotaoDepartamentos({ verticais }: { verticais: Vertical[] }) {
  const ref = useRef<HTMLDialogElement>(null)
  return (
    <>
      <button type="button" onClick={() => ref.current?.showModal()} aria-haspopup="dialog"
        className="flex min-h-11 items-center gap-2 rounded-lg bg-white/10 px-3 text-sm font-bold text-white hover:bg-white/20"><Menu className="h-4 w-4" aria-hidden />Departamentos</button>
      <dialog ref={ref} onClick={(e) => { if (e.target === ref.current) ref.current?.close() }} aria-label="Departamentos"
        className="m-0 h-full max-h-full w-[min(24rem,92vw)] max-w-none overflow-hidden bg-white p-0 text-tinta backdrop:bg-black/50">
        <div className="flex h-full flex-col">
          <div className="flex items-center justify-between border-b border-black/10 px-4 py-3">
            <b className="text-base">Departamentos</b>
            <button type="button" onClick={() => ref.current?.close()} aria-label="Fechar menu" className="flex h-11 w-11 items-center justify-center rounded-lg hover:bg-papel"><X className="h-5 w-5" aria-hidden /></button>
          </div>
          <div className="min-h-0 flex-1 overflow-y-auto p-3"><MenuDepartamentos verticais={verticais} aoNavegar={() => ref.current?.close()} /></div>
        </div>
      </dialog>
    </>
  )
}
