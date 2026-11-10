// Filtros facetados na URL: ?sub=couche-250g&acab=soft-touch,uv&gram=encorpado&ordem=menor_preco
import type { Filtros } from './vitrine'

export const FACETAS: { id: keyof Filtros; titulo: string; unica?: boolean }[] = [
  { id: 'sub', titulo: 'Tipo / Subcategoria', unica: true },
  { id: 'acab', titulo: 'Acabamento / Enobrecimento' },
  { id: 'tipo', titulo: 'Tipo de papel' },
  { id: 'material', titulo: 'Material' },
  { id: 'gram', titulo: 'Gramatura' },
  { id: 'formato', titulo: 'Formato e faca' },
  { id: 'prazo', titulo: 'Prazo de produção' },
  { id: 'preco', titulo: 'Faixa de preço' },
]
export const ORDENS = [['relevancia', 'Mais relevantes'], ['menor_preco', 'Menor preço'], ['maior_preco', 'Maior preço']] as const
const CHAVES = FACETAS.map((f) => f.id as string)
const limpo = (s: string) => s.replace(/[^a-z0-9-]/g, '').slice(0, 60)

export type ParamsUrl = Record<string, string | string[] | undefined>

export function lerFiltros(p: ParamsUrl): Filtros {
  const f: Filtros = {}
  for (const k of CHAVES) {
    const v = p[k]
    const lista = (Array.isArray(v) ? v.join(',') : v ?? '').split(',').map(limpo).filter(Boolean).slice(0, 8)
    if (lista.length) f[k as keyof Filtros] = k === 'sub' ? lista.slice(0, 1) : lista
  }
  return f
}
export const lerOrdem = (p: ParamsUrl) => (ORDENS.some(([o]) => o === p.ordem) ? String(p.ordem) : 'relevancia')

/** Monta o link mantendo termo e ordem; `mudar` liga ou desliga um valor de uma faceta. */
export function hrefFiltros(base: string, f: Filtros, extra: { q?: string; ordem?: string }, mudar?: { faceta: keyof Filtros; valor: string } | { limpar: true }) {
  const novo: Filtros = mudar && 'limpar' in mudar ? {} : JSON.parse(JSON.stringify(f))
  if (mudar && 'faceta' in mudar) {
    const unica = FACETAS.find((x) => x.id === mudar.faceta)?.unica
    const atual = novo[mudar.faceta] ?? []
    novo[mudar.faceta] = atual.includes(mudar.valor) ? atual.filter((x) => x !== mudar.valor) : unica ? [mudar.valor] : [...atual, mudar.valor]
    if (!novo[mudar.faceta]!.length) delete novo[mudar.faceta]
  }
  const q = new URLSearchParams()
  if (extra.q) q.set('q', extra.q)
  if (extra.ordem && extra.ordem !== 'relevancia') q.set('ordem', extra.ordem)
  for (const [k, v] of Object.entries(novo)) if (v?.length) q.set(k, v.join(','))
  const s = q.toString()
  return s ? `${base}?${s}` : base
}
