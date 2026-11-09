import { NextResponse } from 'next/server'
import { checkout, erro, limitar } from '@/lib/api-servidor'

// POST /api/v1/checkout/create-preference
// { cliente: { whatsapp, nome, email?, documento? }, itens: [{ ref, quantidade }], opcoes: { arte, entrega: 'retirada'|'entrega', cep? } }
// -> { ok, numero, total, prazo, data_prevista, link_pagamento }
export async function POST(req: Request) {
  if (!limitar(req, 'checkout', 5)) return erro(429, 'Muitas tentativas seguidas. Aguarde um minuto.')
  const body = await req.json().catch(() => null)
  if (!body) return erro(400, 'Corpo da requisição inválido.')
  const r = await checkout(body)
  return NextResponse.json(r.data, { status: r.status, headers: { 'Cache-Control': 'no-store' } })
}
