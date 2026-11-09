// Leitura da ficha técnica pública da origem interna do catálogo e tradução para linguagem de balcão.
// Funções puras (sem Deno): testadas em Node por scripts/test-loja.ts e usadas pela Edge Function loja-fichas.
// A origem NUNCA aparece no que sai daqui: frases com a marca da origem são descartadas e o resultado é conferido de novo.

export interface FichaOrigem {
  titulo: string | null
  ref: string | null
  material: string | null
  gramatura_g: number | null
  cores: string | null
  peso_g: number | null
  arte_sangria_mm: string | null
  tamanho_final_mm: string | null
  acabamento_padrao: string | null
  tipo_impressao: string | null
  sobre: string[]
}

export interface FichaBalcao {
  titulo: string
  material: string | null
  espessura: string | null
  impressao: string | null
  tamanho_final: string | null
  arte_com_sangria: string | null
  acabamento: string | null
  observacoes: string[]
}

const ENTIDADES: Record<string, string> = { '&amp;': '&', '&lt;': '<', '&gt;': '>', '&quot;': '"', '&#39;': "'", '&nbsp;': ' ' }
const decodificar = (s: string) => s
  .replace(/&(amp|lt|gt|quot|#39|nbsp);/g, (m) => ENTIDADES[m] ?? m)
  .replace(/&#(\d+);/g, (_, n) => String.fromCharCode(Number(n)))
  .replace(/&([a-z]+)(acute|grave|circ|tilde|cedil|uml);/gi, (_, l: string, a: string) => {
    const mapa: Record<string, string> = { acute: '́', grave: '̀', circ: '̂', tilde: '̃', cedil: '̧', uml: '̈' }
    return (l + (mapa[a.toLowerCase()] ?? '')).normalize('NFC')
  })

/** Texto visível da página, uma linha por bloco. */
export function linhasVisiveis(html: string): string[] {
  const semCodigo = html.replace(/<script[\s\S]*?<\/script>|<style[\s\S]*?<\/style>|<!--[\s\S]*?-->/gi, '')
  return decodificar(semCodigo.replace(/<[^>]+>/g, '\n'))
    .split('\n').map((l) => l.replace(/\s+/g, ' ').trim()).filter(Boolean)
}

/** Termos da marca da origem, derivados do host configurado (ex.: "fulanografica.com.br" -> fulanografica, fulano gráfica, fulano). */
export function marcasDaOrigem(origemBase: string): string[] {
  let host = ''
  try { host = new URL(origemBase).hostname.replace(/^www\./, '') } catch { return [] }
  const rotulo = host.split('.')[0]
  const prefixo = rotulo.replace(/gr[aá]fica$/i, '')
  return [...new Set([rotulo, `${prefixo} gráfica`, `${prefixo} grafica`, prefixo, host].filter((t) => t.length >= 3).map((t) => t.toLowerCase()))]
}

const sem = (s: string) => s.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '')
export function citaMarca(texto: string, marcas: string[]): boolean {
  const t = sem(texto)
  return marcas.some((m) => new RegExp(`(^|[^a-z0-9])${sem(m).replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}([^a-z0-9]|$)`).test(t))
}

const ROTULOS: Record<string, keyof FichaOrigem> = {
  'ref.': 'ref',
  'papel/material': 'material',
  'gramatura': 'gramatura_g',
  'cores': 'cores',
  'peso': 'peso_g',
  'tam. da arte c/ sangria': 'arte_sangria_mm',
  'tam. final do material': 'tamanho_final_mm',
  'acabamento(s) padrão(ões)': 'acabamento_padrao',
}

const maiusculas = (s: string) => { const letras = s.replace(/[^A-Za-zÀ-ú]/g, ''); return letras.length > 0 && letras.replace(/[^A-ZÀ-Ý]/g, '').length / letras.length > 0.6 }

const LIXO_SOBRE = /clique aqui|mandamentos|leia o pdf|gabarito|evite erros|login|cadastro/i

/** Extrai título, ficha técnica e o texto "Sobre o produto" (só frases úteis e sem a marca da origem). */
export function lerFicha(html: string, marcas: string[]): FichaOrigem {
  const l = linhasVisiveis(html)
  const f: FichaOrigem = { titulo: null, ref: null, material: null, gramatura_g: null, cores: null, peso_g: null, arte_sangria_mm: null, tamanho_final_mm: null, acabamento_padrao: null, tipo_impressao: null, sobre: [] }
  const iSobre = l.findIndex((x) => /^sobre o produto$/i.test(x))
  const iTec = l.findIndex((x) => /^descri[cç][aã]o t[eé]cnica$/i.test(x))
  if (iSobre > 0) f.titulo = limparTitulo(l[iSobre - 1])
  if (iTec >= 0) {
    for (let i = iTec + 1; i < l.length - 1 && !/^comprar$/i.test(l[i]); i++) {
      const k = ROTULOS[l[i].replace(/:$/, '').toLowerCase()]
      if (!k) continue
      const v = l[i + 1]
      if (k === 'gramatura_g' || k === 'peso_g') (f[k] as number | null) = Number((v.match(/\d+(?:[.,]\d+)?/) ?? [''])[0].replace(',', '.')) || null
      else (f[k] as string | null) = v
      i++
    }
  }
  if (iSobre >= 0) {
    const fim = iTec > iSobre ? iTec : Math.min(l.length, iSobre + 40)
    const bloco = l.slice(iSobre + 1, fim)
    for (let i = 0; i < bloco.length; i++) {
      const x = bloco[i]
      if (/^tipo de impress[aã]o:?$/i.test(x) && bloco[i + 1]) { f.tipo_impressao = bloco[i + 1]; i++; continue }
      if (/:$/.test(x)) continue // rótulos de seção
      if (x.length < 25 || LIXO_SOBRE.test(x) || maiusculas(x)) continue
      for (const frase of x.split(/(?<=[.!?])\s+/)) {
        if (frase.length >= 25 && /[.!?]$/.test(frase.trim()) && !citaMarca(frase, marcas) && !LIXO_SOBRE.test(frase)) f.sobre.push(frase.trim())
      }
    }
  }
  if (f.titulo && citaMarca(f.titulo, marcas)) f.titulo = null
  return f
}

/** "CARTÕES ... VERNIZ UV  VERNIZ UV TOTAL - 4X4 - 1000unid - CFV02" -> "Cartões ... Verniz Uv Total" */
export function limparTitulo(h1: string): string | null {
  let t = h1.split(' - ')[0].replace(/\s+/g, ' ').trim()
  if (!t) return null
  // repete o trecho anterior ("VERNIZ UV VERNIZ UV TOTAL"): remove a primeira ocorrência duplicada
  t = t.replace(/\b((?:\S+ ){1,3}\S+) \1\b/gi, '$1')
  // "ADESIVOS ADESIVO TERMOCOLANTE" -> "ADESIVO TERMOCOLANTE" (categoria repetida no começo)
  const p = t.split(' ')
  if (p.length > 2 && sem(p[1]).slice(0, 5) === sem(p[0]).slice(0, 5)) t = p.slice(1).join(' ')
  return capitalizar(t)
}

const MINUSCULAS = new Set(['e', 'de', 'da', 'do', 'das', 'dos', 'em', 'com', 'para', 'a', 'o', 'c/'])
export function capitalizar(s: string): string {
  return s.toLowerCase().split(' ').map((p, i) => {
    if (i > 0 && MINUSCULAS.has(p)) return p
    if (/^\d+g$/.test(p) || /^\d+x\d+(mm)?$/.test(p)) return p
    if (/^(uv|bopp|pvc|pet|ps|mdf|a\d)$/.test(p)) return p.toUpperCase()
    return p.charAt(0).toUpperCase() + p.slice(1)
  }).join(' ')
}

// Glossário de balcão: termo técnico -> texto que o cliente entende (ordem importa: o mais específico primeiro)
const GLOSSARIO: [RegExp, string][] = [
  [/lamina[cç][aã]o fosca.*verniz.*localizad/i, 'Película com Toque Aveludado e Brilho Especial nos Detalhes'],
  [/verniz.*localizad/i, 'Brilho Especial nos Detalhes'],
  [/verniz (uv )?total brilho frente e verso|verniz uv total frente e verso/i, 'Verniz Brilhante na Frente e no Verso'],
  [/verniz (uv )?total brilho frente|verniz uv total frente/i, 'Verniz Brilhante na Frente'],
  [/verniz (uv )?total/i, 'Verniz Brilhante em Toda a Peça'],
  [/lamina[cç][aã]o fosca|bopp fosco/i, 'Película Fosca com Toque Aveludado'],
  [/lamina[cç][aã]o brilho|bopp brilho/i, 'Película Protetora com Brilho Total'],
  [/4 cantos arredondados|cantos arredondados/i, 'Bordas Arredondadas Elegantes'],
  [/faca especial|corte especial/i, 'Corte com Formato Personalizado'],
  [/refile|corte reto/i, 'Corte Reto Tradicional'],
  [/hot ?stamping/i, 'Detalhe Metalizado (Hot Stamping)'],
  [/sem acabamento|sem verniz/i, 'Sem Acabamento Extra'],
]

const MATERIAIS: [RegExp, string][] = [
  [/couch[eê] fosco/i, 'Papel Couchê Fosco (toque suave, sem reflexo)'],
  [/couch[eê]( brilho)?/i, 'Papel Couchê Brilho (cores vivas)'],
  [/offset|sulfite/i, 'Papel Offset (fosco, aceita escrita)'],
  [/reciclad|kraft/i, 'Papel Reciclado / Kraft'],
  [/supremo|triplex|duplex/i, 'Cartão Firme (tipo embalagem)'],
  [/adesivo vinil|vinil/i, 'Adesivo de Vinil (resistente à água)'],
  [/bopp/i, 'Adesivo Plástico BOPP (resistente à água)'],
  [/adesivo/i, 'Papel Adesivo'],
  [/lona/i, 'Lona'],
  [/pvc/i, 'PVC Rígido'],
  [/acr[ií]lico/i, 'Acrílico'],
  [/tecido|oxford|helanca/i, 'Tecido'],
]

const CORES: Record<string, string> = {
  '4X0': 'Colorido Apenas na Frente', '4X4': 'Colorido Frente e Verso', '1X0': 'Preto e Branco Apenas na Frente',
  '1X1': 'Preto e Branco Frente e Verso', '4X1': 'Colorido na Frente e Preto e Branco no Verso', '2X0': 'Duas Cores Apenas na Frente',
  '0X0': 'Sem Impressão / Acabamento Bruto / Gravação Laser',
}

export const traduzirAcabamento = (s: string | null) => (s ? (GLOSSARIO.find(([r]) => r.test(s))?.[1] ?? capitalizar(s)) : null)
export const traduzirMaterial = (s: string | null) => (s ? (MATERIAIS.find(([r]) => r.test(s))?.[1] ?? capitalizar(s)) : null)
export const traduzirCores = (s: string | null) => (s ? (CORES[s.toUpperCase().replace(/\s/g, '')] ?? s) : null)

export function espessura(g: number | null, material: string | null): string | null {
  // só faz sentido para papel e cartão (em brinde, adesivo, placa e tecido a "gramatura" não é espessura de papel)
  if (!g || !material || !/couch|offset|sulfite|papel|cart[aã]o|supremo|triplex|duplex|kraft|reciclad|color plus|verg[eê]/i.test(material)) return null
  const nome = g < 120 ? 'Papel Fino' : g < 200 ? 'Papel Médio' : g < 280 ? 'Papel Firme' : 'Papel Extra Firme'
  return `${nome} (${g}g)`
}

const mmParaCm = (s: string | null) => {
  if (!s) return null
  const m = s.match(/(\d+(?:[.,]\d+)?)\s*x\s*(\d+(?:[.,]\d+)?)/i)
  if (!m) return s
  const cm = (v: string) => String(Number(v.replace(',', '.')) / 10).replace('.', ',')
  return `${m[1]} x ${m[2]} mm (${cm(m[1])} x ${cm(m[2])} cm)`
}

/** Ficha pronta para o cliente: sem jargão, sem SKU, sem a origem. */
export function fichaBalcao(f: FichaOrigem, marcas: string[]): FichaBalcao {
  let titulo = f.titulo ?? ''
  for (const [r, v] of GLOSSARIO) if (r.test(titulo)) { titulo = titulo.replace(r, v); break }
  const out: FichaBalcao = {
    titulo: titulo.replace(/\s+/g, ' ').trim(),
    material: traduzirMaterial(f.material),
    espessura: espessura(f.gramatura_g, f.material),
    impressao: traduzirCores(f.cores),
    tamanho_final: mmParaCm(f.tamanho_final_mm),
    arte_com_sangria: mmParaCm(f.arte_sangria_mm),
    acabamento: traduzirAcabamento(f.acabamento_padrao),
    observacoes: f.sobre.slice(0, 4),
  }
  // conferência final: nada com a marca da origem sai daqui
  if (citaMarca(JSON.stringify(out), marcas)) {
    out.observacoes = out.observacoes.filter((o) => !citaMarca(o, marcas))
    if (citaMarca(out.titulo, marcas)) out.titulo = ''
  }
  return out
}
