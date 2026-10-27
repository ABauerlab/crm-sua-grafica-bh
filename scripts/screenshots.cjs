// Gera as capturas de tela em docs/telas com o Supabase simulado (nenhum dado real é usado).
// Uso: VITE_SUPABASE_URL=http://localhost:54321 VITE_SUPABASE_ANON_KEY=x npx vite --port 5199 &  node scripts/screenshots.cjs
const { chromium } = require('playwright')
const path = require('node:path')

const ONLY = (process.env.ONLY ?? '').split(',').filter(Boolean)
const want = (n) => ONLY.length === 0 || ONLY.includes(n)
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
const conv = { id: 'cv1041', contact_id: 'c1', status: 'open', stage: 'novo', assigned_to: null, ai_handled: false, last_message_at: ago(0.2), last_message_preview: 'Quero um kit com cartões e adesivos', last_inbound_at: ago(0.2), unread_count: 2, needs_human: false, summary: null, collected_data: {}, labels: ['orçamento'], ad_window_until: ago(-60), last_referral: null, created_at: ago(50), contact: { ...contacts[0], notes: null, tags: ['barbearia'], marketing_consent: 'opted_in', marketing_consent_at: ago(30), marketing_consent_source: 'whatsapp', first_referral: { headline: 'Kit Barbearia', source_id: '1202', source_type: 'ad' }, first_referral_at: ago(50), company: 'Barbearia do Marcos', segment: 'barbearia', email: null, document: null, address: null, created_at: ago(50) } }
const messages = [
  { id: 'm1', conversation_id: 'cv1041', wa_message_id: 'w1', direction: 'in', type: 'text', body: 'Oi! Vi o anúncio do kit para barbearia', template_name: null, media_id: null, media_path: null, status: null, error: null, created_at: ago(1.2) },
  { id: 'm2', conversation_id: 'cv1041', wa_message_id: 'w2', direction: 'out', type: 'text', body: 'Olá, Marcos! O Kit Barbearia tem cartões, adesivos e panfletos. Quantos você precisa?', template_name: null, media_id: null, media_path: null, status: 'read', error: null, created_at: ago(1.1) },
  { id: 'm3', conversation_id: 'cv1041', wa_message_id: 'w3', direction: 'in', type: 'text', body: 'Quero um kit com cartões e adesivos', template_name: null, media_id: null, media_path: null, status: null, error: null, created_at: ago(0.2) },
]
const notes = [{ id: 'n1', conversation_id: 'cv1041', body: 'Cliente indicado pelo Hugo. Oferecer 5% no primeiro pedido.', created_at: ago(0.5) }]
const quick = [{ id: 'q1', shortcut: 'prazo', title: 'Prazo de produção', body: 'Nosso prazo é de 3 a 5 dias úteis após a aprovação da arte.' }, { id: 'q2', shortcut: 'pix', title: 'Formas de pagamento', body: 'Aceitamos Pix e cartão de crédito.' }]
const stats = [{ contact_id: 'c1', orders_count: 3, paid_orders: 2, ltv: 808, profit: 390, last_order_at: ago(24 * 20) }]
const products = [
  { id: 'p1', code: 'CV-0500', description: 'Cartão de visita 500 un couchê 300g frente e verso', category: 'Cartões de visita', supplier: 'Fornecedor', colors: '4X0', weight: 500, qty: 500, size: '90 x 50', lead_days: 3, cost: 48, suggested_price: 119, active: true, floor_price: 72, max_discount_price: 107.1, est_net_profit: 62.08 },
  { id: 'p2', code: 'PF-A5-1000', description: 'Panfleto A5 1.000 un couchê 115g 4x0', category: 'Panfletos', supplier: 'Fornecedor', colors: '4X0', weight: 500, qty: 500, size: '90 x 50', lead_days: 3, cost: 95, suggested_price: 219, active: true, floor_price: 142.5, max_discount_price: 197.1, est_net_profit: 107.58 },
  { id: 'p3', code: 'AD-R5-200', description: 'Adesivo redondo 5 cm 200 un vinil', category: 'Adesivos', supplier: 'Fornecedor', colors: '4X0', weight: 500, qty: 500, size: '90 x 50', lead_days: 3, cost: 38, suggested_price: 99, active: true, floor_price: 57, max_discount_price: 89.1, est_net_profit: 53.58 },
  { id: 'p4', code: 'BN-80120', description: 'Banner 80x120 cm lona 440g com ilhós', category: 'Banners', supplier: 'Fornecedor', colors: '4X0', weight: 500, qty: 500, size: '90 x 50', lead_days: 3, cost: 55, suggested_price: 139, active: true, floor_price: 82.5, max_discount_price: 125.1, est_net_profit: 73.58 },
]
const kits = [{ id: 'k1', name: 'Kit Barbearia', segment: 'barbearia', description: 'Cartões, adesivos e panfletos para barbearias', price: 459, active: true }, { id: 'k2', name: 'Kit Delivery', segment: 'delivery', description: 'Cardápio, adesivos de lacre e cartões', price: 349, active: true }]
const kitItems = [{ id: 'ki1', kit_id: 'k1', product_id: 'p1', description: 'Cartão de visita 500 un', qty: 1, unit_cost: 48 }, { id: 'ki2', kit_id: 'k1', product_id: 'p3', description: 'Adesivo redondo 5 cm 200 un', qty: 2, unit_cost: 38 }, { id: 'ki3', kit_id: 'k1', product_id: 'p2', description: 'Panfleto A5 1.000 un', qty: 1, unit_cost: 95 }]
const adPerf = [
  { ad_id: '1202', ad_name: 'Kit Barbearia | vídeo 1', adset_id: 's1', adset_name: 'BH 25-45', campaign_id: 'c1', campaign_name: 'Kit Barbearia', spend: 180, impressions: 24000, clicks: 520, meta_conversations: 41, conversations: 38, quotes: 21, paid_orders: 9, revenue: 3441, net_profit: 1590 },
  { ad_id: '1203', ad_name: 'Kit Barbearia | imagem', adset_id: 's1', adset_name: 'BH 25-45', campaign_id: 'c1', campaign_name: 'Kit Barbearia', spend: 95, impressions: 12000, clicks: 240, meta_conversations: 17, conversations: 15, quotes: 6, paid_orders: 2, revenue: 760, net_profit: 330 },
  { ad_id: '1301', ad_name: 'Cartões | carrossel', adset_id: 's2', adset_name: 'Lojas BH', campaign_id: 'c2', campaign_name: 'Cartões de visita BH', spend: 210, impressions: 30000, clicks: 410, meta_conversations: 22, conversations: 30, quotes: 9, paid_orders: 1, revenue: 119, net_profit: 55 },
]
const tasksData = [
  { id: 't1', title: 'Cobrar pagamento de Júlia Confeitaria', due_at: ago(26), priority: 'alta', contact_id: 'c3', order_id: 'o3', kind: 'cobrar_pagamento', done_at: null, created_at: ago(30), contact: contacts[2], order: { id: 'o3', number: 1043, title: '500 cartões' } },
  { id: 't2', title: 'Ligar para Studio Fit BH sobre a arte', due_at: ago(-2), priority: 'media', contact_id: 'c4', order_id: null, kind: null, done_at: null, created_at: ago(5), contact: contacts[3], order: null },
]
const userId = '00000000-0000-0000-0000-000000000001'
const profile = { id: userId, name: 'Admin', role: 'admin', created_at: ago(500) }
const settings = [
  { key: 'agent', value: { enabled: true, hours: { start: '08:00', end: '18:00', days: [1, 2, 3, 4, 5] }, handoff_message: 'Vou chamar um atendente para te ajudar. Um instante!' } },
  { key: 'labels', value: ['dúvida', 'orçamento', 'reclamação', 'arte', 'recompra'] },
  { key: 'campaign_goals', value: { max_cost_per_conversation: 6, max_cost_per_sale: 60, min_roas: 4 } },
  { key: 'repurchase', value: { days: 45 } },
  { key: 'company', value: { name: 'Sua Gráfica BH', legal_name: '58.481.181 JOAO VICTOR BAUER ROCHA GOMES', cnpj: '58.481.181/0001-03', address: 'Rua Rio de Janeiro, 462, Centro, Belo Horizonte/MG', email: 'contato@suagraficabh.com.br', phone: '(31) 97561-8243', hours: 'Seg a sex, 8h às 18h' } },
  { key: 'pricing', value: { floor_multiplier: 1.5, max_discount_pct: 10, min_net_profit: 60, tax_pct: 6, payment_fee_pct: 1.5 } },
  { key: 'kanban', value: { stage_limit_hours: { novo: 4, cotando: 8, aguardando_pagamento: 24, pago: 12, arte: 24, prova: 24, producao: 72, entregue: 0, recompra: 0 } } },
]

async function mock(ctx) {
  await ctx.route('**/auth/v1/**', (r) => r.fulfill({ json: { id: userId, email: 'dono@suagraficabh.com.br' } }))
  await ctx.route('**/rest/v1/**', (r) => {
    const url = new URL(r.request().url())
    const t = url.pathname.split('/').pop()
    const single = (r.request().headers()['accept'] ?? '').includes('pgrst.object')
    let table = { orders, order_financials: fins, order_items: items, order_events: events, order_files: [], app_settings: settings, contacts: contacts.map((c) => ({ ...c, notes: null, tags: [], marketing_consent: 'none', marketing_consent_at: null, marketing_consent_source: null, created_at: ago(40) })), conversations: [conv], messages, conversation_notes: notes, quick_replies: quick, contact_stats: stats, products_priced: products, products, kits, kit_items: kitItems, ad_performance: adPerf, ad_entities: [{ updated_at: ago(2) }], ad_manual_spend: [{ id: 'ms1', day: new Date().toISOString().slice(0, 10), campaign_name: 'Panfleto de rua', amount: 80, note: 'Distribuição no Centro' }], tasks: tasksData, agent_logs: [{ id: 'l1', conversation_id: null, actor: 'humano', action: 'pausou_ia', detail: {}, result: 'ok', created_at: ago(3) }], templates_cache: [], profiles: [profile] }[t] ?? []
    if (t === 'app_settings') { const k = (url.searchParams.get('key') ?? '').replace('eq.', ''); if (k) table = settings.filter((x) => x.key === k) }
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
    if (want('login')) {
      await page.goto(`${BASE}/login`)
      await page.waitForSelector('text=Entrar')
      await page.screenshot({ path: path.join(OUT, `login-${name}.png`) })
    }

    await login(ctx)
    if (want('kanban') || want('pedido') || want('painel')) {
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

    }
    for (const [file, route, ready] of [
      ['conversa', `/inbox/cv1041`, 'text=Quero um kit com cartões e adesivos'],
      ['contatos', '/contatos', 'text=Marcos Barbearia'],
      ['catalogo', '/catalogo', 'text=CV-0500'],
      ['campanhas', '/campanhas', 'text=Kit Barbearia'],
      ['tarefas', '/tarefas', 'text=Ligar para Studio Fit BH'],
      ['configuracoes', '/configuracoes', 'text=Dados da empresa'],
    ]) {
      if (!want(file)) continue
      await page.goto(`${BASE}${route}`)
      await page.locator(ready).locator('visible=true').first().waitFor().catch(() => {})
      await page.waitForTimeout(file === 'campanhas' ? 2200 : 500)
      await page.screenshot({ path: path.join(OUT, `${file}-${name}.png`), fullPage: false })
    }
    await ctx.close()
  }
  await browser.close()
})()
