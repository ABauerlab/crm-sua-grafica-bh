// Leitura da tabela de preços do fornecedor em PDF (colunas: Código, Categoria, Descrição do Serviço, Cores, Peso, Qtde, Tam, Prazo*, Preço).
// O PDF vira linhas de texto pelas posições (x, y) de cada trecho; as colunas vêm do cabeçalho de cada página.
// Nada é inventado: linha que parece de dados mas não fecha vai adiante com o preço vazio e é REJEITADA com motivo no servidor.

export interface PdfItem { str: string; x: number; y: number; w: number }
export interface PdfParse {
  rows: string[][]
  /** Linhas do arquivo que terminam em preço (conferência independente do leitor de colunas). */
  candidatas: number
  paginas: number
  titulos: number
  emitidoEm: string | null
  avisos: string[]
}

export const PDF_HEADER = ['Código', 'Categoria', 'Descrição do Serviço', 'Cores', 'Peso', 'Qtde', 'Tam', 'Prazo*', 'Preço']
const KEYS = ['codigo', 'categoria', 'descricao', 'cores', 'peso', 'qtde', 'tam', 'prazo', 'preco'] as const
const PRICE = /^(?:R\$\s*)?\d{1,3}(?:\.\d{3})*,\d{2}$/
const norm = (s: string) => s.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^a-z0-9]/g, '')
const TOL_LINE = 2.5

interface Col { key: (typeof KEYS)[number]; start: number; end: number }

/** Junta os trechos em linhas (mesmo y), da de cima para a de baixo, cada linha da esquerda para a direita. */
function toLines(items: PdfItem[]): PdfItem[][] {
  const sorted = items.filter((i) => i.str.trim() !== '').sort((a, b) => b.y - a.y || a.x - b.x)
  const lines: PdfItem[][] = []
  for (const it of sorted) {
    const last = lines[lines.length - 1]
    if (last && Math.abs(last[0].y - it.y) <= TOL_LINE) last.push(it)
    else lines.push([it])
  }
  return lines.map((l) => l.sort((a, b) => a.x - b.x))
}

/** Cabeçalho: linha com pelo menos 6 dos 9 nomes de coluna. Devolve as colunas com o início e o fim de cada uma. */
function findHeader(line: PdfItem[]): Col[] | null {
  const found: Col[] = []
  for (const it of line) {
    const n = norm(it.str)
    const key = KEYS.find((k) => n === k || (['prazo', 'preco', 'descricao'].includes(k) && n.startsWith(k)))
    if (key && !found.some((f) => f.key === key)) found.push({ key, start: it.x, end: it.x + it.w })
  }
  if (found.length < 6 || !found.some((f) => f.key === 'codigo') || !found.some((f) => f.key === 'preco')) return null
  return found.sort((a, b) => a.start - b.start)
}

/** Coluna de um trecho: número alinhado ao início ou ao fim do cabeçalho (vale o alinhamento mais exato); texto pelo início. */
function columnOf(cols: Col[], it: PdfItem): Col {
  if (/^[\d.,R$\s]+$/.test(it.str)) {
    let melhor: Col | null = null
    let erro = 3.01
    for (const c of cols) {
      const e = Math.min(Math.abs(it.x - c.start), Math.abs(it.x + it.w - c.end))
      if (e < erro) { erro = e; melhor = c }
    }
    if (melhor) return melhor
  }
  let pick = cols[0]
  for (const c of cols) if (it.x >= c.start - 4) pick = c
  return pick
}

export function parsePdfPages(pages: PdfItem[][]): PdfParse {
  const rows: string[][] = [PDF_HEADER]
  const avisos: string[] = []
  let candidatas = 0
  let titulos = 0
  let emitidoEm: string | null = null
  let cols: Col[] | null = null

  pages.forEach((items, p) => {
    let anterior: string[] | null = null
    for (const line of toLines(items)) {
      const text = line.map((i) => i.str).join(' ')
      if (!emitidoEm && /emitid|emiss|atualizad|data/i.test(text)) {
        const d = /(\d{2})\/(\d{2})\/(\d{4})/.exec(text)
        if (d) emitidoEm = `${d[3]}-${d[2]}-${d[1]}`
      }
      const h = findHeader(line)
      if (h) { cols = h; anterior = null; continue }
      if (!cols) continue
      const last = line[line.length - 1]
      if (line.length >= 4 && PRICE.test(last.str.trim())) candidatas++
      const cells: Record<string, string[]> = {}
      for (const it of line) (cells[columnOf(cols, it).key] ??= []).push(it.str.trim())
      const cell = (k: string) => (cells[k] ?? []).join(' ').trim()
      const preco = cell('preco')
      if (PRICE.test(preco)) {
        const row = KEYS.map((k) => cell(k))
        rows.push(row)
        anterior = row
        continue
      }
      const usados = Object.keys(cells)
      if (usados.length >= 3 && /\d/.test(text)) {
        // parece uma linha de dados sem preço legível: vai com o preço vazio para ser rejeitada com motivo (nunca some)
        const row = KEYS.map((k) => (k === 'preco' ? '' : cell(k)))
        rows.push(row)
        anterior = row
        avisos.push(`Página ${p + 1}: linha sem preço legível ("${text.slice(0, 80)}")`)
        continue
      }
      if (usados.every((k) => k === 'descricao' || k === 'categoria') && anterior) {
        // descrição ou categoria que quebrou em duas linhas
        if (cells.descricao) anterior[2] = `${anterior[2]} ${cell('descricao')}`.trim()
        if (cells.categoria) anterior[1] = `${anterior[1]} ${cell('categoria')}`.trim()
        continue
      }
      titulos++
    }
  })
  if (!cols) avisos.push('Não encontrei o cabeçalho das colunas (Código, Categoria, Descrição do Serviço, Cores, Peso, Qtde, Tam, Prazo, Preço) no PDF.')
  return { rows, candidatas, paginas: pages.length, titulos, emitidoEm, avisos }
}

/** Lê o PDF no navegador. A biblioteca só carrega quando o arquivo é PDF. */
export async function readPdfTable(data: ArrayBuffer): Promise<PdfParse> {
  const pdfjs = await import('pdfjs-dist')
  if (typeof window !== 'undefined') {
    const worker = await import('pdfjs-dist/build/pdf.worker.min.mjs?url')
    pdfjs.GlobalWorkerOptions.workerSrc = worker.default
  }
  const doc = await pdfjs.getDocument({ data: new Uint8Array(data) }).promise
  const pages: PdfItem[][] = []
  for (let n = 1; n <= doc.numPages; n++) {
    const page = await doc.getPage(n)
    const content = await page.getTextContent()
    pages.push(
      content.items
        .filter((i): i is typeof i & { str: string; transform: number[]; width: number } => 'str' in i)
        .map((i) => ({ str: i.str, x: i.transform[4], y: i.transform[5], w: i.width })),
    )
    page.cleanup()
  }
  return parsePdfPages(pages)
}
