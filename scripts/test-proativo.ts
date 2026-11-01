// Testes locais (Node >= 22): npm run test:proativo. Regras do envio proativo da Etapa 7 e conferência dos textos e templates.
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { decidirEnvio, erroPermanente, janelaAberta, limparParametro } from '../supabase/functions/_shared/proativo.ts'
import { AGENT_TEMPLATES } from '../src/lib/agent-templates.ts'

const base = { via: 'livre' as const, janelaAberta: true, temTemplate: true, categoria: 'MARKETING', optout: false, consentimento: 'none', exigirOptin: true }
const agora = Date.parse('2026-11-03T15:00:00Z')

// janela de 24 h: só a mensagem do cliente abre
assert.equal(janelaAberta('2026-11-03T10:00:00Z', agora), true)
assert.equal(janelaAberta('2026-11-02T10:00:00Z', agora), false)
assert.equal(janelaAberta(null, agora), false)

// texto livre com janela aberta: sempre, mesmo sem opt-in
assert.deepEqual(decidirEnvio(base), { acao: 'livre' })
// janela fechada: template; marketing sem opt-in é recusado; utilidade passa
assert.deepEqual(decidirEnvio({ ...base, janelaAberta: false }), { acao: 'recusar', motivo: 'sem_optin_marketing', permanente: true })
assert.deepEqual(decidirEnvio({ ...base, janelaAberta: false, consentimento: 'opted_in' }), { acao: 'template' })
assert.deepEqual(decidirEnvio({ ...base, janelaAberta: false, categoria: 'UTILITY' }), { acao: 'template' })
assert.deepEqual(decidirEnvio({ ...base, janelaAberta: false, categoria: 'UTILITY', optout: true, consentimento: 'opted_out' }), { acao: 'template' }, 'quem pediu PARAR continua recebendo avisos do pedido')
assert.deepEqual(decidirEnvio({ ...base, janelaAberta: false, optout: true, consentimento: 'opted_out' }), { acao: 'recusar', motivo: 'optout', permanente: true })
assert.deepEqual(decidirEnvio({ ...base, janelaAberta: false, exigirOptin: false }), { acao: 'template' }, 'o dono pode desligar a exigência de opt-in')
assert.deepEqual(decidirEnvio({ ...base, janelaAberta: false, temTemplate: false }), { acao: 'recusar', motivo: 'janela_fechada', permanente: true })
assert.deepEqual(decidirEnvio({ ...base, via: 'template', janelaAberta: true, consentimento: 'opted_in' }), { acao: 'template' })

// variáveis do template
assert.equal(limparParametro('R$ 8,00\nde desconto'), 'R$ 8,00 de desconto')
assert.equal(limparParametro(''), '-')
assert.equal(limparParametro(null), '-')
assert.ok(limparParametro('x'.repeat(2000)).length <= 900)
assert.equal(erroPermanente(131026), true)
assert.equal(erroPermanente(131047), false)
assert.equal(erroPermanente(null), false)

// os templates usados pelo SQL existem, com o número de variáveis que o banco manda
const porNome = new Map(AGENT_TEMPLATES.map((t) => [t.name, t]))
const vars = (n: string) => new Set((porNome.get(n)?.body.match(/\{\{\d+\}\}/g) ?? [])).size
const usados: Record<string, number> = {
  orcamento_vence_hoje: 3, condicao_especial_orcamento: 4, ultima_chance_orcamento: 2, pagamento_pendente: 3,
  pos_venda_satisfacao: 2, recompra_lembrete: 2, pedido_pronto_retirada: 2, pedido_saiu_entrega: 3,
}
for (const [nome, n] of Object.entries(usados)) {
  assert.ok(porNome.has(nome), `template ${nome} não existe em agent-templates.ts`)
  assert.equal(vars(nome), n, `${nome}: o banco manda ${n} variáveis`)
}

// textos do banco: sem travessão, sem termos internos e sem a palavra bicicleta
const sql = readFileSync(new URL('../supabase/migrations/20261102000001_etapa7_followups_status.sql', import.meta.url), 'utf8')
const textos = [...sql.matchAll(/format\('(Oi,[^']*(?:''[^']*)*)'/g)].map((m) => m[1])
assert.ok(textos.length >= 10, 'textos de mensagem encontrados no SQL')
for (const t of textos) {
  assert.ok(!/[—–]/.test(t), `travessão em: ${t.slice(0, 50)}`)
  assert.ok(!/\b(custo|margem|piso|sku|fornecedor|bicicleta|bike)\b/i.test(t), `termo interno em: ${t.slice(0, 50)}`)
}
console.log('OK: proativo (envio, janela, opt-in, templates e textos)')
