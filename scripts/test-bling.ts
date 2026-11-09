// Fase 6 (Bling e marketplaces): assinatura do webhook e textos de anúncio. npm run test:bling
import assert from 'node:assert/strict'
import { createHmac } from 'node:crypto'
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

console.log('OK: Bling (assinatura do webhook) e anúncios de marketplace')
