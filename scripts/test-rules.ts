// Regras de preço e de transição do kanban (Node >= 22): npm run test:rules
import assert from 'node:assert/strict'
import { blockReason, DEFAULT_KANBAN, formatDuration, isStalled } from '../src/lib/orders.ts'
import { DEFAULT_PRICING, previewNetProfit, priceAlerts, unitFloor } from '../src/lib/pricing.ts'
import { parseMoney } from '../src/lib/money.ts'
import { lockSeconds } from '../src/lib/lock.ts'
import { guessHeaderRow, guessMapping, readTable } from '../src/lib/spreadsheet.ts'
import { goalState, groupCampaigns, metrics } from '../src/lib/campaigns.ts'

const fmt = (v: number) => `R$ ${v.toFixed(2)}`

// Piso = custo x 1,5
assert.equal(unitFloor(100, DEFAULT_PRICING), 150)
assert.equal(unitFloor(33.33, DEFAULT_PRICING), 50)

// Item abaixo do piso gera alerta; no piso não gera
const below = priceAlerts({ items: [{ description: 'Cartões', unit_cost: 100, unit_price: 149.99 }], discountPct: 0, netProfit: 500 }, DEFAULT_PRICING, fmt)
assert.deepEqual(below.map((a) => a.code), ['below_floor'])
const ok = priceAlerts({ items: [{ description: 'Cartões', unit_cost: 100, unit_price: 150 }], discountPct: 10, netProfit: 60 }, DEFAULT_PRICING, fmt)
assert.equal(ok.length, 0, 'no limite exato não alerta')

// Desconto acima de 10% e lucro abaixo de R$ 60
const many = priceAlerts({ items: [{ description: 'X', unit_cost: 10, unit_price: 20 }], discountPct: 10.5, netProfit: 59.99 }, DEFAULT_PRICING, fmt)
assert.deepEqual(many.map((a) => a.code).sort(), ['discount_too_high', 'profit_too_low'])

// Pedido sem itens não alerta lucro
assert.equal(priceAlerts({ items: [], discountPct: 0, netProfit: 0 }, DEFAULT_PRICING, fmt).length, 0)

// Lucro: total * (1 - 7,5%) - custo
assert.equal(previewNetProfit([{ qty: 2, unit_cost: 50, unit_price: 100 }], 0, 6, 1.5), 85)
assert.equal(previewNetProfit([{ qty: 1, unit_cost: 100, unit_price: 200 }], 10, 6, 1.5), 66.5)

// Transições
const base = { payment_status: 'pendente', payment_manual: false, art_status: 'aguardando' } as const
assert.match(blockReason(base, 'pago') ?? '', /pagamento/)
assert.equal(blockReason({ ...base, payment_status: 'aprovado' }, 'pago'), null)
assert.equal(blockReason({ ...base, payment_manual: true }, 'pago'), null, 'confirmação manual libera')
assert.match(blockReason(base, 'producao') ?? '', /arte/)
assert.equal(blockReason({ ...base, art_status: 'aprovada' }, 'producao'), null)
assert.equal(blockReason(base, 'cotando'), null)

// Pedidos parados
const now = Date.now()
const h = (n: number) => new Date(now - n * 3_600_000).toISOString()
assert.equal(isStalled({ stage: 'novo', stage_entered_at: h(5) }, DEFAULT_KANBAN, now), true)
assert.equal(isStalled({ stage: 'novo', stage_entered_at: h(3) }, DEFAULT_KANBAN, now), false)
assert.equal(isStalled({ stage: 'entregue', stage_entered_at: h(900) }, DEFAULT_KANBAN, now), false, 'limite 0 = sem alerta')
assert.equal(formatDuration(0.2), '12 min')
assert.equal(formatDuration(30), '30 h')
assert.equal(formatDuration(72), '3 d')

// Dinheiro digitado
assert.equal(parseMoney('1.234,56'), 1234.56)
assert.equal(parseMoney('12,5'), 12.5)
assert.equal(parseMoney('R$ 99'), 99)
assert.equal(parseMoney(''), 0)

// Bloqueio progressivo do login
assert.equal(lockSeconds(2), 0)
assert.equal(lockSeconds(3), 10)
assert.equal(lockSeconds(5), 40)
assert.equal(lockSeconds(20), 300)

// Campanhas: custo por conversa/venda, ROAS e lucro depois do anúncio
const m = metrics({ spend: 100, conversations: 20, quotes: 10, paid_orders: 4, revenue: 800, net_profit: 360 })
assert.equal(m.cpc, 5)
assert.equal(m.cps, 25)
assert.equal(m.roas, 8)
assert.equal(m.profitAfterAds, 260)
assert.equal(m.quoteRate, 50)
assert.equal(m.paidRate, 20)
assert.equal(metrics({ spend: 50, conversations: 0, quotes: 0, paid_orders: 0, revenue: 0, net_profit: 0 }).cpc, null, 'sem conversas não divide por zero')
assert.equal(metrics({ spend: 0, conversations: 3, quotes: 1, paid_orders: 1, revenue: 100, net_profit: 50 }).roas, null)
assert.equal(goalState('cost', 5, 6), 'good')
assert.equal(goalState('cost', 7, 6), 'bad')
assert.equal(goalState('roas', 4, 4), 'good')
assert.equal(goalState('roas', 3.9, 4), 'bad')
assert.equal(goalState('cost', null, 6), 'none')

const ad = (id: string, campaign: string, spend: number, paid: number, revenue: number) => ({
  ad_id: id, ad_name: id, adset_id: 's', adset_name: 's', campaign_id: campaign, campaign_name: `Campanha ${campaign}`, spend, impressions: 0, clicks: 0,
  meta_conversations: 0, conversations: 10, quotes: 5, paid_orders: paid, revenue, net_profit: revenue / 2,
})
const groups = groupCampaigns([ad('a1', 'X', 40, 1, 100), ad('a2', 'X', 60, 2, 300), ad('b1', 'Y', 10, 0, 0)], [
  { id: '1', day: '2026-10-01', campaign_name: 'campanha x', amount: 25, note: null },
  { id: '2', day: '2026-10-01', campaign_name: 'Panfleto de rua', amount: 80, note: null },
])
assert.equal(groups.length, 3)
assert.equal(groups[0].name, 'Campanha X')
assert.equal(groups[0].m.spend, 125, 'gasto da Meta (100) + manual de mesmo nome (25)')
assert.equal(groups[0].m.paid, 3)
assert.equal(groups.find((g) => g.name === 'Panfleto de rua')?.m.spend, 80, 'investimento manual sem anúncio vira linha própria')

// Planilha do fornecedor: .xlsx com título acima, cabeçalho com acentos e números
assert.equal(parseMoney('1.234'), 1234, 'ponto de milhar')
assert.equal(parseMoney('12.5'), 12.5)
assert.equal(parseMoney('1.234,56'), 1234.56)
const XLSX = await import('xlsx')
const wb = XLSX.utils.book_new()
XLSX.utils.book_append_sheet(
  wb,
  XLSX.utils.aoa_to_sheet([
    ['TABELA DE PREÇOS ZAP GRÁFICA'],
    [],
    ['Código', 'Descrição do Produto', 'Categoria', 'Valor Custo', 'Preço de Venda'],
    ['CV-0500', 'Cartão de visita 500 un', 'Cartões', 48.5, 119],
    ['PF-1000', 'Panfleto A5 1.000 un', 'Panfletos', '95,00', ''],
  ]),
  'Tabela',
)
const buf = XLSX.write(wb, { type: 'array', bookType: 'xlsx' })
const rows = await readTable(new File([buf], 'tabela.xlsx'))
const hdr = guessHeaderRow(rows)
assert.equal(hdr, 1, 'o título (1 célula) é ignorado e o cabeçalho é a linha seguinte')
assert.deepEqual(rows[hdr], ['Código', 'Descrição do Produto', 'Categoria', 'Valor Custo', 'Preço de Venda'])
const map = guessMapping(rows[hdr])
assert.deepEqual(map, { code: 0, description: 1, category: 2, cost: 3, price: 4 })
assert.equal(rows[hdr + 1][3], '48.5')
await assert.rejects(() => readTable(new File(['x'], 'catalogo.pdf')), /PDF/)

console.log('OK: regras de preço, transições do kanban, pedidos parados, login, campanhas e importação de planilha')
