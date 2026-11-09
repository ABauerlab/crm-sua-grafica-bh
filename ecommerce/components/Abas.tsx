'use client'
import { useState } from 'react'

export function Abas({ abas }: { abas: { id: string; titulo: string; conteudo: React.ReactNode }[] }) {
  const [ativa, setAtiva] = useState(abas[0]?.id)
  return (
    <div>
      <div role="tablist" className="flex gap-1 overflow-x-auto border-b border-black/10 [scrollbar-width:none]">
        {abas.map((a) => (
          <button key={a.id} role="tab" aria-selected={a.id === ativa} onClick={() => setAtiva(a.id)}
            className={`whitespace-nowrap border-b-2 px-4 py-3 text-sm font-semibold ${a.id === ativa ? 'border-magenta text-tinta' : 'border-transparent text-black/55 hover:text-tinta'}`}>{a.titulo}</button>
        ))}
      </div>
      {abas.map((a) => <div key={a.id} role="tabpanel" hidden={a.id !== ativa} className="py-5 text-sm leading-relaxed text-black/80">{a.conteudo}</div>)}
    </div>
  )
}
