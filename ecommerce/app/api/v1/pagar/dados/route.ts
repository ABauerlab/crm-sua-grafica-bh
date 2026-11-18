import { NextResponse } from 'next/server'
import { erro, limitar, urlFuncao } from '@/lib/api-servidor'

// POST /api/v1/pagar/dados { acao: carregar|status|salvar|arte|adicionar|remover, token, ... } -> Edge Function checkout-dados
export async function POST(req: Request) {
  if (!limitar(req, 'pagar-dados', 90)) return erro(429, 'Muitas tentativas seguidas. Aguarde um minuto.')
  const body = await req.json().catch(() => null)
  if (!body) return erro(400, 'Corpo da requisição inválido.')
  const r = await urlFuncao('checkout-dados', body)
  return NextResponse.json(r.data, { status: r.status, headers: { 'Cache-Control': 'no-store' } })
}
