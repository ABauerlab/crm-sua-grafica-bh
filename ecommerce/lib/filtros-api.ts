// Leitura segura dos parâmetros de categoria, termo e filtros das rotas /api/v1/facetas e /api/v1/modelos.
import { lerFiltros } from './filtros'

export function lerConsulta(u: URL) {
  const categorias = (u.searchParams.get('categoria') ?? '').split(',').map((s) => s.replace(/[^a-z0-9-]/g, '').slice(0, 80)).filter(Boolean).slice(0, 20)
  const q = (u.searchParams.get('q') ?? '').trim().slice(0, 80)
  const obj: Record<string, string> = {}
  u.searchParams.forEach((v, k) => { obj[k] = v })
  const f = lerFiltros(obj)
  const filtros: Record<string, unknown> = {}
  for (const [k, v] of Object.entries(f)) if (v?.length) filtros[k] = k === 'sub' ? v[0] : v
  return { categorias: categorias.length ? categorias : null, termo: q || null, filtros }
}
