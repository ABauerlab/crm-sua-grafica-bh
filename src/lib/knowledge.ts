// Regras de forma dos trechos do banco de conhecimento. Usadas pela tela (avisos ao editar) e pelo teste npm run test:conhecimento.
// Estilo de vendedor de BH no WhatsApp: curto, uma ideia por vez, sem lista, sem markdown, sem travessão, emoji de vez em quando.

export const KNOWLEDGE_LIMITS = { total: 120, resposta: 40, fatos: 80 } as const
export const KNOWLEDGE_VARIABLES = [
  'arte_basica', 'arte_frete', 'pedido_minimo', 'validade', 'horario',
  // Etapa 7C: nomes das personas e parâmetros de política vêm de Configurações, nunca ficam escritos no trecho
  'persona_vendas', 'persona_pos_pagamento', 'cupom_percentual', 'cupom_teto', 'cupom_validade_dias', 'troca_prazo',
] as const

export interface Trecho {
  slug?: string | null
  titulo: string
  categoria?: string | null
  quando_usar?: string | null
  resposta_pronta?: string | null
  fatos?: string | null
  proximo_passo?: string | null
  tags?: string[] | null
  revisar?: boolean
}

export const words = (s: string | null | undefined): number => (s ?? '').trim().split(/\s+/).filter(Boolean).length

export function trechoPalavras(t: Trecho) {
  const resposta = words(t.resposta_pronta)
  const fatos = words(t.fatos)
  return { resposta, fatos, total: resposta + fatos + words(t.quando_usar) + words(t.proximo_passo) }
}

// Palavras que nunca podem aparecer em trecho nenhum: custo, margem, piso e o fornecedor (o nome real é vigiado por npm test no repositório inteiro).
const PROIBIDAS = /\b(custo|custos|margem|margens|piso|pisos|fornecedor|fornecedores|lucro|lucros|markup)\b/i
const PROIBIDAS_TAGS = /\b(custo|margem|piso|fornecedor)\b/i
const EMOJI = /\p{Extended_Pictographic}/gu

/** Lista os problemas de um trecho (vazia = ok). */
export function trechoProblemas(t: Trecho): string[] {
  const p: string[] = []
  const n = trechoPalavras(t)
  if (n.total > KNOWLEDGE_LIMITS.total) p.push(`passa de ${KNOWLEDGE_LIMITS.total} palavras (${n.total})`)
  if (n.resposta > KNOWLEDGE_LIMITS.resposta) p.push(`resposta pronta passa de ${KNOWLEDGE_LIMITS.resposta} palavras (${n.resposta})`)
  if (n.fatos > KNOWLEDGE_LIMITS.fatos) p.push(`fatos passa de ${KNOWLEDGE_LIMITS.fatos} palavras (${n.fatos})`)
  if (!t.resposta_pronta?.trim()) p.push('sem resposta pronta')
  if (!t.proximo_passo?.trim()) p.push('sem próximo passo')
  if (!t.quando_usar?.trim()) p.push('sem quando usar')

  const campos: [string, string | null | undefined][] = [['título', t.titulo], ['quando usar', t.quando_usar], ['resposta pronta', t.resposta_pronta], ['fatos', t.fatos], ['próximo passo', t.proximo_passo]]
  for (const [nome, v] of campos) {
    if (!v) continue
    if (/[—–]/.test(v)) p.push(`${nome}: travessão`)
    if (/^\s*([-*•]|\d+[.)])\s/m.test(v) || /\n\s*\n/.test(v)) p.push(`${nome}: parece lista ou vários parágrafos`)
    if (/\*\*|__|^#{1,6}\s|`|\[[^\]]*\]\([^)]*\)/m.test(v)) p.push(`${nome}: markdown`)
    for (const w of new Set((v.match(new RegExp(PROIBIDAS.source, 'gi')) ?? []).map((x) => x.toLowerCase()))) p.push(`${nome}: palavra proibida (${w})`)
    if (/R\$\s*\d/.test(v)) p.push(`${nome}: valor em reais escrito no texto (use uma variável)`)
    if (/\b\d+\s*(dias?|semanas?)\b/i.test(v)) p.push(`${nome}: prazo escrito no texto (prazo vem da ferramenta ou de variável)`)
    if (/\b[A-Z]{2,4}\d{2,}[A-Z]?\b/.test(v)) p.push(`${nome}: parece um código de produto`)
    for (const m of v.matchAll(/\{\{(\w+)\}\}/g)) if (!(KNOWLEDGE_VARIABLES as readonly string[]).includes(m[1])) p.push(`${nome}: variável desconhecida {{${m[1]}}}`)
  }
  // Endereço de retirada só em trecho de pós-pagamento (tag pos_pagamento)
  if (!(t.tags ?? []).includes('pos_pagamento')) {
    for (const [nome, v] of campos) if (v && /Rio de Janeiro,?\s*\d|Sala\s*2217|30160/i.test(v)) p.push(`${nome}: endereço de retirada fora de trecho pos_pagamento`)
  }
  const r = t.resposta_pronta ?? ''
  if (/\[CONFIRMAR\]/i.test(r)) p.push('resposta pronta com [CONFIRMAR] (iria ao cliente)')
  if ((r.match(/\?/g) ?? []).length > 2) p.push('resposta pronta com mais de duas perguntas')
  if ((r.match(EMOJI) ?? []).length > 1) p.push('resposta pronta com emoji demais')
  for (const tag of t.tags ?? []) if (PROIBIDAS_TAGS.test(tag)) p.push(`tag proibida: ${tag}`)
  return p
}
