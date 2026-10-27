// Gera as capturas de tela em docs/telas com o Supabase simulado (nenhum dado real é usado).
// Uso: VITE_SUPABASE_URL=http://localhost:54321 VITE_SUPABASE_ANON_KEY=x npx vite --port 5199 &  node scripts/screenshots.cjs
const { chromium } = require('playwright')
const path = require('node:path')

const BASE = 'http://localhost:5199'
const OUT = path.join(__dirname, '..', 'docs', 'telas')
const ago = (h) => new Date(Date.now() - h * 3600_000).toISOString()

const contacts = [
  { id: 'c1', wa_id: '5531991110001', name: 'Marcos Barbearia' },
  { id: 'c2', wa_id: '5531991110002', name: 'Pizzaria Napoli' },
  { id: 'c3', wa_id: '5531991110003', name: 'Júlia Confeitaria' },
  { id: 'c4', wa_id: '5531991110004', name: 'Studio Fit BH' },
  { id: 'c5', wa_id: '5531991110005', name: 'Loja Bella Moda' },
  { id: 'c6', wa_id: '5531991110006', name: 'Auto Peças Minas' },
]
const base = (o) => ({
  id: o.id, number: o.number, contact_id: o.c.id, conversation_id: 'cv' + o.number, title: o.title, stage: o.stage, stage_entered_at: ago(o.h),
  notes: null, origin_ad_id: o.ad ? '1202' : null, origin_label: o.ad ?? null, origin_url: null, discount_pct: 0, tax_pct: 6, payment_fee_pct: 1.5,
  price_override_reason: null, payment_status: o.paid ? 'aprovado' : 'pendente', payment_method: o.paid ? 'pix' : null, payment_link: 'https://mpago.la/abc', payment_external_id: null,
  payment_confirmed_at: o.paid ? ago(20) : null, payment_manual: false, paid_at: o.paid ? ago(20) : null, art_mode: 'criamos', art_status: o.art ?? 'aguardando',
  art_approved_at: null, art_checklist: { alta_resolucao: true, medidas: true }, supplier_order_no: null, due_date: null, delivery_method: 'retirada', delivery_address: null,
  delivery_fee: null, delivery_tracking: null, delivered_at: null, created_at: ago(o.h + 30), updated_at: ago(1),
  contact: o.c, conversation: { id: 'cv' + o.number, ai_handled: !!o.ai, unread_count: o.unread ?? 0, last_inbound_at: ago(2) }, items: [{ description: o.title, qty: 1 }],
})
const orders = [
  base({ id: 'o1', number: 1041, c: contacts[0], title: 'Kit Barbearia', stage: 'novo', h: 1, ad: 'Kit Barbearia', unread: 2 }),
  base({ id: 'o2', number: 1042, c: contacts[1], title: '1.000 panfletos A5', stage: 'cotando', h: 12, ai: true }),
  base({ id: 'o3', number: 1043, c: contacts[2], title: '500 cartões de visita', stage: 'aguardando_pagamento', h: 30, ad: 'Cartões de visita BH' }),
  base({ id: 'o4', number: 1044, c: contacts[3], title: 'Banner 80x120', stage: 'pago', h: 3, paid: true, ai: true }),
  base({ id: 'o5', number: 1045, c: contacts[4], title: '200 adesivos redondos', stage: 'arte', h: 6, paid: true }),
  base({ id: 'o6', number: 1046, c: contacts[5], title: 'Kit Lançamento', stage: 'producao', h: 20, paid: true, art: 'aprovada' }),
  base({ id: 'o7', number: 1047, c: contacts[0], title: 'Kit Delivery', stage: 'entregue', h: 90, paid: true, art: 'aprovada' }),
]
const fin = { o1: [459, 210], o2: [219, 95], o3: [119, 48], o4: [139, 55], o5: [99, 38], o6: [749, 340], o7: [349, 160] }
const fins = Object.entries(fin).map(([id, [total, cost]]) => {
  const tax = +(total * 0.06).toFixed(2), fee = +(total * 0.015).toFixed(2), net = +(total - cost - tax - fee).toFixed(2)
  return { order_id: id, gross: total, total, cost, tax, fee, net_profit: net, margin_pct: +((net / total) * 100).toFixed(1) }
})
const items = [{ id: 'i1', order_id: 'o1', code: 'KB-01', description: 'Kit Barbearia', qty: 1, unit_cost: 210, unit_price: 459 }]
const events = [
  { id: 'e1', order_id: 'o1', kind: 'create', from_stage: null, to_stage: 'novo', message: 'Pedido criado', created_at: ago(1) },
  { id: 'e2', order_id: 'o1', kind: 'note', from_stage: null, to_stage: null, message: 'Cliente quer retirar na sexta.', created_at: ago(0.5) },
]
const userId = '00000000-0000-0000-0000-000000000001'
const profile = { id: userId, name: 'Admin', role: 'admin', created_at: ago(500) }
const settings = [
  { key: 'pricing', value: { floor_multiplier: 1.5, max_discount_pct: 10, min_net_profit: 60, tax_pct: 6, payment_fee_pct: 1.5 } },
  { key: 'kanban', value: { stage_limit_hours: { novo: 4, cotando: 8, aguardando_pagamento: 24, pago: 12, arte: 24, prova: 24, producao: 72, entregue: 0, recompra: 0 } } },
]

async function mock(ctx) {
  await ctx.route('**/auth/v1/**', (r) => r.fulfill({ json: { id: userId, email: 'dono@suagraficabh.com.br' } }))
  await ctx.route('**/rest/v1/**', (r) => {
    const url = new URL(r.request().url())
    const t = url.pathname.split('/').pop()
    const single = (r.request().headers()['accept'] ?? '').includes('pgrst.object')
    const table = { orders, order_financials: fins, order_items: items, order_events: events, order_files: [], app_settings: settings, contacts: contacts.map((c) => ({ ...c, notes: null, tags: [], marketing_consent: 'none', marketing_consent_at: null, marketing_consent_source: null, created_at: ago(40) })), conversations: [], messages: [{ created_at: ago(1) }], templates_cache: [], profiles: [profile] }[t] ?? []
    const body = single ? (Array.isArray(table) ? table[0] ?? null : table) : table
    const head = r.request().method() === 'HEAD'
    return r.fulfill({ status: 200, headers: { 'content-range': `0-0/${Array.isArray(table) ? table.length : 1}` }, json: head ? undefined : body })
  })
}

async function login(ctx) {
  const session = { access_token: 'x.y.z', refresh_token: 'r', token_type: 'bearer', expires_in: 99999, expires_at: Math.floor(Date.now() / 1000) + 99999, user: { id: userId, email: 'dono@suagraficabh.com.br', aud: 'authenticated', app_metadata: {}, user_metadata: {}, created_at: ago(500) } }
  await ctx.addInitScript((s) => localStorage.setItem('sb-localhost-auth-token', JSON.stringify(s)), session)
}

;(async () => {
  const browser = await chromium.launch()
  const sizes = { desktop: { width: 1440, height: 900 }, celular: { width: 390, height: 844 } }
  for (const [name, viewport] of Object.entries(sizes)) {
    const ctx = await browser.newContext({ viewport, deviceScaleFactor: 1 })
    await mock(ctx)
    const page = await ctx.newPage()
    page.on('pageerror', (e) => console.log('pageerror:', name, e.message))
    await page.goto(`${BASE}/login`)
    await page.waitForSelector('text=Entrar')
    await page.screenshot({ path: path.join(OUT, `login-${name}.png`) })

    await login(ctx)
    await page.goto(`${BASE}/kanban`)
    await page.locator('text=Marcos Barbearia').locator('visible=true').first().waitFor()
    await page.screenshot({ path: path.join(OUT, `kanban-${name}.png`) })

    await page.goto(`${BASE}/kanban?pedido=o1`)
    await page.waitForSelector('text=Pedido #1041')
    await page.getByRole('tab', { name: 'Itens' }).click()
    await page.waitForTimeout(400)
    await page.screenshot({ path: path.join(OUT, `pedido-${name}.png`) })

    await page.goto(`${BASE}/painel`)
    await page.getByRole('heading', { name: 'Painel' }).waitFor()
    await page.getByRole('switch', { name: 'Modo demonstração' }).click()
    await page.waitForSelector('text=Funil de pedidos')
    await page.waitForTimeout(2200)
    await page.screenshot({ path: path.join(OUT, `painel-${name}.png`), fullPage: name === 'celular' })
    await ctx.close()
  }
  await browser.close()
})()
