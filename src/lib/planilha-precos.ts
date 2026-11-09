// Leitura da planilha oficial de preços de venda (aba "Catálogo de Preços de Venda").
// Usado pela tela do CRM e por scripts/importar-planilha-precos.ts. As colunas com fórmula
// (unitário, lucro, margem, markup) são ignoradas: o banco só precisa dos valores de origem.

export interface LinhaPlanilha {
  sku: string
  categoria: string
  descricao: string
  cores: string
  formato: string
  quantidade: number | null
  prazo_fabrica_dias: number | null
  prazo_cliente_dias: number | null
  peso_g: number | null
  tipo_embalagem: string
  embalagem_cm: string
  custo: number
  preco_mercado: number | null
  preco_venda: number
  estrategia: string
}

const norm = (s: unknown) => String(s ?? '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/\s+/g, ' ').trim()

const COLUNAS: Record<keyof LinhaPlanilha, (h: string) => boolean> = {
  sku: (h) => h.startsWith('codigo') || h === 'sku',
  categoria: (h) => h === 'categoria',
  descricao: (h) => h.startsWith('descricao'),
  cores: (h) => h === 'cores',
  formato: (h) => h.startsWith('formato'),
  quantidade: (h) => h === 'quantidade',
  prazo_fabrica_dias: (h) => h.startsWith('prazo') && !h.includes('cliente'),
  prazo_cliente_dias: (h) => h.startsWith('prazo cliente'),
  peso_g: (h) => h.startsWith('peso total'),
  tipo_embalagem: (h) => h === 'tipo embalagem',
  embalagem_cm: (h) => h.startsWith('embalagem ('),
  custo: (h) => h.startsWith('preco de custo total'),
  preco_mercado: (h) => h.startsWith('preco de mercado'),
  preco_venda: (h) => h.startsWith('preco de venda sugerido total'),
  estrategia: (h) => h.startsWith('estrategia'),
}

const num = (v: unknown): number | null => {
  if (v === null || v === undefined || v === '') return null
  if (typeof v === 'number') return Number.isFinite(v) ? v : null
  const s = String(v).trim()
  if (s.startsWith('=')) return null
  const n = Number(s.includes(',') ? s.replace(/\./g, '').replace(',', '.') : s)
  return Number.isFinite(n) ? n : null
}
const txt = (v: unknown) => String(v ?? '').trim()

/** Converte as linhas brutas (primeira linha com "Código" é o cabeçalho) em linhas tipadas. */
export function linhasDaPlanilha(tabela: unknown[][]): LinhaPlanilha[] {
  const iCab = tabela.findIndex((r) => r.some((c) => norm(c).startsWith('codigo')))
  if (iCab < 0) throw new Error('Não achei o cabeçalho "Código (SKU)" na planilha.')
  const cab = tabela[iCab].map(norm)
  const idx = {} as Record<keyof LinhaPlanilha, number>
  for (const k of Object.keys(COLUNAS) as (keyof LinhaPlanilha)[]) {
    idx[k] = cab.findIndex(COLUNAS[k])
    if (idx[k] < 0 && ['sku', 'custo', 'preco_venda'].includes(k)) throw new Error(`Coluna obrigatória não encontrada: ${k}.`)
  }
  const get = (r: unknown[], k: keyof LinhaPlanilha) => (idx[k] >= 0 ? r[idx[k]] : '')
  const out: LinhaPlanilha[] = []
  for (const r of tabela.slice(iCab + 1)) {
    const sku = txt(get(r, 'sku')).toUpperCase()
    const custo = num(get(r, 'custo'))
    const preco = num(get(r, 'preco_venda'))
    if (!sku || custo === null || preco === null) continue
    out.push({
      sku,
      categoria: txt(get(r, 'categoria')),
      descricao: txt(get(r, 'descricao')),
      cores: txt(get(r, 'cores')).toUpperCase(),
      formato: txt(get(r, 'formato')),
      quantidade: num(get(r, 'quantidade')),
      prazo_fabrica_dias: num(get(r, 'prazo_fabrica_dias')),
      prazo_cliente_dias: num(get(r, 'prazo_cliente_dias')),
      peso_g: num(get(r, 'peso_g')),
      tipo_embalagem: txt(get(r, 'tipo_embalagem')),
      embalagem_cm: txt(get(r, 'embalagem_cm')),
      custo,
      preco_mercado: num(get(r, 'preco_mercado')),
      preco_venda: preco,
      estrategia: txt(get(r, 'estrategia')),
    })
  }
  return out
}

/** Conferência local antes de enviar: as mesmas travas que o banco aplica (x1,5 e lucro bruto mínimo). */
export function conferirLinhas(linhas: LinhaPlanilha[], multiplicadorPiso = 1.5, lucroBrutoMinimo = 65) {
  const vistos = new Set<string>()
  const problemas: string[] = []
  let duplicados = 0, semNoventa = 0, abaixoPiso = 0, abaixoLucro = 0
  for (const l of linhas) {
    if (vistos.has(l.sku)) { duplicados++; problemas.push(`${l.sku}: SKU repetido`) }
    vistos.add(l.sku)
    if (Math.round(l.preco_venda * 100) % 100 !== 90) semNoventa++
    if (l.preco_venda < l.custo * multiplicadorPiso - 0.005) { abaixoPiso++; problemas.push(`${l.sku}: abaixo de custo x ${multiplicadorPiso}`) }
    if (l.preco_venda - l.custo < lucroBrutoMinimo - 0.005) { abaixoLucro++; problemas.push(`${l.sku}: lucro bruto abaixo de R$ ${lucroBrutoMinimo}`) }
  }
  return {
    resumo: { linhas: linhas.length, categorias: new Set(linhas.map((l) => l.categoria)).size, duplicados, sem_terminacao_90: semNoventa, abaixo_do_piso: abaixoPiso, lucro_bruto_abaixo_do_minimo: abaixoLucro },
    problemas,
  }
}
