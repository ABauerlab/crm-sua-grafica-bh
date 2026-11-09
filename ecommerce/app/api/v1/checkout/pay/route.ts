import { NextResponse } from 'next/server'
import { checkout, erro, limitar } from '@/lib/api-servidor'

// POST /api/v1/checkout/pay { pedido_id, metodo: 'pix' | 'cartao', email? } -> troca a forma de pagamento do pedido
export async function POST(req: Request) {
  if (!limitar(req, 'checkout-pay', 8)) return erro(429, 'Muitas tentativas seguidas. Aguarde um minuto.')
  const b = await req.json().catch(() => null) as Record<string, unknown> | null
  if (!b) return erro(400, 'Corpo da requisição inválido.')
  const r = await checkout({ acao: 'pagar', pedido_id: b.pedido_id, metodo: b.metodo === 'cartao' ? 'cartao' : 'pix', email: b.email })
  return NextResponse.json(r.data, { status: r.status, headers: { 'Cache-Control': 'no-store' } })
}
