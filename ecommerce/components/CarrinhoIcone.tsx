'use client'
import Link from 'next/link'
import { ShoppingCart } from 'lucide-react'
import { useCarrinho } from '@/lib/carrinho'

export function CarrinhoIcone() {
  const { itens } = useCarrinho()
  return (
    <Link href="/carrinho" className="relative inline-flex h-11 w-11 items-center justify-center rounded-lg hover:bg-white/10" aria-label={`Carrinho com ${itens.length} itens`}>
      <ShoppingCart className="h-6 w-6" aria-hidden />
      {itens.length > 0 && <span className="absolute right-0.5 top-0.5 flex h-5 min-w-5 items-center justify-center rounded-full bg-magenta px-1 text-[11px] font-bold">{itens.length}</span>}
    </Link>
  )
}
