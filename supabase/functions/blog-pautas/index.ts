// E-commerce Fase 8: blog automático. Lê os feeds do setor (e a NewsAPI, se ligada), filtra o assunto, pede ao Gemini
// um texto próprio a partir da pauta, confere (relevância, tamanho, crédito à fonte, sem cópia, sem preço, links só internos)
// e publica sozinho até o limite diário. Chamada pelo agendamento (x-cron-secret) ou pelo dono/service role.
// Logs só com contagens.
import { corsHeaders, json, requireOwnerOrServer, serviceClient } from '../_shared/http.ts'
import { type CategoriaLoja, filtroAssunto, type ItemFeed, itensNewsApi, lerFeed, promptPost, slugBlog, validarPost } from '../_shared/blog.ts'

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
