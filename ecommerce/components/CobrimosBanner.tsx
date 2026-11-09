import { BadgePercent } from 'lucide-react'
import { linkWhatsApp } from '@/lib/site'

/** Política "Cobrimos qualquer orçamento": a proposta vai pelo WhatsApp e a condição sai da trava do banco (nunca abaixo do piso). */
export function CobrimosBanner({ produto }: { produto?: string }) {
  const msg = produto
    ? `Olá! Tenho um orçamento menor da concorrência para ${produto} e queria que vocês cobrissem. Vou mandar a proposta aqui.`
    : 'Olá! Tenho um orçamento menor da concorrência e queria que vocês cobrissem. Vou mandar a proposta aqui.'
  return (
    <a href={linkWhatsApp(msg)} target="_blank" rel="noopener" data-evento="Lead"
       className="flex items-center gap-3 rounded-xl2 border-2 border-dashed border-magenta/40 bg-magenta/5 p-4 text-sm transition hover:border-magenta">
      <BadgePercent className="h-8 w-8 shrink-0 text-magenta" aria-hidden />
      <span><b className="block text-base">Tem um orçamento menor da concorrência? Nós cobrimos a oferta!</b>
        <span className="text-black/65">Mande a proposta no WhatsApp com a mesma especificação (papel, cores, quantidade e acabamento) que a gente avalia na hora.</span></span>
    </a>
  )
}
