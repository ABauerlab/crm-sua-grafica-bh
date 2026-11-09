import type { Metadata } from 'next'
import { CheckoutCliente } from './CheckoutCliente'

export const metadata: Metadata = { title: 'Finalizar pedido', robots: { index: false } }

export default function Checkout() {
  return <CheckoutCliente />
}
