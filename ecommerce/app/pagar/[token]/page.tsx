import type { Metadata } from 'next'
import { CheckoutCliente } from '@/components/pagar/CheckoutCliente'

// Página do cliente: nunca indexada, sem referrer (o token está na URL)
export const metadata: Metadata = {
  title: 'Pagamento seguro',
  robots: { index: false, follow: false },
  referrer: 'no-referrer',
}
export const dynamic = 'force-dynamic'

export default async function PaginaPagar({ params }: { params: Promise<{ token: string }> }) {
  const { token } = await params
  return <CheckoutCliente token={token} />
}
