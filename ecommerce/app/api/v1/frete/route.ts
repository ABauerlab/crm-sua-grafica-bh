import { NextResponse } from 'next/server'
import { erro, limitar, urlFuncao } from '@/lib/api-servidor'

// POST /api/v1/frete { cep, itens: [{ ref, quantidade }], arte }
// -> { endereco, frete_gratis, grande_bh, falta_para_frete_gratis, envio: { disponivel, motivo, opcoes: [{ servico, nome, valor, prazo_dias }] } }
export async function POST(req: Request) {
  if (!limitar(req, 'frete', 30)) return erro(429, 'Muitas consultas seguidas. Aguarde um minuto.')
  const body = await req.json().catch(() => null)
  if (!body) return erro(400, 'Corpo da requisição inválido.')
  const r = await urlFuncao('loja-frete', body)
  return NextResponse.json(r.data, { status: r.status, headers: { 'Cache-Control': 'no-store' } })
}
