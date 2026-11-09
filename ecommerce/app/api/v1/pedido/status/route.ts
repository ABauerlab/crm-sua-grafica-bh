import { NextResponse } from 'next/server'
import { erro, limitar, rpc } from '@/lib/api-servidor'

// GET /api/v1/pedido/status?id=<pedido_id> -> { ok, numero, pago }  (a tela do Pix consulta até confirmar)
export async function GET(req: Request) {
  if (!limitar(req, 'pedido-status', 40)) return erro(429, 'Muitas consultas seguidas.')
  const id = new URL(req.url).searchParams.get('id') ?? ''
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) return erro(400, 'Pedido inválido.')
  const r = await rpc<{ ok: boolean; numero?: number; pago?: boolean }>('loja_pedido_status', { p_pedido: id })
  if (!r.ok) return erro(r.status, 'Não foi possível consultar o pedido.')
  return NextResponse.json(r.data, { headers: { 'Cache-Control': 'no-store' } })
}
