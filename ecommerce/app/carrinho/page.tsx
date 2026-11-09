import type { Metadata } from 'next'
import { CarrinhoCliente } from './CarrinhoCliente'

export const metadata: Metadata = { title: 'Carrinho', robots: { index: false } }

export default function Carrinho() {
  return <CarrinhoCliente />
}
