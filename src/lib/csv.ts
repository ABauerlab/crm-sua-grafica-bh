/** Gera e baixa um CSV compatível com Excel (UTF-8 com BOM e separador ponto e vírgula). */
export function toCsv(head: string[], rows: (string | number | null | undefined)[][]): string {
  const esc = (v: string | number | null | undefined) => {
    const s = String(v ?? '')
    return /[";\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s
  }
  return [head, ...rows].map((r) => r.map(esc).join(';')).join('\r\n')
}

export function downloadCsv(filename: string, head: string[], rows: (string | number | null | undefined)[][]) {
  const blob = new Blob(['﻿' + toCsv(head, rows)], { type: 'text/csv;charset=utf-8' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  a.click()
  URL.revokeObjectURL(url)
}

/** Lê um CSV simples (separador ; ou ,) respeitando aspas. Retorna linhas de colunas. */
export function parseCsv(text: string): string[][] {
  const src = text.replace(/^﻿/, '')
  const sep = (src.split('\n')[0].match(/;/g)?.length ?? 0) >= (src.split('\n')[0].match(/,/g)?.length ?? 0) ? ';' : ','
  const rows: string[][] = []
  let row: string[] = []
  let cur = ''
  let q = false
  for (let i = 0; i < src.length; i++) {
    const ch = src[i]
    if (q) {
      if (ch === '"' && src[i + 1] === '"') {
        cur += '"'
        i++
      } else if (ch === '"') q = false
      else cur += ch
    } else if (ch === '"') q = true
    else if (ch === sep) {
      row.push(cur)
      cur = ''
    } else if (ch === '\n' || ch === '\r') {
      if (ch === '\r' && src[i + 1] === '\n') i++
      row.push(cur)
      cur = ''
      if (row.some((c) => c.trim() !== '')) rows.push(row)
      row = []
    } else cur += ch
  }
  row.push(cur)
  if (row.some((c) => c.trim() !== '')) rows.push(row)
  return rows
}
