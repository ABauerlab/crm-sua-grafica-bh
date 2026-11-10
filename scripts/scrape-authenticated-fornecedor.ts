// Extração autenticada da área logada do fornecedor (acabamentos opcionais com custo e gabaritos). Manual, NÃO faz parte do npm test.
// O endereço e a marca do fornecedor NUNCA ficam no repositório: tudo vem de variáveis de ambiente (veja o uso abaixo).
//
// Preparo (uma vez):  npm i --no-save playwright sharp && npx playwright install chromium
//
// MODO RECOMENDADO (Cloudflare bloqueia o navegador aberto por automação): use o SEU Chrome de verdade, com porta de depuração.
//    a) Feche todas as janelas do Chrome e abra um Chrome só para isto (PowerShell):
//       & "C:\Program Files\Google\Chrome\Application\chrome.exe" --remote-debugging-port=9222 --user-data-dir="$env:USERPROFILE\chrome-scrape"
//    b) Nesse Chrome, entre no site do fornecedor normalmente (e-mail completo, senha, verificação) e deixe a conta logada.
//    c) Em outro terminal: $env:ORIGEM_CDP="http://127.0.0.1:9222" e rode "extrair" (o script usa essa janela já logada).
// 1) Login por automação (pode ser barrado pelo Cloudflare; navegador visível; você digita login, senha e resolve o CAPTCHA; a sessão fica em storageState.json, que é ignorado pelo git):
//    ORIGEM_BASE=https://... node scripts/scrape-authenticated-fornecedor.ts login
// 2) Extração em lote (usa a sessão salva; 1 página a cada 2-3 s; retoma de onde parou):
//    ORIGEM_BASE=https://... ORIGEM_MARCA="termo1,termo2" SUPABASE_URL=https://xxxx.supabase.co SUPABASE_SERVICE_ROLE_KEY=... \
//      node scripts/scrape-authenticated-fornecedor.ts extrair [--limite 50] [--dry-run]
//
// O que faz: para cada produto já mapeado em `loja_fichas` (coluna `caminho`), abre a página logada e lê
//  - acabamentos extras e o CUSTO de fábrica (grava em `acabamentos_extras`; a venda sai no banco como 3x o custo, terminando em ,90);
//  - links de gabaritos (PDF, CDR, AI): baixa, confere menção à marca e guarda no bucket PRIVADO `produto-fotos`.
// Fotos baixadas passam por redimensionamento + nitidez (sharp), JPEG até 300 KB.
// Gabarito com a marca do fornecedor vai para `gabaritos-revisar/` e NÃO é publicado: arquivos CDR/AI/PDF não dá para limpar com segurança
// por código, então a limpeza (retirar logotipo) é manual. Só o que passa na conferência vai para `gabaritos/`.
// Selectores são heurísticos (não conheço o HTML logado): use --dry-run para ver o que foi lido e o HTML de amostra em ./scrape-debug/.
import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'

const BASE = (process.env.ORIGEM_BASE ?? '').replace(/\/+$/, '')
const LOGIN_PATH = process.env.ORIGEM_LOGIN_PATH ?? '/login'
const MARCAS = (process.env.ORIGEM_MARCA ?? '').split(',').map((s) => s.trim().toLowerCase()).filter(Boolean)
const CDP = process.env.ORIGEM_CDP ?? ''
const SESSAO = 'storageState.json'
const PROGRESSO = 'scrape-progresso.json'
const modo = process.argv[2]
const args = process.argv.slice(3)
const dry = args.includes('--dry-run')
const limite = Number(args[args.indexOf('--limite') + 1]) || Infinity
const espera = () => new Promise((r) => setTimeout(r, 2000 + Math.random() * 1000))

if (!BASE || !['login', 'extrair'].includes(modo ?? '')) {
  console.error('Uso: ORIGEM_BASE=https://... node scripts/scrape-authenticated-fornecedor.ts login|extrair [--limite N] [--dry-run]')
  process.exit(1)
}

async function carregar<T>(nome: string): Promise<T> {
  try { return (await import(nome)) as T } catch { console.error(`Falta o pacote "${nome}". Rode: npm i --no-save playwright sharp`); process.exit(1) }
}
const { chromium } = await carregar<typeof import('playwright')>('playwright')

if (modo === 'login' && CDP) {
  console.log('Com ORIGEM_CDP não precisa de "login": entre no site no Chrome aberto com a porta 9222 e rode "extrair".')
  process.exit(0)
}
if (modo === 'login') {
  const browser = await chromium.launch({ headless: false, channel: 'chrome' }).catch(() => chromium.launch({ headless: false }))
  const ctx = await browser.newContext()
  const page = await ctx.newPage()
  await page.goto(BASE + LOGIN_PATH)
  console.log('Faça o login no navegador (inclusive o CAPTCHA). Detecto sozinho quando a página de login some; limite de 10 minutos.')
  try {
    await page.waitForURL((u) => !u.pathname.toLowerCase().includes(LOGIN_PATH.replace('/', '').toLowerCase()), { timeout: 10 * 60_000 })
  } catch {
    console.error('Tempo esgotado sem login concluído. Nada foi salvo.'); await browser.close(); process.exit(1)
  }
  await page.waitForLoadState('networkidle').catch(() => {})
  await ctx.storageState({ path: SESSAO })
  console.log(`Sessão salva em ${SESSAO} (não envie este arquivo a ninguém e não faça commit).`)
  await browser.close()
  process.exit(0)
}

// ---------- extração ----------
if (!CDP && !existsSync(SESSAO)) { console.error(`Sem ${SESSAO}. Use ORIGEM_CDP (recomendado) ou rode o modo "login".`); process.exit(1) }
const SB = (process.env.SUPABASE_URL ?? '').replace(/\/+$/, '')
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY ?? ''
if (!dry && (!SB || !KEY)) { console.error('Informe SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY (ou use --dry-run).'); process.exit(1) }
const sbHeaders = { apikey: KEY, Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json' }
const sharp = (await carregar<{ default: typeof import('sharp') }>('sharp')).default

/** Preço no formato brasileiro: "R$ 1.234,56" ou "+ R$ 12,00". */
function lerPreco(t: string): number | null {
  const m = /R\$\s*([\d.]+,\d{2})/.exec(t)
  return m ? Number(m[1].replace(/\./g, '').replace(',', '.')) : null
}
const temMarca = (t: string) => MARCAS.some((m) => t.toLowerCase().includes(m))

async function sb<T>(path: string, init?: RequestInit): Promise<T> {
  const r = await fetch(`${SB}${path}`, { ...init, headers: { ...sbHeaders, ...(init?.headers ?? {}) } })
  if (!r.ok) throw new Error(`Supabase ${r.status}: ${(await r.text()).slice(0, 200)}`)
  return (r.status === 204 ? null : await r.json()) as T
}

/** Nitidez e tamanho: lado maior até 1600 px, nitidez leve, JPEG; reduz a qualidade até caber em 300 KB. */
async function tratarImagem(buf: Buffer): Promise<Buffer> {
  for (const q of [85, 75, 65, 55]) {
    const out = await sharp(buf).rotate().resize({ width: 1600, height: 1600, fit: 'inside', withoutEnlargement: true }).sharpen({ sigma: 1 }).jpeg({ quality: q, mozjpeg: true }).toBuffer()
    if (out.length <= 300 * 1024) return out
  }
  return sharp(buf).resize({ width: 1200, height: 1200, fit: 'inside' }).sharpen().jpeg({ quality: 50 }).toBuffer()
}

async function enviar(caminho: string, corpo: Buffer, tipo: string) {
  if (dry) return
  const r = await fetch(`${SB}/storage/v1/object/produto-fotos/${caminho}`, { method: 'POST', headers: { apikey: KEY, Authorization: `Bearer ${KEY}`, 'Content-Type': tipo, 'x-upsert': 'true' }, body: corpo })
  if (!r.ok) throw new Error(`Storage ${r.status}: ${(await r.text()).slice(0, 160)}`)
}

const progresso: { feitos: string[]; gabaritos: { produto: string; arquivo: string; tipo: string; revisar: boolean }[] } =
  existsSync(PROGRESSO) ? JSON.parse(readFileSync(PROGRESSO, 'utf8')) : { feitos: [], gabaritos: [] }

const fila = await (dry && !SB ? Promise.resolve([] as { chave: string; caminho: string }[]) : sb<{ chave: string; caminho: string }[]>('/rest/v1/loja_fichas?select=chave,caminho&order=chave&limit=5000'))
const pendentes = fila.filter((f) => !progresso.feitos.includes(f.chave)).slice(0, limite)
console.log(`${fila.length} produtos mapeados, ${pendentes.length} nesta rodada${dry ? ' (dry-run: nada é gravado)' : ''}`)

// Com ORIGEM_CDP, usa o Chrome real já logado (Cloudflare não barra); senão, abre um Chromium com a sessão salva.
const browser = CDP ? await chromium.connectOverCDP(CDP) : await chromium.launch({ headless: true })
const ctx = CDP ? browser.contexts()[0] : await browser.newContext({ storageState: SESSAO })
if (!ctx) { console.error('Não achei janela no Chrome da porta 9222. Abra o Chrome com --remote-debugging-port=9222 e entre no site.'); process.exit(1) }
const page = await ctx.newPage()
mkdirSync('scrape-debug', { recursive: true })
let n = 0
for (const item of pendentes) {
  try {
    const resp = await page.goto(BASE + item.caminho, { waitUntil: 'domcontentloaded', timeout: 30_000 })
    await page.waitForLoadState('networkidle', { timeout: 10_000 }).catch(() => {})
    if (page.url().toLowerCase().includes(LOGIN_PATH.replace('/', '').toLowerCase())) { console.error('A sessão expirou. Rode "login" de novo.'); break }
    if (n === 0) writeFileSync('scrape-debug/amostra.html', await page.content())
    if (!resp || resp.status() >= 400) { console.warn(`${item.chave}: HTTP ${resp?.status()}`); continue }

    // Acabamentos: rótulos de opções (select, radio, checkbox) que trazem preço em R$
    const opcoes = await page.evaluate(() => {
      const out: { nome: string; texto: string }[] = []
      document.querySelectorAll('select option').forEach((o) => out.push({ nome: (o.textContent ?? '').trim(), texto: (o.textContent ?? '').trim() }))
      document.querySelectorAll('input[type=checkbox],input[type=radio]').forEach((i) => {
        const l = (i as HTMLInputElement).labels?.[0] ?? i.closest('label') ?? i.parentElement
        if (l) out.push({ nome: (l.textContent ?? '').trim(), texto: (l.textContent ?? '').trim() })
      })
      return out
    })
    const acabamentos = opcoes
      .map((o) => ({ nome: o.nome.replace(/\(?\+?\s*R\$\s*[\d.]+,\d{2}\)?/g, '').replace(/\s+/g, ' ').trim(), custo: lerPreco(o.texto) }))
      .filter((a): a is { nome: string; custo: number } => !!a.nome && a.custo !== null && a.custo > 0 && !temMarca(a.nome))

    // Gabaritos: links para PDF, CDR e AI
    const links = await page.evaluate(() => [...document.querySelectorAll('a[href]')].map((a) => (a as HTMLAnchorElement).href).filter((h) => /\.(pdf|cdr|ai)(\?|$)/i.test(h)))

    if (!dry && acabamentos.length) {
      const prod = await sb<{ categoria_slug: string }[]>(`/rest/v1/ecommerce_products?select=categoria_slug&produto_slug=eq.${encodeURIComponent(item.chave)}&limit=1`)
      const cat = prod[0]?.categoria_slug
      if (cat) await sb('/rest/v1/acabamentos_extras?on_conflict=categoria_slug,nome', { method: 'POST', headers: { Prefer: 'resolution=merge-duplicates,return=minimal' }, body: JSON.stringify(acabamentos.map((a) => ({ categoria_slug: cat, nome: a.nome, custo: a.custo, origem: 'scrape-logado' }))) })
    }
    for (const href of [...new Set(links)].slice(0, 6)) {
      const r = await ctx.request.get(href, { timeout: 60_000 })
      if (!r.ok()) continue
      const buf = Buffer.from(await r.body())
      const ext = (/\.(pdf|cdr|ai)(\?|$)/i.exec(href)?.[1] ?? 'bin').toLowerCase()
      // Confere a marca no conteúdo legível (PDF guarda texto em claro na maioria dos casos) e no nome do arquivo
      const revisar = temMarca(href) || temMarca(buf.toString('latin1'))
      const hash = createHash('sha256').update(buf).digest('hex').slice(0, 24)
      const caminho = `${revisar ? 'gabaritos-revisar' : 'gabaritos'}/${hash}.${ext}`
      await enviar(caminho, buf, ext === 'pdf' ? 'application/pdf' : 'application/octet-stream')
      progresso.gabaritos.push({ produto: item.chave, arquivo: caminho, tipo: ext, revisar })
    }
    // Imagens de gabarito/preview da página: nitidez antes de guardar
    const imgs = await page.evaluate(() => [...document.querySelectorAll('img[src]')].map((i) => (i as HTMLImageElement).src).filter((s) => /gabarit|template|molde/i.test(s)))
    for (const src of [...new Set(imgs)].slice(0, 3)) {
      const r = await ctx.request.get(src, { timeout: 30_000 })
      if (!r.ok()) continue
      const tratada = await tratarImagem(Buffer.from(await r.body()))
      await enviar(`gabaritos/${createHash('sha256').update(tratada).digest('hex').slice(0, 24)}.jpg`, tratada, 'image/jpeg')
    }
    console.log(`${item.chave}: ${acabamentos.length} acabamentos, ${links.length} gabaritos${dry && acabamentos.length ? ' ' + JSON.stringify(acabamentos.slice(0, 3)) : ''}`)
    progresso.feitos.push(item.chave)
    if (!dry && ++n % 10 === 0) writeFileSync(PROGRESSO, JSON.stringify(progresso, null, 1))
  } catch (e) {
    console.warn(`${item.chave}: ${(e as Error).message}`)
  }
  await espera()
}
if (!dry) writeFileSync(PROGRESSO, JSON.stringify(progresso, null, 1))
await page.close().catch(() => {})
await browser.close()
console.log(`Fim. Gabaritos para revisão manual (marca encontrada): ${progresso.gabaritos.filter((g) => g.revisar).length}`)
