import { BadgeCheck, Building2, Lock, ShieldCheck, Star } from 'lucide-react'
import { SITE } from '@/lib/site'

/** Selos do rodapé, carrinho e checkout. Só afirma o que é verdade (HTTPS, Mercado Pago, CNPJ, avaliações públicas). */
export function SelosSeguranca({ escuro = true }: { escuro?: boolean }) {
  const cor = escuro ? 'border-white/15 text-white/85' : 'border-black/10 text-tinta/80'
  const selos = [
    { icone: Lock, texto: 'Site seguro (HTTPS)' },
    { icone: ShieldCheck, texto: 'Pagamento pelo Mercado Pago' },
    { icone: BadgeCheck, texto: 'Compra protegida' },
    { icone: Building2, texto: `CNPJ ${SITE.cnpj}` },
  ]
  return (
    <ul className="flex flex-wrap gap-2 text-xs" aria-label="Segurança da compra">
      {selos.map(({ icone: I, texto }) => (
        <li key={texto} className={`inline-flex items-center gap-1.5 rounded-full border px-3 py-1.5 ${cor}`}><I className="h-3.5 w-3.5" aria-hidden />{texto}</li>
      ))}
      <li>
        <a href={SITE.avaliacaoGoogle} target="_blank" rel="noopener" className={`inline-flex items-center gap-1.5 rounded-full border px-3 py-1.5 hover:border-amarelo ${cor}`}>
          <Star className="h-3.5 w-3.5 fill-amarelo text-amarelo" aria-hidden />Avaliações no Google
        </a>
      </li>
    </ul>
  )
}
