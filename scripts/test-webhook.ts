// Testes locais (Node >= 22): npm run test:webhook
import assert from 'node:assert/strict'
import { createHmac } from 'node:crypto'
import { extractEvents, shouldApplyStatus } from '../supabase/functions/_shared/parse.ts'
import { verifySignature } from '../supabase/functions/_shared/signature.ts'

const secret = 'segredo-de-teste-nao-real'
const payload = JSON.stringify({
  object: 'whatsapp_business_account',
  entry: [{
    changes: [{
      value: {
        contacts: [{ wa_id: '5531999990000', profile: { name: 'Maria Silva' } }],
        messages: [
          { from: '5531999990000', id: 'wamid.TEXT', timestamp: '1790000000', type: 'text', text: { body: 'Quero 500 cartões' } },
          { from: '5531999990000', id: 'wamid.IMG', timestamp: '1790000001', type: 'image', image: { id: 'MEDIA123' } },
        ],
        statuses: [
          { id: 'wamid.OUT', status: 'failed', errors: [{ code: 131047, title: 'Re-engagement message' }] },
        ],
      },
    }],
  }],
})
const sign = (body: string, s = secret) => 'sha256=' + createHmac('sha256', s).update(body).digest('hex')

// Assinatura
assert.equal(await verifySignature(payload, sign(payload), secret), true, 'assinatura válida deve passar')
assert.equal(await verifySignature(payload, sign(payload, 'outro'), secret), false, 'segredo errado deve falhar')
assert.equal(await verifySignature(payload + ' ', sign(payload), secret), false, 'corpo adulterado deve falhar')
assert.equal(await verifySignature(payload, null, secret), false, 'sem cabeçalho deve falhar')
assert.equal(await verifySignature(payload, 'sha256=zzzz', secret), false, 'hex inválido deve falhar')
assert.equal(await verifySignature(payload, sign(payload).replace('sha256=', ''), secret), false, 'sem prefixo deve falhar')

// Parsing
const { messages, statuses } = extractEvents(JSON.parse(payload))
assert.equal(messages.length, 2)
assert.equal(messages[0].name, 'Maria Silva')
assert.equal(messages[0].body, 'Quero 500 cartões')
assert.equal(messages[1].body, '[imagem recebida]')
assert.equal(messages[1].mediaId, 'MEDIA123')
assert.equal(statuses[0].status, 'failed')
assert.match(statuses[0].error ?? '', /131047/)

// Ordem de status
assert.equal(shouldApplyStatus('read', 'delivered'), false)
assert.equal(shouldApplyStatus('sent', 'delivered'), true)
assert.equal(shouldApplyStatus('read', 'failed'), false)
assert.equal(shouldApplyStatus(null, 'sent'), true)

console.log('OK: assinatura, parsing e ordem de status validados')
