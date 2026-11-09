// Blog público (Fase 8): leitura pelas funções loja_blog_* com a chave publicável. Só posts publicados.
import { rpc } from './vitrine'

export interface CategoriaPost { slug: string; nome: string }
export interface PostResumo { slug: string; titulo: string; resumo: string; categorias: CategoriaPost[]; fonte_nome: string; publicado_em: string }
export interface Post extends PostResumo {
  corpo: string; fonte_url: string; atualizado_em: string
  relacionados: { slug: string; titulo: string; resumo: string; publicado_em: string }[]
}

export const POR_PAGINA = 12

export async function listaBlog(pagina = 1) {
  const r = await rpc<{ total: number; posts: PostResumo[] }>('loja_blog_lista', { p_pagina: pagina, p_por_pagina: POR_PAGINA }, 1800)
  return { total: r?.total ?? 0, posts: r?.posts ?? [] }
}

export async function postBlog(slug: string) {
  return rpc<Post | null>('loja_blog_post', { p_slug: slug }, 1800)
}

export async function slugsBlog() {
  return (await rpc<{ s: string; u: string }[]>('loja_blog_slugs', {}, 3600)) ?? []
}

export function dataBR(iso: string) {
  return new Date(iso).toLocaleDateString('pt-BR', { day: '2-digit', month: 'long', year: 'numeric', timeZone: 'America/Sao_Paulo' })
}

// Markdown simples do post -> blocos. Sem HTML cru: o React escapa tudo; links só internos (/categoria/...).
export type Trecho = { t: 'texto'; v: string } | { t: 'negrito'; v: string } | { t: 'link'; v: string; href: string }
export type Bloco = { t: 'p' | 'h2'; trechos: Trecho[] } | { t: 'lista'; itens: Trecho[][] }

export function trechos(linha: string): Trecho[] {
  const out: Trecho[] = []
  const re = /\*\*([^*]+)\*\*|\[([^\]]+)\]\((\/categoria\/[a-z0-9-]+)\)/g
  let i = 0
  for (const m of linha.matchAll(re)) {
    if (m.index! > i) out.push({ t: 'texto', v: linha.slice(i, m.index) })
    out.push(m[1] ? { t: 'negrito', v: m[1] } : { t: 'link', v: m[2], href: m[3] })
    i = m.index! + m[0].length
  }
  if (i < linha.length) out.push({ t: 'texto', v: linha.slice(i) })
  return out
}

export function blocos(md: string): Bloco[] {
  return md.split(/\n{2,}/).map((b) => b.trim()).filter(Boolean).map((b): Bloco => {
    if (b.startsWith('## ')) return { t: 'h2', trechos: trechos(b.slice(3).trim()) }
    const linhas = b.split('\n')
    if (linhas.every((l) => /^\s*[-*] /.test(l))) return { t: 'lista', itens: linhas.map((l) => trechos(l.replace(/^\s*[-*] /, ''))) }
    return { t: 'p', trechos: trechos(linhas.join(' ')) }
  })
}
