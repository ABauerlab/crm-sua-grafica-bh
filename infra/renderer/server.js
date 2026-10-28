// Leitor de páginas com JavaScript (Playwright) para o workflow de pesquisa de preço.
// Rede interna do Coolify apenas: não publique a porta. Token opcional em RENDERER_TOKEN (cabeçalho x-token).
// POST /render { url, timeout_ms } -> { texto, status, url_final }
const http = require('http')
const { chromium } = require('playwright')

const PORTA = Number(process.env.PORT || 3000)
const TOKEN = process.env.RENDERER_TOKEN || ''
const UA = process.env.RENDERER_UA || 'GBH-PrecoBot/1.0 (+https://crm.suagraficabh.com.br)'
const MAX_CONCORRENTES = Number(process.env.MAX_CONCORRENTES || 2)
let navegador = null
let emUso = 0

async function obterNavegador() {
  if (!navegador || !navegador.isConnected()) navegador = await chromium.launch({ args: ['--no-sandbox'] })
  return navegador
}

function proibido(url) {
  // só http(s) público; nada de rede interna
  try {
    const u = new URL(url)
    if (!/^https?:$/.test(u.protocol)) return true
    return /^(localhost|127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|169\.254\.)/i.test(u.hostname)
  } catch {
    return true
  }
}

async function renderizar(url, timeoutMs) {
  const b = await obterNavegador()
  const ctx = await b.newContext({ userAgent: UA, locale: 'pt-BR', viewport: { width: 1280, height: 900 } })
  const pagina = await ctx.newPage()
  try {
    // economia: não baixa imagem, fonte nem mídia
    await pagina.route('**/*', (r) => (['image', 'font', 'media'].includes(r.request().resourceType()) ? r.abort() : r.continue()))
    const resp = await pagina.goto(url, { waitUntil: 'networkidle', timeout: timeoutMs }).catch(() => null)
    const texto = await pagina.evaluate(() => document.body.innerText).catch(() => '')
    return { texto: texto.slice(0, 60000), status: resp ? resp.status() : 0, url_final: pagina.url() }
  } finally {
    await ctx.close()
  }
}

http
  .createServer(async (req, res) => {
    const responder = (codigo, corpo) => {
      res.writeHead(codigo, { 'content-type': 'application/json' })
      res.end(JSON.stringify(corpo))
    }
    if (req.method === 'GET' && req.url === '/saude') return responder(200, { ok: true })
    if (req.method !== 'POST' || req.url !== '/render') return responder(404, { erro: 'rota inexistente' })
    if (TOKEN && req.headers['x-token'] !== TOKEN) return responder(401, { erro: 'não autorizado' })
    let corpo = ''
    req.on('data', (c) => { corpo += c; if (corpo.length > 10000) req.destroy() })
    req.on('end', async () => {
      let entrada
      try { entrada = JSON.parse(corpo) } catch { return responder(400, { erro: 'JSON inválido' }) }
      if (!entrada.url || proibido(entrada.url)) return responder(400, { erro: 'URL não permitida' })
      if (emUso >= MAX_CONCORRENTES) return responder(429, { erro: 'ocupado' })
      emUso++
      try {
        const t = Math.min(Math.max(Number(entrada.timeout_ms) || 20000, 3000), 30000)
        responder(200, await renderizar(entrada.url, t))
      } catch (e) {
        responder(502, { erro: 'falha ao renderizar' })
      } finally {
        emUso--
      }
    })
  })
  .listen(PORTA, () => console.log('renderer na porta ' + PORTA))
