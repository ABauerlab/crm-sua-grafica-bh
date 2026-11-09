// GERADO por "node scripts/bundle-funcao.ts loja-fichas". NÃO edite aqui: edite supabase/functions/ e gere de novo.
// Painel do Supabase > Edge Functions > Deploy a new function (ou Code > Deploy updates) > Via Editor. Nome: loja-fichas. "Verify JWT" desligado (a função confere o dono ou a service role).
import { Image } from 'https://deno.land/x/imagescript@1.3.0/mod.ts'
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2'
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-cron-secret',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}

/** Cliente com service role: ignora RLS. Use apenas dentro das Edge Functions. */
function serviceClient(): SupabaseClient {
  return createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
    auth: { persistSession: false, autoRefreshToken: false },
  })
}

interface Staff {
  userId: string
  role: 'admin' | 'agent'
}

/** Valida o JWT do chamador e exige que ele exista em profiles. */
async function requireStaff(req: Request, db: SupabaseClient): Promise<Staff | null> {
  const token = req.headers.get('Authorization')?.replace(/^Bearer\s+/i, '')
  if (!token) return null
  const { data: userData, error } = await db.auth.getUser(token)
  if (error || !userData.user) return null
  const { data: profile } = await db.from('profiles').select('id, role').eq('id', userData.user.id).maybeSingle()
  if (!profile) return null
  return { userId: profile.id, role: profile.role }
}

function requireEnv(...names: string[]): Record<string, string> | null {
  const out: Record<string, string> = {}
  for (const n of names) {
    const v = Deno.env.get(n)
    if (!v) {
      console.error(`Segredo ausente: ${n}`)
      return null
    }
    out[n] = v
  }
  return out
}

/** Confere uma chave de serviço perguntando ao próprio Supabase: só a service role passa no endpoint de administração do Auth. */
async function ehServiceRole(token: string): Promise<boolean> {
  const url = Deno.env.get('SUPABASE_URL')
  if (!url || token.length < 20) return false
  try {
    const res = await fetch(`${url}/auth/v1/admin/users?page=1&per_page=1`, { headers: { apikey: token, Authorization: `Bearer ${token}` } })
    return res.ok
  } catch {
    return false
  }
}

/** Chamador autorizado a cobrar: o dono logado (JWT) ou outro servidor da própria Sua Gráfica usando a service role key. */
async function requireOwnerOrServer(req: Request, db: SupabaseClient): Promise<'dono' | 'servidor' | null> {
  const token = req.headers.get('Authorization')?.replace(/^Bearer\s+/i, '')
  if (!token) return null
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
  if (serviceKey && token.length === serviceKey.length && token === serviceKey) return 'servidor'
  const { data: userData, error } = await db.auth.getUser(token)
  // Não é um usuário: pode ser a service role de outro formato (a injetada na função nem sempre é igual à do painel)
  if (error || !userData.user) return (await ehServiceRole(token)) ? 'servidor' : null
  const { data: profile } = await db.from('profiles').select('id').eq('id', userData.user.id).maybeSingle()
  if (!profile) return null
  const { data: owner } = await db.from('app_settings').select('value').eq('key', 'owner').maybeSingle()
  const ownerEmail = String((owner?.value as { email?: string } | null)?.email ?? '').toLowerCase()
  if (ownerEmail && (userData.user.email ?? '').toLowerCase() !== ownerEmail) return null
  return 'dono'
}

/** Só a service role (outro servidor da própria Sua Gráfica, como o n8n). Nenhum usuário logado passa. */
async function requireServiceRole(req: Request): Promise<boolean> {
  const token = req.headers.get('Authorization')?.replace(/^Bearer\s+/i, '')
  if (!token) return false
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
  if (serviceKey && token.length === serviceKey.length && token === serviceKey) return true
  return ehServiceRole(token)
}

// Leitura da ficha técnica pública da origem interna do catálogo e tradução para linguagem de balcão.
// Funções puras (sem Deno): testadas em Node por scripts/test-loja.ts e usadas pela Edge Function loja-fichas.
// A origem NUNCA aparece no que sai daqui: frases com a marca da origem são descartadas e o resultado é conferido de novo.

interface FichaOrigem {
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

interface FichaBalcao {
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
function linhasVisiveis(html: string): string[] {
  const semCodigo = html.replace(/<script[\s\S]*?<\/script>|<style[\s\S]*?<\/style>|<!--[\s\S]*?-->/gi, '')
  return decodificar(semCodigo.replace(/<[^>]+>/g, '\n'))
    .split('\n').map((l) => l.replace(/\s+/g, ' ').trim()).filter(Boolean)
}

/** Termos da marca da origem, derivados do host configurado (ex.: "fulanografica.com.br" -> fulanografica, fulano gráfica, fulano). */
function marcasDaOrigem(origemBase: string): string[] {
  let host = ''
  try { host = new URL(origemBase).hostname.replace(/^www\./, '') } catch { return [] }
  const rotulo = host.split('.')[0]
  const prefixo = rotulo.replace(/gr[aá]fica$/i, '')
  return [...new Set([rotulo, `${prefixo} gráfica`, `${prefixo} grafica`, prefixo, host].filter((t) => t.length >= 3).map((t) => t.toLowerCase()))]
}

const sem = (s: string) => s.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '')
function citaMarca(texto: string, marcas: string[]): boolean {
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
function lerFicha(html: string, marcas: string[]): FichaOrigem {
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
function limparTitulo(h1: string): string | null {
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
function capitalizar(s: string): string {
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

const traduzirAcabamento = (s: string | null) => (s ? (GLOSSARIO.find(([r]) => r.test(s))?.[1] ?? capitalizar(s)) : null)
const traduzirMaterial = (s: string | null) => (s ? (MATERIAIS.find(([r]) => r.test(s))?.[1] ?? capitalizar(s)) : null)
const traduzirCores = (s: string | null) => (s ? (CORES[s.toUpperCase().replace(/\s/g, '')] ?? s) : null)

function espessura(g: number | null, material: string | null): string | null {
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
function fichaBalcao(f: FichaOrigem, marcas: string[]): FichaBalcao {
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

// Fotos de produto (Etapa 4B): lógica pura, sem rede, testada em Node (scripts/test-fotos.ts).
// A origem das imagens é INTERNA: o endereço dela vem de app_settings.fotos (banco), nunca do repositório.

const LIMITES = {
  maiorLadoPx: 1000,
  /** abaixo disto é ícone ou lixo e é descartada; entre 100 e 400 px vale (baixa qualidade, o dono aceitou), ampliada para ficar legível */
  minimoPx: 100,
  baixaQualidadePx: 400,
  ampliarAtePx: 640,
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

interface CartaoOrigem {
  /** caminho do produto na origem (último trecho é o código do item) */
  caminho: string
  codigo: string
  imagem: string
}

/** Lê os cartões de uma página de listagem: link do item + imagem do serviço. Ignora banners, ícones e logos. */
function lerCartoes(html: string): CartaoOrigem[] {
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

function normalizar(s: string): string {
  return s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim()
}

/** Slug de categoria no formato da origem: "BLOCOS, COMANDAS E TALÕES" -> "blocos-comandas-e-taloes". */
function slugCategoria(grupo: string): string {
  return normalizar(grupo).replace(/ /g, '-')
}

/** Ordena os cartões: primeiro os que combinam com o termo do cliente; devolve também se houve combinação. */
function escolherCartoes(cartoes: CartaoOrigem[], termo: string | null, quantidade: number): { itens: CartaoOrigem[]; exato: boolean } {
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

interface Processada {
  bytes: Uint8Array
  largura: number
  altura: number
  tamanho: number
  qualidade: number
  /** a origem só tinha imagem pequena: serve, mas aparece marcada na tela do dono para trocar quando houver foto melhor */
  baixaQualidade: boolean
}

/** Subconjunto da biblioteca de imagem usado (imagescript): injetado para testar em Node e rodar no Deno. */
// deno-lint-ignore no-explicit-any
type ImagemLib = { decode(data: Uint8Array): Promise<any> }

/** Redimensiona (máx. 1000 px), converte para JPEG sem metadados, recomprime até caber no teto. Descarta menor que 300 px. */
async function processarImagem(entrada: Uint8Array, lib: ImagemLib): Promise<Processada | { descartada: string }> {
  let img
  try {
    img = await lib.decode(entrada)
  } catch {
    return { descartada: 'imagem ilegível' }
  }
  if (Math.min(img.width, img.height) < LIMITES.minimoPx) return { descartada: 'imagem pequena demais (ícone)' }
  const maior = Math.max(img.width, img.height)
  const baixaQualidade = maior < LIMITES.baixaQualidadePx
  if (maior < LIMITES.ampliarAtePx) {
    // miniatura: amplia com suavização para o WhatsApp não mostrar um quadradinho; não cria detalhe novo
    const f = LIMITES.ampliarAtePx / maior
    img = img.resize(Math.round(img.width * f), Math.round(img.height * f))
  } else if (maior > LIMITES.maiorLadoPx) {
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
  return { bytes: ultimo, largura: img.width, altura: img.height, tamanho: ultimo.length, qualidade: q, baixaQualidade }
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const d = await crypto.subtle.digest('SHA-256', bytes)
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, '0')).join('')
}

/** Nome neutro no Storage: só hash, sem origem e sem nome do produto. */
function nomeArquivoNeutro(hash: string): string {
  return `${hash.slice(0, 2)}/${hash.slice(0, 32)}.jpg`
}

/** Legenda curta e natural. Nunca cita origem, SKU, preço nem fornecedor. */
function legendaSugerida(grupo: string, aproximada: boolean, indice: number, total: number): string {
  const nome = grupo.toLowerCase().replace(/\s+/g, ' ')
  if (aproximada) return total > 1 && indice > 0 ? 'Outro exemplo ilustrativo.' : `Foto ilustrativa de ${nome}. O seu pode variar no acabamento, a gente confirma na hora do orçamento.`
  return total > 1 && indice > 0 ? 'Outra opção.' : `Olha como fica: ${nome}.`
}

/** Texto que o cliente ou o agente podem ver não pode trazer a origem. `origem` é o domínio/nome vindo do banco. */
function vazaOrigem(texto: string, origem: string[]): boolean {
  const t = texto.toLowerCase()
  return origem.some((o) => o && t.includes(o.toLowerCase())) || /https?:\/\/\S*(obs\.|myhuaweicloud)/i.test(texto)
}

interface Janela { pedidosUltimoMinuto: number; imagensHoje: number }
type Decisao = { ok: true; quantidade: number } | { ok: false; motivo: 'muito_rapido' | 'limite_diario' }

/** 1 pedido de foto por minuto por conversa; 10 imagens por contato por dia; máx. 3 por pedido. */
function aplicarLimites(j: Janela, pedido: number): Decisao {
  if (j.pedidosUltimoMinuto >= LIMITES.pedidosPorMinuto) return { ok: false, motivo: 'muito_rapido' }
  const restante = LIMITES.imagensPorContatoDia - j.imagensHoje
  if (restante <= 0) return { ok: false, motivo: 'limite_diario' }
  return { ok: true, quantidade: Math.max(1, Math.min(pedido || 1, LIMITES.porPedido, restante)) }
}

/** Verificação whitelabel com um modelo pequeno de visão. Sem chave, devolve null (nada é dado como limpo sozinho). */
async function conferirMarca(jpeg: Uint8Array, chave: string | undefined): Promise<{ limpa: boolean | null; motivo: string }> {
  if (!chave) return { limpa: null, motivo: 'verificação automática indisponível' }
  let bin = ''
  for (let i = 0; i < jpeg.length; i += 0x8000) bin += String.fromCharCode(...jpeg.subarray(i, i + 0x8000))
  const prompt = 'Olhe esta foto de produto gráfico. Responda SOMENTE em JSON: {"marca": true|false, "motivo": "curto"}. ' +
    'marca = true se houver logotipo, marca, nome de empresa, site, telefone ou qualquer texto que identifique quem fez a foto ou vende o produto. ' +
    'Texto genérico de exemplo (como "Seu Nome Aqui") e arte fictícia da peça NÃO contam como marca.'
  try {
    const ctl = new AbortController()
    const t = setTimeout(() => ctl.abort(), 20000)
    const res = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash-lite:generateContent?key=${chave}`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, signal: ctl.signal,
      body: JSON.stringify({ contents: [{ parts: [{ text: prompt }, { inline_data: { mime_type: 'image/jpeg', data: btoa(bin) } }] }], generationConfig: { responseMimeType: 'application/json', temperature: 0 } }),
    })
    clearTimeout(t)
    if (!res.ok) return { limpa: null, motivo: 'verificação automática falhou' }
    const j = await res.json()
    const out = JSON.parse(j?.candidates?.[0]?.content?.parts?.[0]?.text ?? '{}')
    if (typeof out.marca !== 'boolean') return { limpa: null, motivo: 'resposta da verificação ilegível' }
    return { limpa: !out.marca, motivo: String(out.motivo ?? '').slice(0, 200) }
  } catch {
    return { limpa: null, motivo: 'verificação automática falhou' }
  }
}

// E-commerce Fase 2: lê a ficha técnica pública de cada produto na origem interna, traduz para linguagem de balcão,
// guarda a foto (JPEG leve, nome neutro, bucket público loja-produtos) e aplica na vitrine (loja_ficha_gravar).
// Chamada pelo agendamento (x-cron-secret) ou pelo dono/service role. Uma página a cada 2 s; nada de log com conteúdo ou origem.
const UA = 'Mozilla/5.0 (compatible; SuaGraficaBH-catalogo/1.0)'
const decode = { decode: (d: Uint8Array) => Image.decode(d) }
const espera = (ms: number) => new Promise((r) => setTimeout(r, ms))

async function baixar(url: string, binario: boolean): Promise<Response> {
  const ctl = new AbortController()
  const t = setTimeout(() => ctl.abort(), 20000)
  try {
    return await fetch(url, { headers: { 'User-Agent': UA, Accept: binario ? 'image/*' : 'text/html' }, signal: ctl.signal, redirect: 'follow' })
  } finally {
    clearTimeout(t)
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)
  const db = serviceClient()
  const cronSecret = Deno.env.get('CRON_SECRET')
  const sent = req.headers.get('x-cron-secret')
  const fromCron = !!cronSecret && !!sent && sent.length === cronSecret.length && sent === cronSecret
  if (!fromCron && !(await requireOwnerOrServer(req, db))) return json({ error: 'Não autorizado.' }, 401)

  const [{ data: fotosCfg }, { data: cfgRow }] = await Promise.all([
    db.from('app_settings').select('value').eq('key', 'fotos').maybeSingle(),
    db.from('app_settings').select('value').eq('key', 'loja_fichas').maybeSingle(),
  ])
  const base = String((fotosCfg?.value as { origem_base?: string } | null)?.origem_base ?? '')
  const cfg = (cfgRow?.value ?? {}) as { ligado?: boolean; por_execucao?: number; intervalo_ms?: number; verificar_marca?: boolean }
  if (!base) return json({ error: 'Origem do catálogo não configurada.' }, 400)
  if (cfg.ligado === false) return json({ ok: true, desligado: true })
  const host = new URL(base).hostname
  const raiz = `https://${host.startsWith('www.') ? host : `www.${host}`}`
  const marcas = marcasDaOrigem(base)
  const intervalo = Math.max(1500, cfg.intervalo_ms ?? 2000)
  const gemini = cfg.verificar_marca === false ? undefined : Deno.env.get('GEMINI_API_KEY')

  const { data: lote, error } = await db.rpc('loja_fichas_pegar', { p_n: Math.min(cfg.por_execucao ?? 20, 30) })
  if (error) return json({ error: 'Não foi possível pegar o lote.' }, 500)
  const itens = (lote ?? []) as { chave: string; caminho: string; imagem_origem: string | null }[]
  const inicio = Date.now()
  let ok = 0, falhas = 0
  for (const [i, it] of itens.entries()) {
    if (Date.now() - inicio > 110_000) {
      // perto do limite de tempo: devolve o resto para a fila
      await db.from('loja_fichas').update({ status: 'pendente' }).in('chave', itens.slice(i).map((x) => x.chave))
      break
    }
    if (i > 0) await espera(intervalo)
    try {
      const res = await baixar(raiz + it.caminho, false)
      if (!res.ok) throw new Error(`página ${res.status}`)
      const ficha = lerFicha(await res.text(), marcas)
      if (!ficha.material && !ficha.titulo) throw new Error('ficha não encontrada na página')
      const balcao = fichaBalcao(ficha, marcas)
      const { sobre: _sobre, ref: _ref, ...fichaSemTexto } = ficha
      let foto: string | null = null
      let marcaOk: boolean | null = null
      if (it.imagem_origem) {
        const img = await baixar(it.imagem_origem, true)
        if (img.ok) {
          const p = await processarImagem(new Uint8Array(await img.arrayBuffer()), decode)
          if ('bytes' in p) {
            const v = await conferirMarca(p.bytes, gemini)
            marcaOk = v.limpa
            if (v.limpa !== false) {
              const nome = nomeArquivoNeutro(await sha256Hex(p.bytes))
              const up = await db.storage.from('loja-produtos').upload(nome, p.bytes, { contentType: 'image/jpeg', upsert: true, cacheControl: '31536000' })
              if (!up.error) foto = nome
            }
          }
        }
      }
      await db.rpc('loja_ficha_gravar', { p_chave: it.chave, p_ficha: fichaSemTexto, p_balcao: balcao, p_foto: foto, p_marca_ok: marcaOk, p_erro: null })
      ok++
    } catch (e) {
      falhas++
      await db.rpc('loja_ficha_gravar', { p_chave: it.chave, p_ficha: null, p_balcao: null, p_foto: null, p_marca_ok: null, p_erro: e instanceof Error ? e.message : 'erro' })
    }
  }
  console.log(`loja-fichas: ${ok} ok, ${falhas} com erro, ${itens.length} no lote`)
  return json({ ok: true, processados: ok, erros: falhas, lote: itens.length })
})
