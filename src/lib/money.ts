const brl = new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' })
const num = new Intl.NumberFormat('pt-BR')
const compact = new Intl.NumberFormat('pt-BR', { notation: 'compact', maximumFractionDigits: 1 })

export const formatBRL = (v: number | null | undefined) => brl.format(Number(v ?? 0))
export const formatNumber = (v: number) => num.format(v)
/** R$ 12,3 mil, para eixos de gráfico. */
export const formatBRLCompact = (v: number) => `R$ ${compact.format(v)}`
export const formatPct = (v: number, digits = 0) => `${v.toLocaleString('pt-BR', { maximumFractionDigits: digits, minimumFractionDigits: digits })}%`

/** Converte texto digitado (1.234,56 ou 1234.56) em número. */
export function parseMoney(input: string): number {
  const s = input.trim().replace(/[^\d,.-]/g, '')
  if (!s) return 0
  const normalized = s.includes(',') ? s.replace(/\./g, '').replace(',', '.') : s
  const n = Number(normalized)
  return Number.isFinite(n) ? n : 0
}
