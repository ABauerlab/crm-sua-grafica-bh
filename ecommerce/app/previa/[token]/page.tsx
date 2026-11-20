import type { Metadata } from 'next'
import { PreviaCliente } from '@/components/previa/PreviaCliente'

// Página do cliente: nunca indexada, sem referrer (o token está na URL)
export const metadata: Metadata = {
  title: 'Prévia da sua arte',
  robots: { index: false, follow: false },
  referrer: 'no-referrer',
}
export const dynamic = 'force-dynamic'

export default async function PaginaPrevia({ params }: { params: Promise<{ token: string }> }) {
  const { token } = await params
  return <PreviaCliente token={token} />
}
