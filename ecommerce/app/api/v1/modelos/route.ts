import { NextResponse } from 'next/server'
import { erro, limitar, rpc } from '@/lib/api-servidor'
import { lerConsulta } from '@/lib/filtros-api'

// GET /api/v1/modelos?categoria=cartoes-de-visita&q=&acab=soft-touch&ordem=menor_preco&limite=24&pagina=1
// -> { total, itens: [{ ref, sku, sku_slug, titulo, categoria, foto, preco, parcela_2x, quantidade, impressao, formato, prazo_dias_uteis, variante, ... }] }
// Cada item é um SKU (um SKU = um produto); a página dele é /produto/<sku_slug>.
export async function GET(req: Request) {
  if (!limitar(req, 'modelos', 60)) return erro(429, 'Muitas consultas seguidas. Aguarde um minuto.')
  const u = new URL(req.url)
  const c = lerConsulta(u)
  const limite = Math.min(Math.max(Number(u.searchParams.get('limite') ?? 24) || 24, 1), 48)
  const pagina = Math.max(Number(u.searchParams.get('pagina') ?? 1) || 1, 1)
  const ordem = ['menor_preco', 'maior_preco'].includes(u.searchParams.get('ordem') ?? '') ? u.searchParams.get('ordem') : 'relevancia'
  const r = await rpc<unknown>('loja_sku_lista', { p_categorias: c.categorias, p_termo: c.termo, p_filtros: c.filtros, p_ordem: ordem, p_limite: limite, p_offset: (pagina - 1) * limite })
  if (!r.ok) return erro(r.status, 'Busca indisponível no momento.')
  return NextResponse.json(r.data, { headers: { 'Cache-Control': 'public, s-maxage=300, stale-while-revalidate=600' } })
}
