import { NextResponse } from 'next/server'
import { erro, limitar, rpc } from '@/lib/api-servidor'

// GET /api/v1/products/search?q=cartao%20de%20visita&limite=12&categoria=cartoes-de-visita
export async function GET(req: Request) {
  if (!limitar(req, 'busca', 60)) return erro(429, 'Muitas buscas seguidas. Aguarde um minuto.')
  const u = new URL(req.url)
  const q = (u.searchParams.get('q') ?? '').slice(0, 80)
  const limite = Math.min(Math.max(Number(u.searchParams.get('limite') ?? 12) || 12, 1), 48)
  const categoria = u.searchParams.get('categoria')?.replace(/[^a-z0-9-]/g, '').slice(0, 80) || null
  const r = await rpc<unknown>('loja_buscar', { p_termo: q || null, p_limite: limite, p_categoria: categoria })
  if (!r.ok) return erro(r.status, 'Busca indisponível no momento.')
  return NextResponse.json(r.data, { headers: { 'Cache-Control': 'public, s-maxage=300, stale-while-revalidate=600' } })
}
