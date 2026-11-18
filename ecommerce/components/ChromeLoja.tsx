'use client'
import { usePathname } from 'next/navigation'

/** Esconde o cabeçalho, o rodapé e o botão flutuante da loja nas páginas de pagamento (/pagar), que têm layout próprio e sem distrações. */
export function ChromeLoja({ children }: { children: React.ReactNode }) {
  const rota = usePathname() ?? '/'
  return rota.startsWith('/pagar/') ? null : <>{children}</>
}
