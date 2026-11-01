// Fotos de produto (Etapa 4B): lógica pura, sem rede, testada em Node (scripts/test-fotos.ts).
// A origem das imagens é INTERNA: o endereço dela vem de app_settings.fotos (banco), nunca do repositório.

export const LIMITES = {
  maiorLadoPx: 1000,
  minimoPx: 300,
  metaBytes: 150 * 1024,
  tetoBytes: 300 * 1024,
  qualidades: [80, 72, 64, 56, 48],
  porPedido: 3,
  pedidosPorMinuto: 1,
  imagensPorContatoDia: 10,
  cacheDias: 30,
  intervaloOrigemMs: 1100,
  timeoutOrigemMs: 15000,
  userAgent: 'SuaGraficaBH-CRM/1.0 (+contato.bauerlab@gmail.com)',
} as const

export interface CartaoOrigem {
  /** caminho do produto na origem (último trecho é o código do item) */
  caminho: string
  codigo: string
  imagem: string
}

/** Lê os cartões de uma página de listagem: link do item + imagem do serviço. Ignora banners, ícones e logos. */
export function lerCartoes(html: string): CartaoOrigem[] {
  const out: CartaoOrigem[] = []
  const vistos = new Set<string>()
  const re = /href="(?:https?:\/\/[^"\/]+)?(\/servico\/detalhe\/[^"?#]+)"[\s\S]{0,900}?data-src="(https:\/\/[^"]+\/servicos\/[0-9A-Fa-f-]{36}\.(?:jpe?g|png|webp))(?:\?[^"]*)?"/g
  for (const m of html.matchAll(re)) {
    const caminho = m[1].replace(/\/+$/, '')
    const imagem = m[2]
    if (vistos.has(imagem)) continue
    vistos.add(imagem)
    out.push({ caminho, codigo: caminho.split('/').pop() ?? '', imagem })
  }
  return out
}

export function normalizar(s: string): string {
  return s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim()
}

/** Slug de categoria no formato da origem: "BLOCOS, COMANDAS E TALÕES" -> "blocos-comandas-e-taloes". */
export function slugCategoria(grupo: string): string {
  return normalizar(grupo).replace(/ /g, '-')
}

/** Ordena os cartões: primeiro os que combinam com o termo do cliente; devolve também se houve combinação. */
export function escolherCartoes(cartoes: CartaoOrigem[], termo: string | null, quantidade: number): { itens: CartaoOrigem[]; exato: boolean } {
  const n = Math.max(1, Math.min(quantidade, 12))
  const tokens = normalizar(termo ?? '').split(' ').filter((t) => t.length >= 4)
  if (tokens.length) {
    const pontuados = cartoes
      .map((c) => ({ c, p: tokens.filter((t) => normalizar(c.caminho).includes(t)).length }))
      .filter((x) => x.p > 0)
      .sort((a, b) => b.p - a.p)
    if (pontuados.length) return { itens: pontuados.slice(0, n).map((x) => x.c), exato: true }
  }
  // sem combinação: espalha as escolhas pela página (variedade), em vez de pegar só as três primeiras
  const passo = Math.max(1, Math.floor(cartoes.length / n))
  const itens: CartaoOrigem[] = []
  for (let i = 0; i < cartoes.length && itens.length < n; i += passo) itens.push(cartoes[i])
  return { itens, exato: false }
}

export interface Processada {
  bytes: Uint8Array
  largura: number
  altura: number
  tamanho: number
  qualidade: number
}

/** Subconjunto da biblioteca de imagem usado (imagescript): injetado para testar em Node e rodar no Deno. */
// deno-lint-ignore no-explicit-any
export type ImagemLib = { decode(data: Uint8Array): Promise<any> }

/** Redimensiona (máx. 1000 px), converte para JPEG sem metadados, recomprime até caber no teto. Descarta menor que 300 px. */
export async function processarImagem(entrada: Uint8Array, lib: ImagemLib): Promise<Processada | { descartada: string }> {
  let img
  try {
    img = await lib.decode(entrada)
  } catch {
    return { descartada: 'imagem ilegível' }
  }
  if (Math.min(img.width, img.height) < LIMITES.minimoPx) return { descartada: 'imagem menor que 300 px' }
  const maior = Math.max(img.width, img.height)
  if (maior > LIMITES.maiorLadoPx) {
    const f = LIMITES.maiorLadoPx / maior
    img = img.resize(Math.round(img.width * f), Math.round(img.height * f))
  }
  // encode de JPEG recria o arquivo do zero: EXIF, perfil e comentários não passam
  let ultimo: Uint8Array | null = null
  let q = 0
  for (const qualidade of LIMITES.qualidades) {
    ultimo = await img.encodeJPEG(qualidade)
    q = qualidade
    if (ultimo.length <= LIMITES.metaBytes) break
  }
  if (!ultimo || ultimo.length > LIMITES.tetoBytes) return { descartada: 'imagem acima de 300 KB mesmo recomprimida' }
  return { bytes: ultimo, largura: img.width, altura: img.height, tamanho: ultimo.length, qualidade: q }
}

export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const d = await crypto.subtle.digest('SHA-256', bytes)
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, '0')).join('')
}

/** Nome neutro no Storage: só hash, sem origem e sem nome do produto. */
export function nomeArquivoNeutro(hash: string): string {
  return `${hash.slice(0, 2)}/${hash.slice(0, 32)}.jpg`
}

/** Legenda curta e natural. Nunca cita origem, SKU, preço nem fornecedor. */
export function legendaSugerida(grupo: string, aproximada: boolean, indice: number, total: number): string {
  const nome = grupo.toLowerCase().replace(/\s+/g, ' ')
  if (aproximada) return total > 1 && indice > 0 ? 'Outro exemplo ilustrativo.' : `Foto ilustrativa de ${nome}. O seu pode variar no acabamento, a gente confirma na hora do orçamento.`
  return total > 1 && indice > 0 ? 'Outra opção.' : `Olha como fica: ${nome}.`
}

/** Texto que o cliente ou o agente podem ver não pode trazer a origem. `origem` é o domínio/nome vindo do banco. */
export function vazaOrigem(texto: string, origem: string[]): boolean {
  const t = texto.toLowerCase()
  return origem.some((o) => o && t.includes(o.toLowerCase())) || /https?:\/\/\S*(obs\.|myhuaweicloud)/i.test(texto)
}

export interface Janela { pedidosUltimoMinuto: number; imagensHoje: number }
export type Decisao = { ok: true; quantidade: number } | { ok: false; motivo: 'muito_rapido' | 'limite_diario' }

/** 1 pedido de foto por minuto por conversa; 10 imagens por contato por dia; máx. 3 por pedido. */
export function aplicarLimites(j: Janela, pedido: number): Decisao {
  if (j.pedidosUltimoMinuto >= LIMITES.pedidosPorMinuto) return { ok: false, motivo: 'muito_rapido' }
  const restante = LIMITES.imagensPorContatoDia - j.imagensHoje
  if (restante <= 0) return { ok: false, motivo: 'limite_diario' }
  return { ok: true, quantidade: Math.max(1, Math.min(pedido || 1, LIMITES.porPedido, restante)) }
}
