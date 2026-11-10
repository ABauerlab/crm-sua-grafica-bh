import { NextResponse } from 'next/server'
import { erro, limitar, rpc } from '@/lib/api-servidor'
import { lerConsulta } from '@/lib/filtros-api'

// GET /api/v1/facetas?categoria=cartoes-de-visita&q=&acab=soft-touch,uv&gram=encorpado
// -> { total, facetas: { sub|acab|tipo|material|gram|formato|prazo|preco: [{ valor, rotulo, n }] } } (n = modelos)
export async function GET(req: Request) {
  if (!limitar(req, 'facetas', 60)) return erro(429, 'Muitas consultas seguidas. Aguarde um minuto.')
  const c = lerConsulta(new URL(req.url))
  const r = await rpc<unknown>('loja_facetas', { p_categorias: c.categorias, p_termo: c.termo, p_filtros: c.filtros })
  if (!r.ok) return erro(r.status, 'Filtros indisponíveis no momento.')
  return NextResponse.json(r.data, { headers: { 'Cache-Control': 'public, s-maxage=300, stale-while-revalidate=600' } })
}
