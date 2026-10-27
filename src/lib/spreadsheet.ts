import { parseCsv } from './csv.ts'
import { parseMoney } from './money.ts'

const cell = (v: unknown): string => {
  if (v === null || v === undefined) return ''
  if (v instanceof Date) return v.toISOString().slice(0, 10)
  return String(v).trim()
}

/** Lê CSV, XLSX ou XLS e devolve as linhas como texto. A biblioteca de Excel só carrega quando necessário. */
export async function readTable(file: File): Promise<string[][]> {
  const name = file.name.toLowerCase()
  if (name.endsWith('.csv') || file.type === 'text/csv') return parseCsv(await file.text())
  if (name.endsWith('.xlsx') || name.endsWith('.xls') || name.endsWith('.html') || name.endsWith('.htm')) {
    const XLSX = await import('xlsx')
    const buf = await file.arrayBuffer()
    // Muitos sistemas "exportam para Excel" gerando uma tabela HTML com extensão .xls (é o caso da tabela da ZAP Gráfica).
    // Esse texto vem em ISO-8859-1; lido como UTF-8 os acentos viram "�".
    const html = looksLikeHtml(buf) ? decodeText(buf) : null
    const wb = html !== null ? XLSX.read(html, { type: 'string', cellDates: true }) : XLSX.read(buf, { type: 'array', cellDates: true })
    const sheet = wb.Sheets[wb.SheetNames[0]]
    if (!sheet) throw new Error('A planilha está vazia.')
    const rows = XLSX.utils.sheet_to_json<unknown[]>(sheet, { header: 1, raw: true, defval: '', blankrows: false })
    return rows.map((r) => r.map(cell)).filter((r) => r.some((c) => c !== ''))
  }
  if (name.endsWith('.pdf')) {
    throw new Error('PDF não dá para ler com segurança. Abra o PDF no Excel ou no Google Planilhas, salve como .xlsx e envie de novo (ou me mande o PDF para eu converter).')
  }
  throw new Error('Formato não suportado. Use .xlsx, .xls ou .csv.')
}

function looksLikeHtml(buf: ArrayBuffer): boolean {
  const head = new TextDecoder('latin1').decode(buf.slice(0, 600)).toLowerCase()
  return head.includes('<html') || head.includes('<table') || head.includes('<!doctype html') || head.includes('<meta')
}

/** UTF-8 quando for válido; senão Windows-1252 (padrão de arquivos exportados por sistemas antigos). */
export function decodeText(buf: ArrayBuffer): string {
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(buf)
  } catch {
    return new TextDecoder('windows-1252').decode(buf)
  }
}

export const normalize = (s: string) => s.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').trim()

/** Primeira linha com pelo menos 3 células preenchidas: costuma ser o cabeçalho (planilhas de fornecedor têm títulos acima). */
export function guessHeaderRow(rows: string[][]): number {
  const i = rows.findIndex((r) => r.filter((c) => c !== '').length >= 3)
  return i < 0 ? 0 : i
}

export type Field = 'code' | 'description' | 'category' | 'cost' | 'price'

const HINTS: Record<Field, string[]> = {
  code: ['codigo', 'cod', 'code', 'sku', 'ref'],
  description: ['descricao', 'produto', 'nome', 'item', 'description'],
  category: ['categoria', 'grupo', 'familia', 'category'],
  cost: ['custo', 'cost', 'preco de custo', 'preco fornecedor', 'valor un', 'valor'],
  // só preço de VENDA: numa tabela de fornecedor o "Preço" simples é o nosso custo
  price: ['preco de venda', 'preco venda', 'venda', 'sugerido', 'price'],
}

/** Colunas que diferenciam produtos de mesma descrição (ex.: 4x0, quantidade, tamanho) e entram no nome do produto. */
const EXTRA_HINTS = ['cores', 'qtde', 'quantidade', 'tam', 'tamanho', 'medida']

/** Sugere qual coluna é cada campo pelo nome do cabeçalho; -1 quando não achar. */
export function guessMapping(header: string[]): Record<Field, number> {
  const h = header.map(normalize)
  const used = new Set<number>()
  const out = {} as Record<Field, number>
  for (const f of ['code', 'description', 'category', 'price', 'cost'] as Field[]) {
    let idx = -1
    for (const hint of HINTS[f]) {
      idx = h.findIndex((x, i) => !used.has(i) && x.includes(hint))
      if (idx >= 0) break
    }
    out[f] = idx
    if (idx >= 0) used.add(idx)
  }
  // Sem coluna de custo explícita: o primeiro "preço" é o valor cobrado pelo fornecedor, ou seja, o custo
  if (out.cost < 0) {
    const i = h.findIndex((x, n) => !used.has(n) && (x.includes('preco') || x.includes('valor')))
    if (i >= 0) out.cost = i
  }
  return out
}

/** Colunas extras sugeridas para compor a descrição. */
export function guessExtras(header: string[], map: Record<Field, number>): number[] {
  const taken = new Set(Object.values(map))
  return header.flatMap((h, i) => (!taken.has(i) && EXTRA_HINTS.some((k) => normalize(h).startsWith(k)) ? [i] : []))
}

export interface ImportItem {
  code: string
  description: string
  category: string | null
  cost: number
  suggested_price: number
  active: boolean
}

/** Converte as linhas da planilha em produtos. Ignora títulos, linhas de seção e cabeçalhos repetidos (a tabela da ZAP repete o cabeçalho a cada categoria). */
export function buildProducts(
  rows: string[][],
  headerRow: number,
  map: Record<Field, number>,
  extras: number[],
  markup: number,
): { items: ImportItem[]; skipped: number } {
  const header = rows[headerRow] ?? []
  const codeLabel = map.code >= 0 ? normalize(header[map.code] ?? '') : ''
  const items: ImportItem[] = []
  let skipped = 0
  for (const r of rows.slice(headerRow + 1)) {
    const code = map.code >= 0 ? (r[map.code] ?? '').trim() : ''
    const base = map.description >= 0 ? (r[map.description] ?? '').trim() : ''
    if (!code || !base || normalize(code) === codeLabel) {
      skipped++
      continue
    }
    const parts = extras.flatMap((i) => {
      const v = (r[i] ?? '').trim()
      if (!v) return []
      return /^(qtde|quantidade)/.test(normalize(header[i] ?? '')) ? [`${v} un`] : [v]
    })
    const cost = map.cost >= 0 ? parseMoney(r[map.cost] ?? '') : 0
    const given = map.price >= 0 ? parseMoney(r[map.price] ?? '') : 0
    items.push({
      code,
      description: [base, ...parts].join(' · '),
      category: map.category >= 0 ? (r[map.category] ?? '').trim() || null : null,
      cost,
      suggested_price: given > 0 ? given : markup > 0 ? Math.round(Math.round(cost * 100) * markup) / 100 : 0,
      active: true,
    })
  }
  return { items, skipped }
}
