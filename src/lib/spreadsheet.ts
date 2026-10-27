import { parseCsv } from './csv.ts'

const cell = (v: unknown): string => {
  if (v === null || v === undefined) return ''
  if (v instanceof Date) return v.toISOString().slice(0, 10)
  return String(v).trim()
}

/** Lê CSV, XLSX ou XLS e devolve as linhas como texto. A biblioteca de Excel só carrega quando necessário. */
export async function readTable(file: File): Promise<string[][]> {
  const name = file.name.toLowerCase()
  if (name.endsWith('.csv') || file.type === 'text/csv') return parseCsv(await file.text())
  if (name.endsWith('.xlsx') || name.endsWith('.xls')) {
    const XLSX = await import('xlsx')
    const wb = XLSX.read(await file.arrayBuffer(), { type: 'array', cellDates: true })
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
  cost: ['custo', 'valor un', 'preco de custo', 'cost', 'preco fornecedor', 'valor'],
  price: ['preco de venda', 'preco venda', 'venda', 'sugerido', 'preco', 'price'],
}

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
  return out
}
