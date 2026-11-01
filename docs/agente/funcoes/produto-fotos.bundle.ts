// GERADO por "node scripts/bundle-funcao.ts produto-fotos". NÃO edite aqui: edite supabase/functions/ e gere de novo.
// Painel do Supabase > Edge Functions > Deploy a new function (ou Code > Deploy updates) > Via Editor. Nome: produto-fotos. "Verify JWT" desligado (a função confere o dono ou a service role).
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

// Fotos de produto para o agente. A origem das imagens é INTERNA: o endereço vem de app_settings.fotos.origem_base (banco),
// nunca aparece em resposta, legenda, nome de arquivo, metadado nem log. A resposta ao agente é mínima: { enviadas, legenda_sugerida }.
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const GRAPH = 'https://graph.facebook.com/v21.0'
const WINDOW_MS = 24 * 60 * 60 * 1000
const BUCKET = 'produto-fotos'
const ORIENTACAO_SEM_FOTO = 'NUNCA diga ao cliente que não temos foto. Diga que vai separar as fotos e já envia, siga com a conversa (quantidade, arte, orçamento) e não envie foto de outro produto. A equipe já foi avisada.'

interface Body {
  acao?: 'enviar' | 'rebuscar' | 'trocar' | 'topos' | 'varrer'
  termo_ou_sku?: string
  quantidade_fotos?: number
  conversation_id?: string
  /** rebuscar/trocar: grupo do catálogo */
  grupo?: string
  /** trocar (tela do dono): endereço de uma imagem escolhida por ele */
  url_imagem?: string
  /** varrer: categoria do menu da origem e página inicial */
  topo?: string
  pagina?: number
}

const dormir = (ms: number) => new Promise((r) => setTimeout(r, ms))
let ultimoAcesso = 0
/** No máximo 1 requisição por segundo à origem, tempo limite de 15 s, User-Agent identificável, sem paralelismo. */
async function buscarOrigem(url: string, opcoes: { binario?: boolean; post?: string } = {}): Promise<Response> {
  const espera = LIMITES.intervaloOrigemMs - (Date.now() - ultimoAcesso)
  if (espera > 0) await dormir(espera)
  ultimoAcesso = Date.now()
  const ctl = new AbortController()
  const t = setTimeout(() => ctl.abort(), LIMITES.timeoutOrigemMs)
  try {
    return await fetch(url, {
      method: opcoes.post !== undefined ? 'POST' : 'GET',
      headers: { 'User-Agent': LIMITES.userAgent, Accept: opcoes.binario ? 'image/*' : '*/*', ...(opcoes.post !== undefined ? { 'Content-Type': 'application/x-www-form-urlencoded' } : {}) },
      body: opcoes.post, signal: ctl.signal, redirect: 'follow',
    })
  } finally {
    clearTimeout(t)
  }
}

/** Verificação whitelabel com um modelo pequeno de visão. Sem chave configurada, nada é aprovado sozinho (fica para o dono). */
async function conferirMarca(jpeg: Uint8Array): Promise<{ limpa: boolean | null; motivo: string }> {
  const chave = Deno.env.get('GEMINI_API_KEY')
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

// deno-lint-ignore no-explicit-any
type Db = any
const decode = { decode: (d: Uint8Array) => Image.decode(d) }

/** Baixa, processa, guarda e confere UMA imagem da origem. Devolve true se ficou guardada (aprovada ou à espera do dono). */
async function guardarImagem(db: Db, grupo: string, urlImagem: string, sku: string | null, aproximada: boolean, ordem: number, verificar: boolean, fonte = 'site'): Promise<{ guardada: boolean; baixaQualidade: boolean }> {
  try {
    const r = await buscarOrigem(urlImagem, { binario: true })
    if (!r.ok) return { guardada: false, baixaQualidade: false }
    const p = await processarImagem(new Uint8Array(await r.arrayBuffer()), decode)
    if ('descartada' in p) return { guardada: false, baixaQualidade: false }
    const hash = await sha256Hex(p.bytes)
    const arquivo = nomeArquivoNeutro(hash)
    const up = await db.storage.from(BUCKET).upload(arquivo, p.bytes, { contentType: 'image/jpeg', upsert: true })
    if (up.error) return { guardada: false, baixaQualidade: false }
    const { data: id } = await db.rpc('foto_registrar', {
      p_grupo: grupo, p_url_origem: urlImagem, p_arquivo: arquivo, p_largura: p.largura, p_altura: p.altura, p_bytes: p.tamanho, p_hash: hash,
      p_aproximada: aproximada, p_ordem: ordem, p_baixa_qualidade: p.baixaQualidade, p_fonte: fonte, p_sku: sku,
    })
    if (!id) return { guardada: false, baixaQualidade: false }
    // whitelabel: na primeira vez de cada imagem
    if (verificar) {
      const v = await conferirMarca(p.bytes)
      if (v.limpa === true) await db.rpc('foto_decidir', { p_id: id, p_status: 'aprovada', p_motivo: v.motivo || null })
      else if (v.limpa === false) { await db.rpc('foto_decidir', { p_id: id, p_status: 'bloqueada', p_motivo: `marca visível: ${v.motivo}` }); return { guardada: false, baixaQualidade: p.baixaQualidade } }
      else await db.from('produto_fotos').update({ revisar: true, motivo: v.motivo }).eq('id', id)
    } else {
      await db.rpc('foto_decidir', { p_id: id, p_status: 'aprovada', p_motivo: 'verificação automática desligada' })
    }
    return { guardada: true, baixaQualidade: p.baixaQualidade }
  } catch (e) {
    console.error('Falha ao processar uma imagem:', (e as Error).message)
    return { guardada: false, baixaQualidade: false }
  }
}

/** Candidatas do mapa (SKU exato, termo, variedade do grupo). Sem mapa, cai na página da categoria do grupo. */
async function candidatas(db: Db, grupo: string, sku: string | null, termo: string | null, origemBase: string): Promise<{ imagem: string; exato: boolean }[]> {
  const { data } = await db.rpc('foto_candidatas', { p_grupo: grupo, p_sku: sku, p_termo: termo, p_limite: 8 })
  const lista = ((data ?? []) as { imagem: string; exato: boolean }[]).filter((c) => /^https:\/\//.test(c.imagem))
  if (lista.length) return lista
  try {
    const res = await buscarOrigem(`${origemBase.replace(/\/+$/, '')}/produto/categoria/${slugCategoria(grupo)}`)
    if (!res.ok) return []
    return lerCartoes(await res.text()).slice(0, 8).map((c) => ({ imagem: c.imagem, exato: false }))
  } catch { return [] }
}

/** Preenche o grupo: até 3 imagens aproveitáveis (as grandes primeiro), aceitando baixa qualidade quando é só o que existe. */
async function preencherGrupo(db: Db, grupo: string, sku: string | null, termo: string | null, origemBase: string, verificar: boolean): Promise<{ situacao: 'ok' | 'sem_foto' | 'erro'; novas: number }> {
  const lista = await candidatas(db, grupo, sku, termo, origemBase)
  if (!lista.length) {
    await db.rpc('foto_fechar_busca', { p_grupo: grupo, p_situacao: 'erro', p_detalhe: 'nenhuma imagem mapeada para o grupo' })
    return { situacao: 'erro', novas: 0 }
  }
  let boas = 0
  let novas = 0
  let ordem = 0
  for (const c of lista) {
    if (boas >= LIMITES.porPedido) break
    const r = await guardarImagem(db, grupo, c.imagem, c.exato ? sku : null, !c.exato, ordem++, verificar)
    if (r.guardada) { novas++; if (!r.baixaQualidade) boas++ }
  }
  await db.rpc('foto_fechar_busca', { p_grupo: grupo, p_situacao: novas ? 'ok' : 'erro', p_detalhe: novas ? null : 'imagens do grupo não puderam ser aproveitadas' })
  return { situacao: novas ? 'ok' : 'erro', novas }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)
  const db = serviceClient()
  const quem = await requireOwnerOrServer(req, db)
  if (!quem) return json({ error: 'Não autorizado.' }, 401)

  let input: Body
  try { input = await req.json() } catch { return json({ error: 'Corpo da requisição inválido.' }, 400) }
  const acao = input.acao ?? 'enviar'

  const { data: cfgRow } = await db.from('app_settings').select('value').eq('key', 'fotos').maybeSingle()
  const cfg = (cfgRow?.value ?? {}) as { origem_base?: string; ligado?: boolean; verificar_marca?: boolean }
  const origemBase = String(cfg.origem_base ?? '').replace(/\/+$/, '')
  const verificar = cfg.verificar_marca !== false
  const segredosOrigem = [origemBase, (() => { try { return new URL(origemBase).hostname.replace(/^www\./, '') } catch { return '' } })()]

  // ---- tela do dono e agendamentos: mapear o menu da origem, refazer a busca de um grupo, trocar uma imagem
  if (acao === 'topos' || acao === 'varrer' || acao === 'rebuscar' || acao === 'trocar') {
    if (!origemBase) return json({ error: 'A origem das fotos ainda não foi configurada pelo dono.' }, 409)

    if (acao === 'topos') {
      // todas as categorias do menu lateral (a primeira parte de cada caminho)
      try {
        const home = await (await buscarOrigem(`${origemBase}/`)).text()
        const topos = [...new Set([...home.matchAll(/listServico\('[^']*',\s*'([^'/]+)(?:\/[^']*)?'\)/g)].map((m) => m[1]))]
        return json({ ok: true, topos })
      } catch { return json({ error: 'Não foi possível ler o menu da origem agora.' }, 502) }
    }

    if (acao === 'varrer') {
      // Uma categoria do menu, em partes (a função tem limite de tempo): devolve a próxima página ou null quando acabou.
      const topo = (input.topo ?? '').trim()
      if (!/^[a-z0-9-]+$/i.test(topo)) return json({ error: 'Informe a categoria do menu (topo).' }, 400)
      let pagina = Math.max(0, Number(input.pagina) || 0)
      const limite = Date.now() + 100_000
      let itens = 0
      while (Date.now() < limite) {
        let cards: string[] = []
        try {
          const r = await buscarOrigem(`${origemBase}/home/CategoriaPaginada`, { post: `categoria=${encodeURIComponent(topo)}&pagina=${pagina}` })
          if (!r.ok) return json({ ok: true, topo, itens, proxima: null, aviso: `origem respondeu ${r.status}` })
          cards = ((await r.json()) as { cardsHomepage?: string[] }).cardsHomepage ?? []
        } catch { return json({ ok: false, topo, itens, proxima: pagina, error: 'Falha de rede; tente de novo a partir desta página.' }, 502) }
        if (!cards.length) return json({ ok: true, topo, itens, proxima: null })
        const lote = lerCartoes(cards.join('\n')).map((c) => ({ codigo: c.codigo, topo, caminho: c.caminho, imagem: c.imagem }))
        if (lote.length) { await db.rpc('foto_mapa_gravar', { p_itens: lote }); itens += lote.length }
        pagina++
      }
      return json({ ok: true, topo, itens, proxima: pagina })
    }

    const grupo = input.grupo?.trim()
    if (!grupo) return json({ error: 'Informe o grupo.' }, 400)
    if (acao === 'trocar') {
      // só endereços https públicos (nunca rede interna); quem chama é o dono ou o servidor
      let host = ''
      try { host = new URL(input.url_imagem ?? '').hostname } catch { /* inválido */ }
      if (!/^https:\/\//.test(input.url_imagem ?? '') || !host.includes('.') || /^(localhost|127\.|10\.|192\.168\.|169\.254\.)/.test(host)) return json({ error: 'Endereço de imagem inválido.' }, 400)
      const r = await guardarImagem(db, grupo, input.url_imagem!, null, true, 0, false, 'manual')
      if (!r.guardada) return json({ error: 'Não foi possível aproveitar essa imagem.' }, 422)
      return json({ ok: true })
    }
    const r = await preencherGrupo(db, grupo, null, input.termo_ou_sku ?? null, origemBase, verificar)
    return json({ ok: true, situacao: r.situacao, novas: r.novas })
  }

  // ---- ferramenta do agente: enviar_foto_produto
  const termo = (input.termo_ou_sku ?? '').trim().slice(0, 120)
  if (!termo) return json({ error: 'Informe o produto ou o SKU.' }, 400)
  if (!input.conversation_id || !UUID.test(input.conversation_id)) return json({ error: 'Informe a conversa.' }, 400)

  const { data: conv } = await db.from('conversations').select('id, contact_id, last_inbound_at, ad_window_until, contact:contacts(wa_id)').eq('id', input.conversation_id).maybeSingle()
  // deno-lint-ignore no-explicit-any
  const waId = (conv as any)?.contact?.wa_id as string | undefined
  if (!conv || !waId) return json({ error: 'Conversa não encontrada.' }, 404)
  const ate = Math.max(conv.last_inbound_at ? new Date(conv.last_inbound_at).getTime() + WINDOW_MS : 0, conv.ad_window_until ? new Date(conv.ad_window_until).getTime() : 0)
  if (ate <= Date.now()) return json({ error: 'A janela de atendimento está fechada.', code: 'window_closed' }, 409)

  const registrar = (grupo: string | null, qtd: number, bytes: number, via: 'cache' | 'busca' | null, resultado: string) =>
    db.rpc('foto_registrar_envio', { p_conversation: conv.id, p_contact: conv.contact_id, p_grupo: grupo, p_quantidade: qtd, p_bytes: bytes, p_via: via, p_resultado: resultado })

  // limites: 1 pedido por minuto por conversa, 10 imagens por contato por dia, 3 por pedido
  const { data: lim } = await db.rpc('foto_limites', { p_conversation: conv.id, p_contact: conv.contact_id })
  const decisao = aplicarLimites({ pedidosUltimoMinuto: lim?.pedidos_ultimo_minuto ?? 0, imagensHoje: lim?.imagens_hoje ?? 0 }, Number(input.quantidade_fotos) || 1)
  if (!decisao.ok) {
    await registrar(null, 0, 0, null, decisao.motivo)
    return json({ enviadas: 0, motivo: decisao.motivo, orientacao: decisao.motivo === 'muito_rapido' ? 'Já enviei fotos agora há pouco. Espere um instante e pergunte se o cliente quer ver outra opção.' : 'Por hoje já enviei várias fotos. Ofereça o orçamento e diga que a equipe mostra mais se ele quiser.' })
  }

  const semFoto = async (grupo: string | null) => {
    await registrar(grupo, 0, 0, null, 'sem_foto')
    // a equipe é avisada (gravidade baixa) sem interromper o atendimento; o agente nunca diz ao cliente que não há foto
    await db.from('alertas').insert({ tipo: 'foto_indisponivel', gravidade: 'baixa', conversation_id: conv.id, contact_id: conv.contact_id, motivo: `Pedido de foto sem imagem disponível (${grupo ?? 'produto não identificado'}). Enviar a foto à mão.` })
    return json({ enviadas: 0, sem_foto: true, orientacao: ORIENTACAO_SEM_FOTO })
  }

  if (cfg.ligado === false) return await semFoto(null)
  const { data: res } = await db.rpc('foto_resolver_grupo', { p_termo: termo })
  if (!res?.ok) return await semFoto(null)
  const grupo = res.grupo as string
  const sku: string | null = res.exato_por_sku ? termo.toUpperCase() : null

  // Sob demanda: só busca e guarda o que o cliente pediu. Nada é pré-carregado.
  let via: 'cache' | 'busca' = 'cache'
  await db.rpc('foto_estado_grupo', { p_grupo: grupo })   // só conta o pedido (ranking dos grupos mais pedidos)
  const quer = decisao.quantidade
  const tem = async () => ((await db.rpc('foto_aprovadas', { p_grupo: grupo, p_quantidade: quer, p_sku: sku })).data ?? []) as { arquivo: string; bytes: number; aproximada: boolean }[]
  let lista = await tem()
  if (sku) {
    // pediu um item específico: a foto dele (uma só); se o item não está no mapa, cai em fotos do grupo
    if (!lista.some((f) => !f.aproximada) && origemBase) {
      const { data: c1 } = await db.rpc('foto_candidatas', { p_grupo: grupo, p_sku: sku, p_termo: null, p_limite: 1 })
      const c = (c1 ?? [])[0] as { imagem: string; exato: boolean } | undefined
      if (c?.exato && /^https:\/\//.test(c.imagem)) { via = 'busca'; await guardarImagem(db, grupo, c.imagem, sku, false, 0, verificar); lista = await tem() }
    }
  }
  if (lista.length < quer && origemBase && !lista.some((f) => !f.aproximada && sku)) {
    // sem foto suficiente guardada: busca só a quantidade pedida (itens que combinam com o termo; senão variedade do grupo)
    const cands = await candidatas(db, grupo, sku, sku ? null : termo, origemBase)
    let faltam = quer - lista.length
    let ordem = 10
    for (const c of cands) {
      if (faltam <= 0) break
      via = 'busca'
      const r = await guardarImagem(db, grupo, c.imagem, c.exato ? sku : null, !c.exato, ordem++, verificar)
      if (r.guardada) faltam--
    }
    lista = await tem()
  }
  // item específico com foto própria: manda só a dele (as outras do grupo seriam apenas ilustrativas)
  if (sku && lista.some((f) => !f.aproximada)) lista = lista.filter((f) => !f.aproximada).slice(0, quer)
  if (!lista.length) return await semFoto(grupo)

  const env = requireEnv('WHATSAPP_TOKEN', 'WHATSAPP_PHONE_NUMBER_ID')
  if (!env) return json({ error: 'Integração com o WhatsApp não configurada no servidor.' }, 500)

  let enviadas = 0
  let bytes = 0
  let primeiraLegenda = ''
  for (let i = 0; i < lista.length; i++) {
    const f = lista[i]
    const legenda = legendaSugerida(grupo, f.aproximada, i, lista.length)
    if (vazaOrigem(legenda, segredosOrigem)) continue
    const { data: signed } = await db.storage.from(BUCKET).createSignedUrl(f.arquivo, 300)
    if (!signed?.signedUrl) continue
    let r: Response
    try {
      r = await fetch(`${GRAPH}/${env.WHATSAPP_PHONE_NUMBER_ID}/messages`, {
        method: 'POST', headers: { Authorization: `Bearer ${env.WHATSAPP_TOKEN}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ messaging_product: 'whatsapp', to: waId, type: 'image', image: { link: signed.signedUrl, caption: legenda } }),
      })
    } catch { continue }
    const out = await r.json().catch(() => ({}))
    if (!r.ok) { console.error('Erro da Meta ao enviar foto:', out?.error?.code); continue }
    const agora = new Date().toISOString()
    await db.from('messages').insert({ conversation_id: conv.id, wa_message_id: out?.messages?.[0]?.id ?? null, direction: 'out', type: 'image', body: `[foto] ${legenda}`, status: 'sent', created_at: agora })
    await db.from('conversations').update({ last_message_at: agora, last_message_preview: '[foto do produto]' }).eq('id', conv.id)
    enviadas++
    bytes += f.bytes
    if (!primeiraLegenda) primeiraLegenda = legenda
  }
  if (!enviadas) { await registrar(grupo, 0, 0, via, 'erro'); return json({ error: 'Não foi possível enviar as fotos agora. Chame o dono.' }, 502) }
  await registrar(grupo, enviadas, bytes, via, 'enviada')
  // resposta mínima ao agente: nunca traz origem, URL, SKU nem nome de arquivo
  return json({ enviadas, legenda_sugerida: primeiraLegenda })
})
