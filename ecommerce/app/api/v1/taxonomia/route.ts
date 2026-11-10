import { NextResponse } from 'next/server'
import { erro, limitar, rpc } from '@/lib/api-servidor'

// GET /api/v1/taxonomia -> { verticais: [{ id, nome, descricao, modelos, categorias: [{ slug, nome, produtos, modelos, a_partir_de, foto, subcategorias: [{ slug, nome, modelos }] }] }] }
export async function GET(req: Request) {
  if (!limitar(req, 'taxonomia', 60)) return erro(429, 'Muitas consultas seguidas. Aguarde um minuto.')
  const r = await rpc<unknown>('loja_arvore', {})
  if (!r.ok) return erro(r.status, 'Taxonomia indisponível no momento.')
  return NextResponse.json(r.data, { headers: { 'Cache-Control': 'public, s-maxage=900, stale-while-revalidate=3600' } })
}
