// GERADO por "node scripts/bundle-funcao.ts blog-pautas". NÃO edite aqui: edite supabase/functions/ e gere de novo.
// Painel do Supabase > Edge Functions > Deploy a new function (ou Code > Deploy updates) > Via Editor. Nome: blog-pautas. "Verify JWT" desligado (a função confere o dono ou a service role).
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

// Blog do site (Fase 8): leitura de feeds, filtro de assunto, prompt e conferência do texto gerado.
// Sem dependências de Deno para poder ser testado no Node (npm run test:blog).

interface ItemFeed { titulo: string; url: string; resumo: string; data: string | null }
interface CategoriaLoja { slug: string; nome: string }
interface PostGerado { titulo: string; resumo: string; corpo: string; categorias: CategoriaLoja[]; relevancia: number }

const ENTIDADES: Record<string, string> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ', hellip: '...', ndash: '-', mdash: '-', laquo: '"', raquo: '"', rsquo: "'", lsquo: "'", ldquo: '"', rdquo: '"' }

/** minúsculas e sem acento, para comparar termos */
function normalizar(s: string): string {
  return s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase()
}

/** HTML/CDATA de feed -> texto simples, sem o rodapé automático do WordPress */
function textoLimpo(html: string | null | undefined): string {
  if (!html) return ''
  return html
    .replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, '$1')
    .replace(/<p>\s*O (?:post|conteúdo)[\s\S]*?apareceu? primeiro em[\s\S]*?<\/p>/gi, '')
    .replace(/<(script|style)[\s\S]*?<\/\1>/gi, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&#(\d+);/g, (_m, n) => String.fromCodePoint(Number(n)))
    .replace(/&#x([0-9a-f]+);/gi, (_m, n) => String.fromCodePoint(parseInt(n, 16)))
    .replace(/&([a-z]+);/gi, (m, n) => ENTIDADES[n.toLowerCase()] ?? m)
    .replace(/\s*(?:The post|O post|O conteúdo) .{0,200}? (?:appeared first on|apareceu primeiro em|aparece primeiro em) .{0,120}$/i, '')
    .replace(/\s+/g, ' ')
    .trim()
}

function tag(bloco: string, nome: string): string | null {
  const m = bloco.match(new RegExp(`<${nome}(?:\\s[^>]*)?>([\\s\\S]*?)</${nome}>`, 'i'))
  return m ? m[1] : null
}

/** Lê RSS 2.0 ou Atom. Devolve no máximo `max` itens com título, link, resumo e data ISO. */
function lerFeed(xml: string, max = 30): ItemFeed[] {
  const blocos = xml.match(/<item[\s>][\s\S]*?<\/item>/gi) ?? xml.match(/<entry[\s>][\s\S]*?<\/entry>/gi) ?? []
  const out: ItemFeed[] = []
  for (const b of blocos.slice(0, max)) {
    const titulo = textoLimpo(tag(b, 'title'))
    let url = textoLimpo(tag(b, 'link'))
    if (!url) url = b.match(/<link[^>]*href="([^"]+)"/i)?.[1] ?? ''
    const resumo = textoLimpo(tag(b, 'description') ?? tag(b, 'summary') ?? tag(b, 'content:encoded') ?? tag(b, 'content')).slice(0, 2000)
    const bruta = textoLimpo(tag(b, 'pubDate') ?? tag(b, 'published') ?? tag(b, 'updated') ?? tag(b, 'dc:date'))
    const d = bruta ? new Date(bruta) : null
    if (!titulo || !/^https?:\/\//i.test(url)) continue
    out.push({ titulo: titulo.slice(0, 300), url: url.slice(0, 600), resumo, data: d && !isNaN(d.getTime()) ? d.toISOString() : null })
  }
  return out
}

/** Itens da NewsAPI (/v2/everything) no mesmo formato do feed */
function itensNewsApi(j: unknown): (ItemFeed & { fonte: string })[] {
  const arts = ((j as { articles?: unknown[] })?.articles ?? []) as { title?: string; url?: string; description?: string; publishedAt?: string; source?: { name?: string } }[]
  return arts.filter((a) => a.title && a.url && a.title !== '[Removed]').map((a) => ({
    titulo: textoLimpo(a.title).slice(0, 300), url: String(a.url).slice(0, 600), resumo: textoLimpo(a.description).slice(0, 2000),
    data: a.publishedAt ?? null, fonte: (a.source?.name ?? 'NewsAPI').slice(0, 80),
  }))
}

/** Filtro barato antes do modelo: precisa de um termo do setor e nenhum termo proibido. */
function filtroAssunto(texto: string, setor: string[], proibidos: string[]): { ok: boolean; motivo?: string } {
  const t = ` ${normalizar(texto).replace(/[^a-z0-9&-]+/g, ' ')} `
  const proibido = proibidos.find((p) => t.includes(` ${normalizar(p)}`))
  if (proibido) return { ok: false, motivo: `assunto fora do setor (${proibido})` }
  if (!setor.some((s) => t.includes(` ${normalizar(s)}`))) return { ok: false, motivo: 'sem termo do setor gráfico' }
  return { ok: true }
}

function slugBlog(titulo: string): string {
  const s = normalizar(titulo).replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '')
  if (s.length <= 80) return s
  const corte = s.slice(0, 81)
  return corte.slice(0, corte.lastIndexOf('-') > 20 ? corte.lastIndexOf('-') : 80)
}

function promptPost(p: { titulo: string; resumo: string; fonte: string }, categorias: CategoriaLoja[]): string {
  return [
    'Você escreve para o blog da Sua Gráfica BH, gráfica de Belo Horizonte que vende impressos (cartões de visita, panfletos, adesivos, banners, embalagens, brindes e muito mais) pelo site e pelo WhatsApp.',
    'Leia a notícia abaixo, que é só a PAUTA. Responda SOMENTE em JSON com as chaves:',
    '{"relevancia": 0-10, "motivo": "curto", "titulo": "...", "resumo": "...", "corpo": "...", "categorias": ["slug", ...]}',
    'relevancia: quanto o assunto interessa a donos de pequenos negócios que compram impressos, embalagens e comunicação visual (10 = muito). Política, economia geral, esporte, crime, programas sociais e fofoca = 0.',
    'Regras do texto (só se relevancia >= 7; senão devolva os textos vazios):',
    '- Escreva com SUAS palavras em português do Brasil, tom simples e próximo. Nunca copie frases da fonte.',
    '- titulo: até 90 caracteres, sem clickbait. resumo: 1 ou 2 frases, até 220 caracteres.',
    '- corpo: 4 a 6 parágrafos curtos em markdown simples (pode usar "## " para 1 ou 2 subtítulos e "- " para listas). Explique a notícia e depois dê dicas práticas de como um pequeno negócio pode aproveitar a ideia com materiais impressos.',
    '- Cite a fonte no texto de forma natural (ex.: "segundo a ' + p.fonte + '").',
    '- Quando falar de um tipo de produto da lista abaixo, marque assim: [[slug|texto do link]]. Use no máximo 4 marcações e só slugs da lista. Não escreva nenhum endereço de site.',
    '- Nunca fale de preço, prazo, desconto, frete ou promoção. Não invente dados nem números que não estejam na pauta.',
    '- Não use travessão. Não use emoji.',
    '- categorias: 2 a 4 slugs da lista que combinam com o texto.',
    '',
    'Categorias da loja (slug: nome):',
    categorias.map((c) => `${c.slug}: ${c.nome}`).join('\n'),
    '',
    `PAUTA (fonte: ${p.fonte})`,
    `Título: ${p.titulo}`,
    `Resumo: ${p.resumo.slice(0, 1500)}`,
  ].join('\n')
}

/** Trechos de 10 palavras seguidas iguais à fonte indicam cópia. */
function pareceCopia(texto: string, fonte: string, n = 10): boolean {
  const palavras = (s: string) => normalizar(s).replace(/[^a-z0-9 ]+/g, ' ').split(/\s+/).filter(Boolean)
  const f = palavras(fonte)
  if (f.length < n) return false
  const trechos = new Set<string>()
  for (let i = 0; i + n <= f.length; i++) trechos.add(f.slice(i, i + n).join(' '))
  const t = palavras(texto)
  for (let i = 0; i + n <= t.length; i++) if (trechos.has(t.slice(i, i + n).join(' '))) return true
  return false
}

function semTravessao(s: string): string {
  return s.replace(/\s*[—–]\s*/g, ', ').replace(/,\s*,/g, ',')
}

/** Confere o JSON do modelo e devolve o post pronto (links internos montados aqui) ou o motivo da recusa. */
function validarPost(
  bruto: unknown,
  o: { categorias: CategoriaLoja[]; fonteNome: string; fonteResumo: string; bloqueados: string[]; relevanciaMinima: number },
): { ok: true; post: PostGerado } | { ok: false; motivo: string; relevancia?: number } {
  const r = (bruto ?? {}) as Record<string, unknown>
  const relevancia = Number(r.relevancia)
  if (!Number.isFinite(relevancia)) return { ok: false, motivo: 'resposta do modelo ilegível' }
  if (relevancia < o.relevanciaMinima) return { ok: false, motivo: `pouco relevante (${relevancia}): ${String(r.motivo ?? '').slice(0, 120)}`, relevancia }
  const titulo = semTravessao(String(r.titulo ?? '').trim())
  const resumo = semTravessao(String(r.resumo ?? '').trim())
  let corpo = semTravessao(String(r.corpo ?? '').replace(/\r/g, '').trim())
  if (titulo.length < 15 || titulo.length > 110) return { ok: false, motivo: 'título fora do tamanho', relevancia }
  if (resumo.length < 40 || resumo.length > 300) return { ok: false, motivo: 'resumo fora do tamanho', relevancia }
  if (/https?:\/\/|www\./i.test(corpo + resumo + titulo)) return { ok: false, motivo: 'texto com endereço de site', relevancia }
  const mapa = new Map(o.categorias.map((c) => [c.slug, c.nome]))
  corpo = corpo.replace(/\[\[([a-z0-9-]+)\|([^\]]{1,80})\]\]/g, (_m, slug: string, txt: string) => (mapa.has(slug) ? `[${txt.trim()}](/categoria/${slug})` : txt.trim()))
  corpo = corpo.replace(/\[\[|\]\]/g, '')
  const paragrafos = corpo.split(/\n{2,}/).filter((p) => p.trim() && !p.trim().startsWith('## '))
  if (paragrafos.length < 3 || corpo.length < 700) return { ok: false, motivo: 'texto curto demais', relevancia }
  if (corpo.length > 7000) return { ok: false, motivo: 'texto longo demais', relevancia }
  if (!normalizar(corpo).includes(normalizar(o.fonteNome))) return { ok: false, motivo: 'texto sem crédito à fonte', relevancia }
  const tudo = normalizar(`${titulo} ${resumo} ${corpo}`)
  const bloqueado = o.bloqueados.find((b) => b && tudo.includes(normalizar(b)))
  if (bloqueado) return { ok: false, motivo: 'termo bloqueado no texto', relevancia }
  if (/\bR\$\s*\d|\bdesconto\b|\bpromo[cç][aã]o\b/i.test(corpo)) return { ok: false, motivo: 'texto fala de preço ou promoção', relevancia }
  if (pareceCopia(corpo, o.fonteResumo)) return { ok: false, motivo: 'trecho copiado da fonte', relevancia }
  const cats = [...new Set((Array.isArray(r.categorias) ? r.categorias : []).map(String))].filter((s) => mapa.has(s)).slice(0, 4)
  if (!cats.length) return { ok: false, motivo: 'sem categoria da loja relacionada', relevancia }
  return { ok: true, post: { titulo, resumo, corpo, relevancia, categorias: cats.map((slug) => ({ slug, nome: mapa.get(slug)! })) } }
}

// E-commerce Fase 8: blog automático. Lê os feeds do setor (e a NewsAPI, se ligada), filtra o assunto, pede ao Gemini
// um texto próprio a partir da pauta, confere (relevância, tamanho, crédito à fonte, sem cópia, sem preço, links só internos)
// e publica sozinho até o limite diário. Chamada pelo agendamento (x-cron-secret) ou pelo dono/service role.
// Logs só com contagens.
interface Config {
  ligado?: boolean; posts_por_dia?: number; avaliacoes_por_rodada?: number; relevancia_minima?: number; modelo?: string; newsapi?: boolean
  termos_setor?: string[]; termos_proibidos?: string[]; termos_bloqueados?: string[]
}
interface Fonte { id: number; nome: string; url: string; tipo: 'rss' | 'newsapi' }

const UA = 'SuaGraficaBH-Blog/1.0 (+https://suagraficabh.com.br/blog)'
const DIAS_PAUTA = 10

async function buscarTexto(url: string, ms = 12000): Promise<string> {
  const ctl = new AbortController()
  const t = setTimeout(() => ctl.abort(), ms)
  try {
    const res = await fetch(url, { headers: { 'User-Agent': UA, Accept: 'application/rss+xml, application/atom+xml, application/xml, text/xml, */*' }, redirect: 'follow', signal: ctl.signal })
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    return await res.text()
  } finally {
    clearTimeout(t)
  }
}

async function gemini(prompt: string, modelo: string, chave: string): Promise<unknown> {
  for (const m of [...new Set([modelo, 'gemini-2.0-flash'])]) {
    const ctl = new AbortController()
    const t = setTimeout(() => ctl.abort(), 45000)
    try {
      const res = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${m}:generateContent?key=${chave}`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, signal: ctl.signal,
        body: JSON.stringify({ contents: [{ parts: [{ text: prompt }] }], generationConfig: { responseMimeType: 'application/json', temperature: 0.6 } }),
      })
      if (res.status === 404) continue // modelo indisponível: tenta o reserva
      if (!res.ok) throw new Error(`Gemini ${res.status}`)
      const j = await res.json()
      return JSON.parse(j?.candidates?.[0]?.content?.parts?.[0]?.text ?? '{}')
    } finally {
      clearTimeout(t)
    }
  }
  throw new Error('modelo indisponível')
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)
  const db = serviceClient()
  const cron = Deno.env.get('CRON_SECRET')
  const enviado = req.headers.get('x-cron-secret')
  const doCron = !!cron && !!enviado && enviado.length === cron.length && enviado === cron
  if (!doCron && !(await requireOwnerOrServer(req, db))) return json({ error: 'Não autorizado.' }, 401)

  const { data: cfgRow } = await db.from('app_settings').select('value').eq('key', 'blog').maybeSingle()
  const cfg = (cfgRow?.value ?? {}) as Config
  if (cfg.ligado === false) return json({ ok: true, desligado: true })
  const setor = cfg.termos_setor ?? []
  const proibidos = cfg.termos_proibidos ?? []
  const resumo = { lidas: 0, novas: 0, descartadas_filtro: 0, avaliadas: 0, publicadas: 0, recusadas: 0, erros_fonte: 0 }

  // 1) Pautas: feeds RSS e, se ligada, NewsAPI
  const { data: fontes } = await db.from('blog_fontes').select('id, nome, url, tipo').eq('ativo', true)
  const limite = Date.now() - DIAS_PAUTA * 86400000
  await Promise.all(((fontes ?? []) as Fonte[]).map(async (f) => {
    let itens: (ItemFeed & { fonte: string })[] = []
    try {
      if (f.tipo === 'newsapi') {
        const chave = Deno.env.get('NEWSAPI_KEY')
        if (!cfg.newsapi || !chave) return
        const q = '("impressão gráfica" OR "embalagens personalizadas" OR "comunicação visual" OR "papelaria corporativa" OR "identidade visual" OR "brindes corporativos" OR "materiais promocionais" OR "marketing impresso")'
        const u = `${f.url}?q=${encodeURIComponent(q)}&language=pt&sortBy=publishedAt&pageSize=30`
        const res = await fetch(u, { headers: { 'X-Api-Key': chave, 'User-Agent': UA } })
        if (!res.ok) throw new Error(`HTTP ${res.status}`)
        itens = itensNewsApi(await res.json())
      } else {
        itens = lerFeed(await buscarTexto(f.url)).map((i) => ({ ...i, fonte: f.nome }))
      }
      await db.from('blog_fontes').update({ ultima_leitura: new Date().toISOString(), ultimo_erro: null }).eq('id', f.id)
    } catch (e) {
      resumo.erros_fonte++
      await db.from('blog_fontes').update({ ultima_leitura: new Date().toISOString(), ultimo_erro: String((e as Error).message).slice(0, 200) }).eq('id', f.id)
      return
    }
    const recentes = itens.filter((i) => !i.data || Date.parse(i.data) >= limite)
    resumo.lidas += recentes.length
    if (!recentes.length) return
    const linhas = recentes.map((i) => {
      const fil = filtroAssunto(`${i.titulo} ${i.resumo}`, setor, proibidos)
      if (!fil.ok) resumo.descartadas_filtro++
      return { url: i.url, titulo: i.titulo, resumo_fonte: i.resumo, fonte_nome: i.fonte, publicada_na_fonte: i.data,
               status: fil.ok ? 'nova' : 'descartada', motivo: fil.ok ? null : fil.motivo }
    })
    const { data: ins } = await db.from('blog_pautas').upsert(linhas, { onConflict: 'url', ignoreDuplicates: true }).select('id')
    resumo.novas += ins?.length ?? 0
  }))
  await db.from('blog_pautas').update({ status: 'descartada', motivo: 'pauta antiga' }).eq('status', 'nova')
    .lt('publicada_na_fonte', new Date(limite).toISOString())

  // 2) Escrita: até o limite do dia (dia de BH)
  const chave = Deno.env.get('GEMINI_API_KEY')
  if (!chave) return json({ ok: true, ...resumo, aviso: 'GEMINI_API_KEY ausente: pautas guardadas, nada escrito.' })
  const hojeBH = new Date(Date.now() - 3 * 3600000).toISOString().slice(0, 10)
  const { count } = await db.from('blog_posts').select('id', { count: 'exact', head: true }).gte('publicado_em', `${hojeBH}T03:00:00Z`)
  let restante = Math.max(0, (cfg.posts_por_dia ?? 3) - (count ?? 0))
  if (!restante) return json({ ok: true, ...resumo, limite_do_dia: true })

  const { data: pautas } = await db.from('blog_pautas').select('id, url, titulo, resumo_fonte, fonte_nome, tentativas').eq('status', 'nova')
    .order('publicada_na_fonte', { ascending: false, nullsFirst: false }).limit(Math.min(cfg.avaliacoes_por_rodada ?? 4, 8))
  if (!pautas?.length) return json({ ok: true, ...resumo })

  const { data: cats } = await db.rpc('loja_categorias')
  const categorias = ((cats ?? []) as { slug: string; nome: string }[]).map((c) => ({ slug: c.slug, nome: c.nome })) as CategoriaLoja[]
  const { data: fotosCfg } = await db.from('app_settings').select('value').eq('key', 'fotos').maybeSingle()
  const bloqueados = [...(cfg.termos_bloqueados ?? [])]
  try {
    const host = new URL(String((fotosCfg?.value as { origem_base?: string } | null)?.origem_base ?? '')).hostname.replace(/^www\./, '').split('.')[0]
    if (host && host.length > 3) bloqueados.push(host)
  } catch { /* sem origem configurada */ }

  for (const p of pautas) {
    if (!restante) break
    resumo.avaliadas++
    let saida: unknown
    try {
      saida = await gemini(promptPost({ titulo: p.titulo, resumo: p.resumo_fonte ?? '', fonte: p.fonte_nome }, categorias), cfg.modelo ?? 'gemini-2.5-flash', chave)
    } catch (e) {
      const t = (p.tentativas ?? 0) + 1
      await db.from('blog_pautas').update({ tentativas: t, status: t >= 3 ? 'erro' : 'nova', motivo: String((e as Error).message).slice(0, 200), atualizado_em: new Date().toISOString() }).eq('id', p.id)
      continue
    }
    const v = validarPost(saida, { categorias, fonteNome: p.fonte_nome, fonteResumo: `${p.titulo} ${p.resumo_fonte ?? ''}`, bloqueados, relevanciaMinima: cfg.relevancia_minima ?? 7 })
    if (!v.ok) {
      resumo.recusadas++
      await db.from('blog_pautas').update({ status: 'descartada', motivo: v.motivo, relevancia: v.relevancia ?? null, tentativas: (p.tentativas ?? 0) + 1, atualizado_em: new Date().toISOString() }).eq('id', p.id)
      continue
    }
    let slug = slugBlog(v.post.titulo) || `post-${p.id}`
    const { data: existe } = await db.from('blog_posts').select('id').eq('slug', slug).maybeSingle()
    if (existe) slug = `${slug.slice(0, 72)}-${p.id}`
    const { error } = await db.from('blog_posts').insert({ slug, titulo: v.post.titulo, resumo: v.post.resumo, corpo: v.post.corpo, categorias: v.post.categorias,
      fonte_nome: p.fonte_nome, fonte_url: p.url, pauta_id: p.id })
    if (error) {
      await db.from('blog_pautas').update({ status: 'erro', motivo: 'falha ao gravar o post', atualizado_em: new Date().toISOString() }).eq('id', p.id)
      continue
    }
    await db.from('blog_pautas').update({ status: 'publicada', relevancia: v.post.relevancia, tentativas: (p.tentativas ?? 0) + 1, motivo: null, atualizado_em: new Date().toISOString() }).eq('id', p.id)
    resumo.publicadas++
    restante--
  }
  console.log(`blog-pautas: ${JSON.stringify(resumo)}`)
  return json({ ok: true, ...resumo })
})
