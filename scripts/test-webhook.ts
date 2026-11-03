// Testes locais (Node >= 22): npm run test:webhook
import assert from 'node:assert/strict'
import { createHmac } from 'node:crypto'
import { extractEvents, isOptOutMessage, shouldApplyStatus } from '../supabase/functions/_shared/parse.ts'
import { verifySignature } from '../supabase/functions/_shared/signature.ts'

const secret = 'segredo-de-teste-nao-real'
const payload = JSON.stringify({
  object: 'whatsapp_business_account',
  entry: [{
    changes: [{
      value: {
        contacts: [{ wa_id: '5531999990000', profile: { name: 'Maria Silva' } }],
        messages: [
          { from: '5531999990000', id: 'wamid.TEXT', timestamp: '1790000000', type: 'text', text: { body: 'Quero 500 cartões' }, referral: { source_url: 'https://fb.me/abc', source_id: '120200', source_type: 'ad', headline: 'Cartões de visita', ctwa_clid: 'AbCd' } },
          { from: '5531999990000', id: 'wamid.LOC', timestamp: '1790000002', type: 'location', location: { latitude: -19.92, longitude: -43.94, name: 'Escritório' } },
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
assert.equal(messages.length, 3)
assert.equal(messages[0].name, 'Maria Silva')
assert.equal(messages[0].body, 'Quero 500 cartões')
assert.match(messages[1].body, /localização.*maps\?q=-19.92,-43.94/)
assert.equal(messages[2].body, '[imagem recebida]')
assert.equal(messages[0].referral?.sourceId, '120200')
assert.equal(messages[0].referral?.headline, 'Cartões de visita')
assert.equal(messages[2].referral, null)
assert.equal(messages[2].mediaId, 'MEDIA123')
assert.equal(statuses[0].status, 'failed')
assert.match(statuses[0].error ?? '', /131047/)

// Ordem de status
assert.equal(shouldApplyStatus('read', 'delivered'), false)
assert.equal(shouldApplyStatus('sent', 'delivered'), true)
assert.equal(shouldApplyStatus('read', 'failed'), false)
assert.equal(shouldApplyStatus(null, 'sent'), true)

// Descadastro (PARAR)
for (const ok of ['PARAR', 'parar', ' Parar! ', 'sair', 'STOP', 'Parar de receber', 'Cancelar inscrição', 'Parar promoções', 'Não quero receber', 'Não quero mais', 'não quero mais!', 'Pare']) {
  assert.equal(isOptOutMessage(ok), true, `"${ok}" deve descadastrar`)
}
for (const no of ['quero parar o pedido', 'não parar', 'oi', '', 'saiu?', 'não quero mais esse modelo', 'quero mais 500']) {
  assert.equal(isOptOutMessage(no), false, `"${no}" não deve descadastrar`)
}

console.log('OK: assinatura, parsing, ordem de status e descadastro validados')

// Tipos novos: vídeo, figurinha, contato, reação, resposta a uma mensagem, encaminhada, não suportada
{
  const ev = extractEvents({ entry: [{ changes: [{ value: { messages: [
    { from: '5531999990000', id: 'w.vid', timestamp: '1790000010', type: 'video', video: { id: 'V1', mime_type: 'video/mp4', caption: 'olha' } },
    { from: '5531999990000', id: 'w.stk', timestamp: '1790000011', type: 'sticker', sticker: { id: 'S1', animated: false } },
    { from: '5531999990000', id: 'w.ctt', timestamp: '1790000012', type: 'contacts', contacts: [{ name: { formatted_name: 'João' }, phones: [{ phone: '+55 31 90000-0000', wa_id: '553190000000' }] }] },
    { from: '5531999990000', id: 'w.rea', timestamp: '1790000013', type: 'reaction', reaction: { message_id: 'wamid.ALVO', emoji: '👍' } },
    { from: '5531999990000', id: 'w.rep', timestamp: '1790000014', type: 'text', text: { body: 'sim' }, context: { id: 'wamid.ORIG', forwarded: true } },
    { from: '5531999990000', id: 'w.uns', timestamp: '1790000015', type: 'unsupported', errors: [{ code: 131051, title: 'Message type is not supported' }] },
    { from: '5531999990000', id: 'w.aud', timestamp: '1790000016', type: 'audio', audio: { id: 'A1', voice: true, mime_type: 'audio/ogg; codecs=opus' } },
    { from: '5531999990000', id: 'w.doc', timestamp: '1790000017', type: 'document', document: { id: 'D1', filename: 'proposta.pdf', mime_type: 'application/pdf' } },
  ] } }] }] })
  const por = Object.fromEntries(ev.messages.map((m) => [m.waMessageId, m]))
  assert.equal(por['w.vid'].type, 'video'); assert.equal(por['w.vid'].mediaId, 'V1'); assert.ok(por['w.vid'].body.includes('olha'))
  assert.equal(por['w.stk'].type, 'sticker')
  assert.equal(por['w.ctt'].type, 'contacts'); assert.ok(por['w.ctt'].body.includes('João'))
  assert.equal(por['w.rea'].type, 'reaction'); assert.equal(por['w.rea'].body, '👍'); assert.equal(por['w.rea'].meta?.alvo, 'wamid.ALVO')
  assert.equal(por['w.rep'].replyToWaId, 'wamid.ORIG'); assert.equal(por['w.rep'].forwarded, true)
  assert.equal(por['w.uns'].body, '[mensagem não suportada]'); assert.equal(por['w.uns'].rawType, 'unsupported'); assert.ok(por['w.uns'].meta)
  assert.equal(por['w.aud'].meta?.voice, true)
  assert.equal(por['w.doc'].meta?.filename, 'proposta.pdf')
  console.log('OK: vídeo, figurinha, contato, reação, resposta, encaminhada, áudio de voz, documento e tipo não suportado')
}
