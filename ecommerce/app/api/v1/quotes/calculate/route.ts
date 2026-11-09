import { erro, limitar, respostaBanco, rpc } from '@/lib/api-servidor'

// POST /api/v1/quotes/calculate  { itens: [{ ref, quantidade }], arte?: 'pronta'|'conferencia'|'criacao', cep?: '30160040' }
export async function POST(req: Request) {
  if (!limitar(req, 'calculo', 60)) return erro(429, 'Muitos cálculos seguidos. Aguarde um minuto.')
  const body = await req.json().catch(() => null) as { itens?: unknown; arte?: string; cep?: string } | null
  if (!body || !Array.isArray(body.itens)) return erro(400, 'Informe os itens.')
  const r = await rpc<Record<string, unknown>>('loja_calcular', { p_itens: body.itens, p_arte: body.arte ?? 'pronta', p_cep: body.cep ?? null })
  if (!r.ok) return erro(r.status, 'Cálculo indisponível no momento.')
  return respostaBanco(r.data, 'no-store')
}
