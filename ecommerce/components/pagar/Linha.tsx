import { ChevronDown } from 'lucide-react'

/** Opção secundária do checkout: uma linha recolhida (título + escolha atual) que abre só se o cliente quiser mexer.
 *  Mantém o caminho principal curto: dados, arte e pagamento. */
export function Linha({ titulo, valor, children }: { titulo: string; valor?: string; children: React.ReactNode }) {
  return (
    <details className="group rounded-xl2 bg-white shadow-sm">
      <summary className="flex min-h-14 cursor-pointer list-none items-center justify-between gap-3 px-4 py-3 text-sm">
        <span className="min-w-0"><b>{titulo}</b>{valor && <span className="block truncate text-black/60">{valor}</span>}</span>
        <span className="flex shrink-0 items-center gap-1 font-semibold text-magenta">Alterar<ChevronDown className="h-4 w-4 transition-transform group-open:rotate-180" aria-hidden /></span>
      </summary>
      <div className="px-4 pb-4 [&_h2]:hidden [&>section]:p-0 [&>section]:shadow-none">{children}</div>
    </details>
  )
}
