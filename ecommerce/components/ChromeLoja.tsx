'use client'
import { usePathname } from 'next/navigation'

/** Esconde o cabeçalho, o rodapé e o botão flutuante da loja nas páginas de pagamento (/pagar) e de prévia de
 * arte (/previa), que têm layout próprio e sem distrações (sem menu, busca nem carrinho da loja). */
export function ChromeLoja({ children }: { children: React.ReactNode }) {
  const rota = usePathname() ?? '/'
  return rota.startsWith('/pagar/') || rota.startsWith('/previa/') ? null : <>{children}</>
}
