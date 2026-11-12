// Consulta ao vivo da página do produto na origem, usando um Chrome REAL já logado (perfil persistente) por CDP.
// O endereço da origem vem só de ORIGEM_BASE (variável de ambiente). Nada de nome de fornecedor neste arquivo.
// API (cabeçalho Authorization: Bearer <API_TOKEN>):
//   GET  /saude                -> { ok, navegador, logado, ultima_checagem }
//   POST /consultar {caminho}  -> dados lidos da página (preços, medidas, prazo, tabelas, texto) com cache de 6 h
// Guarda de sessão: a cada 4 min abre a página inicial; se perder o login, avisa o banco (RPC origem_sessao_registrar), que alerta o dono.
import http from 'node:http'
import dns from 'node:dns/promises'
import { chromium } from 'playwright-core'

const BASE = (process.env.ORIGEM_BASE ?? '').replace(/\/+$/, '')
const TOKEN = process.env.API_TOKEN ?? ''
const CDP_HOST = process.env.CDP_HOST ?? '127.0.0.1'
// O Chrome só aceita Host com IP ou localhost no CDP: resolve o nome do contêiner para IP.
const cdpUrl = async () => `http://${(await dns.lookup(CDP_HOST, { family: 4 })).address}:9222`
const PORTA = Number(process.env.PORTA ?? 3100)
const SB_URL = (process.env.SUPABASE_URL ?? '').replace(/\/+$/, '')
const SB_KEY = process.env.SUPABASE_PUBLISHABLE_KEY ?? ''
const SB_TOKEN = process.env.ORIGEM_SESSAO_TOKEN ?? ''
const CACHE_MS = 6 * 3600 * 1000
const MARCADORES_LOGADO = new RegExp(process.env.MARCADOR_LOGADO ?? '(sair|logout|minha conta|meus pedidos)', 'i')
const MARCADORES_LOGIN = new RegExp(process.env.MARCADOR_LOGIN ?? '(esqueci (minha )?senha|entrar na sua conta|fa[cç]a (seu )?login)', 'i')
if (!BASE || !TOKEN) { console.error('Faltam ORIGEM_BASE e API_TOKEN.'); process.exit(1) }

let browser = null
let estado = { logado: null, ultima_checagem: null, motivo: null }
const cache = new Map()
let fila = Promise.resolve()
const espera = (ms) => new Promise((r) => setTimeout(r, ms))

async function conectar() {
  if (browser?.isConnected()) return browser
  browser = await chromium.connectOverCDP(await cdpUrl())
  return browser
}
async function aba() {
  const b = await conectar()
  const ctx = b.contexts()[0] ?? (await b.newContext())
  return ctx.newPage()
}
const serial = (fn) => { const p = fila.then(fn, fn); fila = p.then(() => espera(2000), () => espera(2000)); return p }

async function lerPagina(page) {
  return page.evaluate(() => {
    const t = (document.querySelector('main') ?? document.body).innerText.replace(/\n{3,}/g, '\n\n').trim()
    const tabelas = [...document.querySelectorAll('table')].slice(0, 8).map((tb) => tb.innerText.replace(/\s+\n/g, '\n').trim().slice(0, 1500))
    return { titulo: document.title, h1: document.querySelector('h1')?.innerText ?? null, texto: t.slice(0, 8000), tabelas, corpo_completo: document.body.innerText.slice(0, 20000) }
  })
}
function extrair(d) {
  const t = d.corpo_completo
  const num = '\\d+(?:[.,]\\d+)?'
  const medidas = [...new Set([...t.matchAll(new RegExp(`${num}\\s*[xX×]\\s*${num}(?:\\s*[xX×]\\s*${num})?\\s*(?:mm|cm)?`, 'g'))].map((m) => m[0].trim()))].slice(0, 30)
  const lpa = [...new Set([...t.matchAll(/L\s*[:=]?\s*\d+[\s,.]*(?:x|×)?\s*P\s*[:=]?\s*\d+[\s,.]*(?:x|×)?\s*A\s*[:=]?\s*\d+(?:\s*(?:mm|cm))?/gi)].map((m) => m[0]))]
  const precos = [...new Set([...t.matchAll(/R\$\s*\d{1,3}(?:\.\d{3})*,\d{2}/g)].map((m) => m[0]))].slice(0, 40)
  const prazo = [...t.matchAll(/(\d+)\s*dias?\s*[úu]teis?/gi)].map((m) => Number(m[1])).slice(0, 10)
  return { medidas, largura_profundidade_altura: lpa, precos, prazo_dias_uteis: prazo }
}
function sessao(d, urlFinal) {
  const loginUrl = /login|entrar|auth/i.test(new URL(urlFinal).pathname)
  const logado = !loginUrl && !MARCADORES_LOGIN.test(d.corpo_completo) && MARCADORES_LOGADO.test(d.corpo_completo)
  return { logado, loginUrl }
}

async function avisarBanco(logado, motivo) {
  if (!SB_URL || !SB_KEY || !SB_TOKEN) return
  try {
    await fetch(`${SB_URL}/rest/v1/rpc/origem_sessao_registrar`, { method: 'POST', headers: { apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ p_token: SB_TOKEN, p_logado: logado, p_motivo: motivo }) })
  } catch (e) { console.error('Falha ao avisar o banco:', e.message) }
}

async function checarSessao() {
  return serial(async () => {
    let page
    try {
      page = await aba()
      await page.goto(BASE + '/', { waitUntil: 'domcontentloaded', timeout: 30000 })
      await page.waitForTimeout(2500)
      const d = await lerPagina(page)
      const s = sessao(d, page.url())
      const mudou = estado.logado !== s.logado
      estado = { logado: s.logado, ultima_checagem: new Date().toISOString(), motivo: s.logado ? null : (s.loginUrl ? 'redirecionado_para_login' : 'sem_marcador_de_conta') }
      if (mudou || !s.logado) await avisarBanco(s.logado, estado.motivo)
      return estado
    } catch (e) {
      estado = { logado: false, ultima_checagem: new Date().toISOString(), motivo: `erro: ${String(e.message).slice(0, 120)}` }
      browser = null
      await avisarBanco(false, estado.motivo)
      return estado
    } finally { try { await page?.close() } catch { /* ignora */ } }
  })
}

async function consultar(caminho) {
  if (!/^\/[A-Za-z0-9\-_/.%]+$/.test(caminho) || caminho.includes('..')) throw Object.assign(new Error('caminho inválido'), { status: 400 })
  const hit = cache.get(caminho)
  if (hit && Date.now() - hit.em < CACHE_MS) return { ...hit.dados, cache: true }
  return serial(async () => {
    const page = await aba()
    try {
      await page.goto(BASE + caminho, { waitUntil: 'domcontentloaded', timeout: 30000 })
      await page.waitForTimeout(3000)
      const d = await lerPagina(page)
      const s = sessao(d, page.url())
      if (!s.logado) { estado = { ...estado, logado: false, motivo: 'sessao_expirada_na_consulta' }; await avisarBanco(false, estado.motivo); throw Object.assign(new Error('sessao_expirada'), { status: 409 }) }
      const dados = { caminho, consultado_em: new Date().toISOString(), titulo: d.titulo, h1: d.h1, ...extrair(d), tabelas: d.tabelas, texto: d.texto, cache: false }
      cache.set(caminho, { em: Date.now(), dados })
      return dados
    } finally { try { await page.close() } catch { /* ignora */ } }
  })
}

const srv = http.createServer(async (req, res) => {
  const out = (st, o) => { res.writeHead(st, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(o)) }
  if ((req.headers.authorization ?? '') !== `Bearer ${TOKEN}`) return out(401, { error: 'Não autorizado.' })
  try {
    if (req.method === 'GET' && req.url === '/saude') {
      let nav = false
      try { await conectar(); nav = true } catch { nav = false }
      return out(200, { ok: nav, navegador: nav, ...estado })
    }
    if (req.method === 'POST' && req.url === '/consultar') {
      let corpo = ''; for await (const c of req) { corpo += c; if (corpo.length > 5000) break }
      const { caminho } = JSON.parse(corpo || '{}')
      return out(200, { ok: true, ...(await consultar(String(caminho ?? ''))) })
    }
    return out(404, { error: 'Rota inexistente.' })
  } catch (e) { return out(e.status ?? 502, { ok: false, error: String(e.message ?? e).slice(0, 200) }) }
})
srv.listen(PORTA, () => console.log(`consulta-origem na porta ${PORTA}`))
setTimeout(checarSessao, 20000)
setInterval(checarSessao, 4 * 60 * 1000)
