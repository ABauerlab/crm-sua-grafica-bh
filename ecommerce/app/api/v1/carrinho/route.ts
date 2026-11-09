import { NextResponse } from 'next/server'
import { erro, limitar, rpc } from '@/lib/api-servidor'

// POST /api/v1/carrinho { sessao, cliente: { whatsapp, nome, email }, itens: [{ ref, quantidade }], opcoes: { arte, entrega, cep } }
// Guarda o carrinho para o follow-up de carrinho abandonado. O valor é recalculado no banco.
export async function POST(req: Request) {
  if (!limitar(req, 'carrinho', 20)) return erro(429, 'Muitas atualizações seguidas.')
  const b = await req.json().catch(() => null) as Record<string, unknown> | null
  if (!b) return erro(400, 'Corpo da requisição inválido.')
  const r = await rpc<{ ok: boolean; erro?: string }>('loja_carrinho_salvar', { p_sessao: b.sessao, p_cliente: b.cliente ?? {}, p_itens: b.itens ?? [], p_opcoes: b.opcoes ?? {} })
  if (!r.ok) return erro(r.status, 'Não foi possível salvar o carrinho.')
  return NextResponse.json({ ok: r.data.ok }, { headers: { 'Cache-Control': 'no-store' } })
}
