'use client'
import { Brush, FileCheck2, FileUp } from 'lucide-react'
import { brl } from '@/lib/site'
import type { Checkout, OpcaoArte } from '@/lib/pagar'

const ICONE = { pronta: FileUp, conferencia: FileCheck2, criacao: Brush } as const

/** Prioridade do checkout: arte que não está nos gabaritos não imprime. O cliente escolhe conferir ou criar, e o total se ajusta na hora. */
export function ArteUpsell({ c, ocupado, onEscolher }: { c: Checkout; ocupado: boolean; onEscolher: (a: OpcaoArte['codigo']) => void }) {
  if (c.arte.inclusa) {
    return (
      <section className="flex gap-3 rounded-xl2 border-2 border-[#0E8A3E]/30 bg-[#0E8A3E]/5 p-4 text-sm" aria-label="Arte">
        <Brush className="h-5 w-5 shrink-0 text-[#0E8A3E]" aria-hidden />
        <p><b>A criação da sua arte já está inclusa.</b> Depois do pagamento nossa equipe chama você no WhatsApp para começar.</p>
      </section>
    )
  }
  return (
    <section aria-labelledby="arte-t" className="rounded-xl2 bg-white p-5 shadow-sm">
      <h2 id="arte-t" className="text-lg font-black">Como está a sua arte?</h2>
      <p className="mb-3 text-sm text-black/65">Arquivo fora do gabarito não imprime direito (corta, fica borrado ou com cor errada). A gente cuida disso para o seu material sair perfeito.</p>
      <div role="radiogroup" aria-labelledby="arte-t" className="grid gap-2.5 md:grid-cols-3">
        {c.arte.opcoes.map((o) => {
          const Icone = ICONE[o.codigo]
          const ativo = c.arte.atual === o.codigo
          return (
            <button key={o.codigo} type="button" role="radio" aria-checked={ativo} disabled={ocupado} onClick={() => !ativo && onEscolher(o.codigo)}
              className={`relative flex min-h-[7.5rem] flex-col items-start gap-1 rounded-xl border-2 p-3.5 text-left transition-colors disabled:opacity-60 ${ativo ? 'border-magenta bg-magenta/5' : 'border-black/10 hover:border-magenta/50'}`}>
              {o.codigo === 'criacao' && <span className="absolute -top-2.5 right-3 rounded-full bg-amarelo px-2 py-0.5 text-[11px] font-black text-tinta">Mais pedida</span>}
              <span className="flex w-full items-center gap-2"><Icone className={`h-5 w-5 ${ativo ? 'text-magenta' : 'text-black/55'}`} aria-hidden /><span className="flex-1 font-bold leading-tight">{o.titulo}</span></span>
              <span className="text-xs text-black/60">{o.texto}</span>
              <span className="mt-auto pt-1 text-sm font-black">{o.valor > 0 ? `+ ${brl(o.valor)}` : o.codigo === 'criacao' && c.campanha?.ativa ? 'Grátis na Black Friday' : 'Sem custo'}</span>
            </button>
          )
        })}
      </div>
    </section>
  )
}
