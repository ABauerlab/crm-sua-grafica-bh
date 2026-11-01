// Testes locais (Node >= 22): npm run test:agente
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { acionarAgente } from '../supabase/functions/_shared/agente.ts'

// ---- Gancho do webhook: sem segredos fica desligado; com segredos manda só o id da mensagem
let chamadas: { url: string; init: RequestInit }[] = []
const falso = (ok: boolean, lancar = false): typeof fetch => (async (url: string | URL | Request, init?: RequestInit) => {
  chamadas.push({ url: String(url), init: init ?? {} })
  if (lancar) throw new Error('rede')
  return new Response('', { status: ok ? 200 : 500 })
}) as typeof fetch
assert.equal(await acionarAgente('m1', { url: '', token: 'x' }, falso(true)), 'desligado')
assert.equal(await acionarAgente('m1', { url: 'https://n8n/x', token: null }, falso(true)), 'desligado')
assert.equal(chamadas.length, 0, 'sem segredos nada é chamado')
assert.equal(await acionarAgente('abc', { url: 'https://n8n/x', token: 'seg' }, falso(true)), 'enviado')
assert.deepEqual(JSON.parse(String(chamadas[0].init.body)), { message_id: 'abc' }, 'só o id da mensagem vai ao n8n')
assert.equal((chamadas[0].init.headers as Record<string, string>)['x-gbh-token'], 'seg')
assert.equal(await acionarAgente('abc', { url: 'https://n8n/x', token: 'seg' }, falso(false)), 'falhou')
assert.equal(await acionarAgente('abc', { url: 'https://n8n/x', token: 'seg' }, falso(true, true)), 'falhou', 'falha de rede nunca lança')

// ---- O webhook não pode ter o nome do fornecedor nem segredos; e o gancho precisa estar depois do PARAR
const wh = readFileSync(new URL('../supabase/functions/whatsapp-webhook/index.ts', import.meta.url), 'utf8')
assert.ok(wh.indexOf('confirmOptOut(db') < wh.indexOf('acionarAgente('), 'o agente é acionado depois do tratamento de PARAR')
assert.ok(/!\(m\.type === 'text' && isOptOutMessage/.test(wh), 'mensagem PARAR não aciona o agente')

console.log('Gancho do webhook: OK')
