import { erro, limitar, respostaBanco, rpc } from '@/lib/api-servidor'

// GET /api/v1/products/:ref/quote?arte=pronta|conferencia|criacao&cep=30160040
export async function GET(req: Request, { params }: { params: Promise<{ ref: string }> }) {
  if (!limitar(req, 'cotacao', 60)) return erro(429, 'Muitas cotações seguidas. Aguarde um minuto.')
  const { ref } = await params
  if (!/^[0-9a-f]{12}$/.test(ref)) return erro(404, 'Produto não encontrado.')
  const u = new URL(req.url)
  const r = await rpc<Record<string, unknown>>('loja_cotar', { p_ref: ref, p_arte: u.searchParams.get('arte') ?? 'pronta', p_cep: u.searchParams.get('cep') })
  if (!r.ok) return erro(r.status, 'Cotação indisponível no momento.')
  return respostaBanco(r.data, 'public, s-maxage=120, stale-while-revalidate=300')
}
