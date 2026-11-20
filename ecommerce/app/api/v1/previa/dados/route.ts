import { NextResponse } from 'next/server'
import { erro, limitar, urlFuncao } from '@/lib/api-servidor'

// POST /api/v1/previa/dados { acao: carregar|enviar_briefing|regenerar|ajustar|fechar, token, ... } -> Edge Function previa-arte
export async function POST(req: Request) {
  if (!limitar(req, 'previa-dados', 60)) return erro(429, 'Muitas tentativas seguidas. Aguarde um minuto.')
  const body = await req.json().catch(() => null)
  if (!body) return erro(400, 'Corpo da requisição inválido.')
  const r = await urlFuncao('previa-arte', body)
  return NextResponse.json(r.data, { status: r.status, headers: { 'Cache-Control': 'no-store' } })
}
