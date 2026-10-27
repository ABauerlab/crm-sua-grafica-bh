// Regras de preço e de transição do kanban (Node >= 22): npm run test:rules
import assert from 'node:assert/strict'
import { blockReason, DEFAULT_KANBAN, formatDuration, isStalled } from '../src/lib/orders.ts'
import { DEFAULT_PRICING, previewNetProfit, priceAlerts, unitFloor } from '../src/lib/pricing.ts'
import { parseMoney } from '../src/lib/money.ts'
import { lockSeconds } from '../src/lib/lock.ts'

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

console.log('OK: regras de preço, transições do kanban, pedidos parados e bloqueio de login')
