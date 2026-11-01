// Testes locais do Mercado Pago (Node >= 22): npm run test:mp
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { taxaRealDe, metodoDe } from '../supabase/functions/_shared/mppay.ts'
import { hmacSha256Hex } from '../supabase/functions/_shared/signature.ts'
import {
  buildItems, buildManifest, buildPreference, formatReference, mapStatus, parseExpiraHoras, parseModo, parseReference, parseSignatureHeader, toCents, verifyMpSignature,
} from '../supabase/functions/_shared/mp.ts'

const secret = 'segredo-de-teste-nao-real'
const now = 1_790_000_000_000
const sign = async (dataId: string | null, requestId: string | null, ts: number, key = secret) =>
  `ts=${ts},v1=${await hmacSha256Hex(key, buildManifest(dataId, requestId, String(ts)))}`

// Manifesto no formato do Mercado Pago (id em minúsculo quando alfanumérico)
assert.equal(buildManifest('ABC123', 'req-1', '1700'), 'id:abc123;request-id:req-1;ts:1700;')
assert.equal(buildManifest(null, 'req-1', '1700'), 'request-id:req-1;ts:1700;')

// Assinatura: válida, inválida, ausente, malformada e antiga (replay)
const ok = await sign('123456', 'req-1', now)
assert.deepEqual(await verifyMpSignature({ secret, signatureHeader: ok, requestId: 'req-1', dataId: '123456', nowMs: now + 1000 }), { ok: true })
assert.deepEqual(await verifyMpSignature({ secret, signatureHeader: await sign('123456', 'req-1', now, 'outro-segredo'), requestId: 'req-1', dataId: '123456', nowMs: now }), { ok: false, reason: 'invalida' })
assert.deepEqual(await verifyMpSignature({ secret, signatureHeader: ok, requestId: 'req-2', dataId: '123456', nowMs: now }), { ok: false, reason: 'invalida' }, 'request-id diferente')
assert.deepEqual(await verifyMpSignature({ secret, signatureHeader: ok, requestId: 'req-1', dataId: '999', nowMs: now }), { ok: false, reason: 'invalida' }, 'id de outro pagamento')
assert.deepEqual(await verifyMpSignature({ secret, signatureHeader: null, requestId: 'req-1', dataId: '123456', nowMs: now }), { ok: false, reason: 'ausente' })
assert.deepEqual(await verifyMpSignature({ secret, signatureHeader: 'lixo', requestId: 'req-1', dataId: '123456', nowMs: now }), { ok: false, reason: 'formato' })
assert.deepEqual(await verifyMpSignature({ secret, signatureHeader: 'ts=abc,v1=' + 'a'.repeat(64), requestId: null, dataId: null, nowMs: now }), { ok: false, reason: 'formato' })
const old = await sign('123456', 'req-1', now - 11 * 60 * 1000)
assert.deepEqual(await verifyMpSignature({ secret, signatureHeader: old, requestId: 'req-1', dataId: '123456', nowMs: now }), { ok: false, reason: 'antiga' }, 'replay fora da janela')
assert.deepEqual(await verifyMpSignature({ secret, signatureHeader: old, requestId: 'req-1', dataId: '123456', nowMs: now, windowMs: 60 * 60 * 1000 }), { ok: true }, 'janela configurável')
const future = await sign('123456', 'req-1', now + 11 * 60 * 1000)
assert.deepEqual(await verifyMpSignature({ secret, signatureHeader: future, requestId: 'req-1', dataId: '123456', nowMs: now }), { ok: false, reason: 'antiga' }, 'relógio adiantado também falha')
// Carimbo em segundos também é aceito
const secs = `ts=${now / 1000},v1=${await hmacSha256Hex(secret, buildManifest('1', 'r', String(now / 1000)))}`
assert.deepEqual(await verifyMpSignature({ secret, signatureHeader: secs, requestId: 'r', dataId: '1', nowMs: now }), { ok: true })
assert.deepEqual(parseSignatureHeader('ts=1, v1=abc'), { ts: '1', v1: 'abc' })

// Referência, modo e status
assert.equal(formatReference(1), 'SG-0001')
assert.equal(formatReference(12345), 'SG-12345')
assert.equal(parseReference('SG-0042'), 42)
assert.equal(parseReference('sg-1'), null)
assert.equal(parseReference('XX-0001'), null)
assert.equal(parseReference(null), null)
assert.equal(parseModo(' Teste '), 'teste')
assert.equal(parseModo('producao'), 'producao')
assert.equal(parseModo('prod'), null)
assert.equal(mapStatus('approved'), 'aprovado')
assert.equal(mapStatus('pending'), 'pendente')
assert.equal(mapStatus('in_process'), 'em_analise')
assert.equal(mapStatus('rejected'), 'recusado')
assert.equal(mapStatus('cancelled', 'expired'), 'expirado')
assert.equal(mapStatus('cancelled'), 'cancelado')
assert.equal(mapStatus('refunded'), 'estornado')
assert.equal(mapStatus('charged_back'), 'contestado')

// Itens da preferência: soma exata em centavos, mesmo com desconto, sem código do fornecedor nem custo
const lines = [
  { description: 'Cartão de visita 500 un', qty: 3, unit_price: 33.33 },
  { description: 'Banner 80x120', qty: 1, unit_price: 99.9 },
  { description: 'Adesivo', qty: 7, unit_price: 1.17 },
]
const gross = lines.reduce((n, l) => n + toCents(l.unit_price) * l.qty, 0)
for (const total of [gross, Math.round(gross * 0.9), Math.round(gross * 0.933), 1]) {
  const items = buildItems(lines, total)
  assert.equal(items.length, 3)
  assert.equal(items.reduce((n, i) => n + toCents(i.unit_price), 0), total, `soma fecha em ${total}`)
  assert.ok(items.every((i) => i.quantity === 1 && i.currency_id === 'BRL' && i.unit_price >= 0))
}
assert.deepEqual(buildItems([], 1000), [])
assert.deepEqual(buildItems(lines, 0), [])
assert.match(buildItems(lines, gross)[0].title, /^3x Cartão de visita/)
assert.equal(buildItems(lines, gross)[0].description, 'Cartão de visita 500 un')
assert.equal(buildItems(lines, gross)[0].category_id, 'services')

// Validade do link: padrão 48 h, aceita menos, recusa fora da faixa
assert.equal(parseExpiraHoras(undefined), 48)
assert.equal(parseExpiraHoras(2), 2)
assert.throws(() => parseExpiraHoras(0))
assert.throws(() => parseExpiraHoras(1000))
assert.throws(() => parseExpiraHoras('abc'))
const optsPref = { items: buildItems(lines, gross), reference: 'SG-0001', notificationUrl: 'https://x.supabase.co/functions/v1/mp-webhook?source_news=webhooks', backBase: 'https://crm.exemplo.com.br', now: new Date('2026-10-27T12:00:00Z'), horas: 48 }
const pref = buildPreference(optsPref)
assert.equal(pref.expiration_date_to, '2026-10-29T12:00:00.000Z')
assert.equal(pref.external_reference, 'SG-0001')
assert.equal(pref.auto_return, 'approved')
assert.equal(pref.expires, true)
assert.equal(pref.back_urls.success, 'https://crm.exemplo.com.br/pagamento/obrigado?r=ok')
assert.deepEqual(pref.payment_methods.excluded_payment_types, [{ id: 'ticket' }, { id: 'atm' }])
assert.equal(pref.payment_methods.installments, 12, 'link mostra até 12 parcelas (2x sem juros; acima disso juros do cliente)')
assert.equal(buildPreference({ ...optsPref, maxParcelas: 3 }).payment_methods.installments, 3, 'máximo de parcelas vem de Configurações')
assert.equal(buildPreference({ ...optsPref, politica: 'Produto personalizado.' }).additional_info, 'Produto personalizado.', 'política vai na descrição do link')

// Taxa real do Mercado Pago (fee_details) e método do pagamento
assert.deepEqual(taxaRealDe({ fee_details: [{ type: 'mercadopago_fee', amount: 9.9 }, { type: 'financing_fee', amount: 11.5 }], transaction_details: { net_received_amount: 178.6 }, installments: 2 }), { taxa: 21.4, liquido: 178.6, parcelas: 2 })
assert.equal(taxaRealDe({ fee_details: [] }), null)
assert.equal(taxaRealDe({}), null)
assert.equal(taxaRealDe({ fee_details: [{ amount: 'x' }] }), null)
assert.equal(metodoDe({ payment_method_id: 'pix' }), 'pix')
assert.equal(metodoDe({ payment_method_id: 'visa', payment_type_id: 'credit_card' }), 'cartao_credito')
assert.equal(metodoDe({ payment_method_id: 'debvisa', payment_type_id: 'debit_card' }), 'cartao_debito')
assert.ok(!JSON.stringify(pref).includes('unit_cost'), 'sem custo')

// Nenhum segredo do Mercado Pago no repositório (tokens APP_USR/TEST e chaves de 64 hex ao lado de "secret")
const files = execFileSync('git', ['ls-files', '-z'], { encoding: 'utf8' }).split('\0').filter((f) => f && !/\.(png|jpg|svg|ico|woff2?|pdf)$/.test(f))
for (const f of files) {
  let text = ''
  try {
    text = readFileSync(f, 'utf8')
  } catch {
    continue
  }
  assert.ok(!/(APP_USR|TEST)-[0-9a-f]{8,}-[0-9a-z-]{8,}/i.test(text), `possível token do Mercado Pago em ${f}`)
}

console.log('OK: assinatura do Mercado Pago, referência, status, itens da preferência, validade e ausência de segredos')
