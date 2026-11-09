// Fase 6 (Bling e marketplaces): assinatura do webhook e textos de anúncio. npm run test:bling
import assert from 'node:assert/strict'
import { createHash, createHmac } from 'node:crypto'
import { corpoMeta, eventoMeta, sha256 } from '../supabase/functions/_shared/meta.ts'
import { assinaturaBlingValida, descricaoMarketplace, resumoEventoBling, tituloMarketplace } from '../supabase/functions/_shared/bling.ts'

const segredo = 'segredo-de-teste'
const corpo = JSON.stringify({ event: 'order.created', data: { id: 123 } })
const assinatura = 'sha256=' + createHmac('sha256', segredo).update(corpo).digest('hex')
assert.equal(await assinaturaBlingValida(corpo, assinatura, segredo), true)
assert.equal(await assinaturaBlingValida(corpo + ' ', assinatura, segredo), false, 'corpo alterado')
assert.equal(await assinaturaBlingValida(corpo, assinatura, 'outro'), false, 'segredo errado')
assert.equal(await assinaturaBlingValida(corpo, null, segredo), false, 'sem cabeçalho')
assert.equal(await assinaturaBlingValida(corpo, assinatura, undefined), false, 'sem segredo configurado nada passa')
assert.deepEqual(resumoEventoBling({ event: 'order.created', data: { id: 123 } }), { evento: 'order.created', recurso_id: '123' })

const p = { titulo: 'Cartões de Visita Couchê 300g Verniz Brilhante na Frente e no Verso', categoria: 'Cartões de Visita', quantidade: 1000,
  impressao: 'Colorido Frente e Verso', formato: '88 x 48 mm (8,8 x 4,8 cm)', material: 'Papel Couchê Brilho (cores vivas)', espessura: 'Papel Extra Firme (300g)',
  acabamento: 'Verniz Brilhante na Frente e no Verso', prazo_dias: 4, observacoes: ['Ideal para quem procura requinte.'] }
const t = tituloMarketplace(p)
assert.ok(t.length <= 60, `título com ${t.length} caracteres`)
assert.ok(t.startsWith('1.000 Cartões de Visita'))
const d = descricaoMarketplace(p)
assert.match(d, /1\.000 unidades/)
assert.match(d, /Prazo de fabricação: 4 dias úteis/)
assert.doesNotMatch(d, /custo|piso|margem|fornecedor|\bSKU\b/i)

// Conversions API (Fase 7): formato do evento e hash
const h = await sha256(' 5531975618243 ')
assert.equal(h, createHash('sha256').update('5531975618243').digest('hex'), 'normaliza espaços e gera SHA-256')
const ev = eventoMeta({ id: 1, event_id: 'purchase-abc', event_name: 'Purchase', event_time: '2026-11-09T12:00:00Z', action_source: 'website', event_source_url: null,
  user_data: { ph: h, em: 'nao-e-hash@x.com', fbp: 'fb.1.123.456', client_ip_address: '1.2.3.4' }, custom_data: { currency: 'BRL', value: 151.9 } })
assert.equal(ev.event_time, 1794225600)
assert.deepEqual(ev.user_data.ph, [h], 'hash vai em lista')
assert.equal('em' in ev.user_data, false, 'texto sem hash nunca vai para a Meta')
assert.equal(ev.user_data.fbp, 'fb.1.123.456')
assert.equal('event_source_url' in ev, false)
assert.equal(corpoMeta([], 'TEST123').test_event_code, 'TEST123')

console.log('OK: Bling (assinatura do webhook), anúncios de marketplace e Conversions API')
