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
    // Muitos sistemas "exportam para Excel" gerando uma tabela HTML com extensão .xls (é o caso de algumas tabelas de preço de fornecedores).
    // Esse texto vem em ISO-8859-1; lido como UTF-8 os acentos viram "�".
    const html = looksLikeHtml(buf) ? decodeText(buf) : null
    const wb = html !== null ? XLSX.read(html, { type: 'string', cellDates: true }) : XLSX.read(buf, { type: 'array', cellDates: true })
    const sheet = wb.Sheets[wb.SheetNames[0]]
    if (!sheet) throw new Error('A planilha está vazia.')
    const rows = XLSX.utils.sheet_to_json<unknown[]>(sheet, { header: 1, raw: true, defval: '', blankrows: false })
    return rows.map((r) => r.map(cell)).filter((r) => r.some((c) => c !== ''))
  }
  if (name.endsWith('.pdf') || file.type === 'application/pdf') return (await readCatalogFile(file)).rows
  throw new Error('Formato não suportado. Use .pdf, .xlsx, .xls ou .csv.')
}

export interface CatalogFile {
  rows: string[][]
  /** Só PDF: linhas que terminam em preço, contadas à parte do leitor de colunas (conferência do total). */
  candidatas: number | null
  emitidoEm: string | null
  avisos: string[]
}

/** Lê a tabela do fornecedor (PDF, Excel ou CSV). O PDF original é guardado em bucket privado pela tela antes de importar. */
export async function readCatalogFile(file: File): Promise<CatalogFile> {
  const name = file.name.toLowerCase()
  if (name.endsWith('.pdf') || file.type === 'application/pdf') {
    const { readPdfTable } = await import('./catalog-pdf.ts')
    const r = await readPdfTable(await file.arrayBuffer())
    if (r.rows.length < 2) throw new Error('Não encontrei linhas de produtos no PDF. Confira se é a tabela de preços completa.')
    return { rows: r.rows, candidatas: r.candidatas, emitidoEm: r.emitidoEm, avisos: r.avisos }
  }
  return { rows: await readTable(file), candidatas: null, emitidoEm: null, avisos: [] }
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

export type Field = 'code' | 'category' | 'description' | 'colors' | 'weight' | 'qty' | 'size' | 'lead' | 'cost'

const HINTS: Record<Field, string[]> = {
  code: ['codigo', 'cod', 'code', 'sku', 'ref'],
  category: ['categoria', 'grupo', 'familia', 'category'],
  description: ['descricao', 'produto', 'nome', 'item', 'description'],
  colors: ['cores', 'cor'],
  weight: ['peso'],
  qty: ['qtde', 'quantidade', 'qtd'],
  size: ['tam', 'tamanho', 'medida'],
  lead: ['prazo'],
  cost: ['custo', 'cost', 'preco de custo', 'preco fornecedor', 'valor un', 'valor'],
}

const ORDER: Field[] = ['code', 'category', 'description', 'colors', 'weight', 'qty', 'size', 'lead', 'cost']

/** Sugere qual coluna é cada campo pelo nome do cabeçalho; -1 quando não achar. */
export function guessMapping(header: string[]): Record<Field, number> {
  const h = header.map(normalize)
  const used = new Set<number>()
  const out = {} as Record<Field, number>
  for (const f of ORDER) {
    let idx = -1
    for (const hint of HINTS[f]) {
      idx = h.findIndex((x, i) => !used.has(i) && (hint.length <= 3 ? x === hint || x.startsWith(hint + ' ') : x.includes(hint)))
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

/** Gramatura em gramas escrita na descrição ("10g", "300 g", "150g/m²", "90 gramas"). Se a descrição cita mais de uma (capa e miolo), vale o sufixo final da tabela do fornecedor. Sem número claro, devolve null. */
export function extractGrammage(description: string): number | null {
  const tail = /(\d{1,4})\s*g\s*$/i.exec(description)
  if (tail) return Number(tail[1])
  const m = /(\d{1,4})\s*(?:g\/m|gr?(?![a-z0-9])|gramas)/i.exec(description)
  return m ? Number(m[1]) : null
}

export interface ImportItem {
  /** Número da linha no arquivo (1 = primeira linha da planilha), para achar a linha no relatório. */
  n: number
  /** Nulo quando a linha não tem código: entra como sem_sku e não é vendável. */
  sku: string | null
  categoria: string | null
  descricao: string
  cores: string | null
  peso_g: number | null
  quantidade: number | null
  tamanho_mm: string | null
  prazo: number | null
  custo: number | null
}

/** Converte as linhas da planilha em itens, uma coluna para cada campo. Ignora só títulos, linhas de seção e cabeçalhos repetidos.
 *  Linha de dados sem código NÃO é ignorada (entra como sem_sku) e linha com dado faltando NÃO some: o servidor rejeita com motivo. */
export function buildProducts(rows: string[][], headerRow: number, map: Record<Field, number>): { items: ImportItem[]; skipped: number; ignoradas: string[] } {
  const header = rows[headerRow] ?? []
  const codeLabel = map.code >= 0 ? normalize(header[map.code] ?? '') : ''
  const text = (r: string[], f: Field) => (map[f] >= 0 ? (r[map[f]] ?? '').trim() : '')
  const num = (r: string[], f: Field) => {
    const t = text(r, f)
    if (!t) return null
    const n = parseMoney(t)
    return Number.isFinite(n) ? n : null
  }
  const items: ImportItem[] = []
  const ignoradas: string[] = []
  let skipped = 0
  rows.forEach((r, idx) => {
    if (idx <= headerRow) return
    const code = text(r, 'code')
    const description = text(r, 'description')
    const hasCost = text(r, 'cost') !== ''
    const hasQty = text(r, 'qty') !== ''
    const repeatedHeader = code !== '' && normalize(code) === codeLabel
    // dado = tem preço, ou tem quantidade junto de código ou descrição. O resto é título, seção ou cabeçalho repetido.
    const isData = !repeatedHeader && (hasCost || (hasQty && (code !== '' || description !== '')))
    if (!isData) {
      skipped++
      if (r.some((c) => c !== '') && ignoradas.length < 20) ignoradas.push(`linha ${idx + 1}: ${r.filter(Boolean).slice(0, 4).join(' | ')}`)
      return
    }
    const qty = num(r, 'qty')
    const lead = num(r, 'lead')
    items.push({
      n: idx + 1,
      sku: code || null,
      categoria: text(r, 'category') || null,
      descricao: description,
      cores: text(r, 'colors') || null,
      peso_g: num(r, 'weight'),
      quantidade: qty === null ? null : Math.round(qty),
      tamanho_mm: text(r, 'size') || null,
      prazo: lead === null ? null : Math.round(lead),
      custo: hasCost ? num(r, 'cost') : null,
    })
  })
  return { items, skipped, ignoradas }
}
