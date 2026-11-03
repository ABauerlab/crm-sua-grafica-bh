// Consolidação dos resultados: matriz cenário x resultado, médias por critério, critérios de aprovação da rodada.
import { CRITERIOS, type Criterio, type ResultadoConversa } from './tipos.ts'
import { notaMedia } from './juiz.ts'

export interface Resumo {
  conversas: number
  comErro: number
  criticas: number
  mediaGeral: number | null
  porCriterio: Partial<Record<Criterio, number>>
  piorCriterio: number | null
  /** Aprovada = zero críticas, média >= 9 e nenhum critério abaixo de 8 (e nenhuma conversa com erro de execução). */
  aprovada: boolean
  motivos: string[]
}

export function resumir(rs: ResultadoConversa[]): Resumo {
  const criticas = rs.reduce((s, r) => s + todasFalhas(r).filter((f) => f.gravidade === 'critica').length, 0)
  const julgadas = rs.filter((r) => r.veredito)
  const porCriterio: Partial<Record<Criterio, number>> = {}
  for (const c of CRITERIOS) {
    const notas = julgadas.flatMap((r) => r.veredito!.notas.filter((n) => n.criterio === c).map((n) => n.nota))
    if (notas.length) porCriterio[c] = notas.reduce((a, b) => a + b, 0) / notas.length
  }
  const medias = Object.values(porCriterio) as number[]
  const mediaGeral = julgadas.length ? julgadas.reduce((s, r) => s + notaMedia(r.veredito!), 0) / julgadas.length : null
  const piorCriterio = medias.length ? Math.min(...medias) : null
  const comErro = rs.filter((r) => r.erro).length
  const motivos: string[] = []
  if (criticas > 0) motivos.push(`${criticas} falha(s) crítica(s)`)
  if (comErro > 0) motivos.push(`${comErro} conversa(s) com erro de execução`)
  if (mediaGeral === null) motivos.push('sem notas do juiz')
  else if (mediaGeral < 9) motivos.push(`média ${mediaGeral.toFixed(2)} abaixo de 9`)
  if (piorCriterio !== null && piorCriterio < 8) motivos.push(`critério com média ${piorCriterio.toFixed(2)} abaixo de 8`)
  return { conversas: rs.length, comErro, criticas, mediaGeral, porCriterio, piorCriterio, aprovada: motivos.length === 0, motivos }
}

export const todasFalhas = (r: ResultadoConversa) => [...r.falhasDeterministicas, ...(r.veredito?.falhas ?? [])]

export function matrizMarkdown(rs: ResultadoConversa[]): string {
  const linhas = ['| Cenário | Form. | Média | Críticas | Outras falhas | Erro |', '|---|---|---|---|---|---|']
  for (const r of rs) {
    const fs = todasFalhas(r)
    const crit = fs.filter((f) => f.gravidade === 'critica').map((f) => f.codigo)
    const outras = fs.filter((f) => f.gravidade !== 'critica').map((f) => f.codigo)
    linhas.push(`| ${r.cenario} | ${r.formulacao} | ${r.veredito ? notaMedia(r.veredito).toFixed(1) : '-'} | ${crit.join(', ') || '0'} | ${[...new Set(outras)].join(', ') || '-'} | ${r.erro ?? ''} |`)
  }
  return linhas.join('\n')
}
