// Utilidades do menu de departamentos: busca sem acento por categorias e subcategorias.
import type { Vertical } from './vitrine'

export const semAcento = (s: string) => s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase()

export interface ItemBusca { nome: string; href: string; contexto: string; tipo: 'categoria' | 'subcategoria' }

/** Todas as categorias e subcategorias em uma lista plana (para a busca do menu e as sugestões do cabeçalho). */
export function itensDeBusca(verticais: Vertical[]): ItemBusca[] {
  const out: ItemBusca[] = []
  for (const v of verticais) for (const c of v.categorias) {
    out.push({ nome: c.nome, href: `/categoria/${c.slug}`, contexto: v.nome, tipo: 'categoria' })
    for (const s of c.subcategorias) out.push({ nome: s.nome, href: `/categoria/${c.slug}?sub=${s.slug}`, contexto: `${c.nome}`, tipo: 'subcategoria' })
  }
  return out
}

export function buscarItens(itens: ItemBusca[], termo: string, limite = 30): ItemBusca[] {
  const t = semAcento(termo.trim())
  if (t.length < 2) return []
  const palavras = t.split(/\s+/)
  return itens.filter((i) => { const n = semAcento(i.nome + ' ' + i.contexto); return palavras.every((p) => n.includes(p)) })
    .sort((a, b) => Number(semAcento(b.nome).startsWith(t)) - Number(semAcento(a.nome).startsWith(t)) || Number(a.tipo === 'subcategoria') - Number(b.tipo === 'subcategoria'))
    .slice(0, limite)
}
