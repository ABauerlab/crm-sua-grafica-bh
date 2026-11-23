// Testes locais do checkout próprio (Node >= 22): npm run test:checkout
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { corpoPagamento, desfechoCartao, documentoValido, emailValido, lerEntrada, mensagemRecusa, pagouComJuros, TOKEN_CHECKOUT, urlCheckout } from '../supabase/functions/_shared/checkout.ts'

// URL e token
assert.equal(urlCheckout('a'.repeat(32)), 'https://suagraficabh.com.br/pagar/' + 'a'.repeat(32))
assert.equal(urlCheckout('b'.repeat(32), 'https://x.com.br/'), 'https://x.com.br/pagar/' + 'b'.repeat(32))
assert.ok(TOKEN_CHECKOUT.test('0123456789abcdef0123456789abcdef'))
assert.ok(!TOKEN_CHECKOUT.test('0123456789ABCDEF0123456789abcdef') && !TOKEN_CHECKOUT.test('curto'))

// CPF e CNPJ
assert.ok(documentoValido('529.982.247-25') && documentoValido('52998224725'))
assert.ok(!documentoValido('529.982.247-24') && !documentoValido('11111111111') && !documentoValido('123'))
assert.ok(documentoValido('58.481.181/0001-03'), 'CNPJ da própria gráfica')
assert.ok(!documentoValido('58.481.181/0001-04') && !documentoValido('') && !documentoValido(null))
assert.ok(emailValido('paulo@exemplo.com') && !emailValido('sem-arroba') && !emailValido('a@b'))

// Entrada do Payment Brick: valor e pagador nunca são lidos do navegador
assert.deepEqual(lerEntrada({ payment_method_id: 'pix' }, 2), { ok: true, tipo: 'pix' })
const cartao = lerEntrada({ token: 'abc12345def', payment_method_id: 'visa', installments: 2, issuer_id: '24' }, 2)
assert.deepEqual(cartao, { ok: true, tipo: 'cartao', cardToken: 'abc12345def', metodo: 'visa', issuer: '24', parcelas: 2 })
assert.equal(lerEntrada({ token: 'abc12345def', payment_method_id: 'visa', installments: 3 }, 2).ok, false, 'acima do limite informado')
assert.equal(lerEntrada({ token: 'abc12345def', payment_method_id: 'visa', installments: 12 }, 12).ok, true, 'até 12x no cartão')
assert.equal(lerEntrada({ token: 'abc12345def', payment_method_id: 'visa', installments: 13 }, 12).ok, false)
assert.equal(lerEntrada({ token: 'abc12345def', payment_method_id: 'visa', installments: 0 }, 2).ok, false)
assert.equal(lerEntrada({ payment_method_id: 'visa', installments: 1 }, 2).ok, false, 'cartão sem token')
assert.equal(lerEntrada({ token: '<script>', payment_method_id: 'visa', installments: 1 }, 2).ok, false)
assert.equal(lerEntrada({ token: 'abc12345def', payment_method_id: 'visa; drop', installments: 1 }, 2).ok, false)
assert.equal(lerEntrada(null, 2).ok, false)

// Corpo do pagamento: valor e referência vêm do banco
const base = {
  valorCents: 23_680, referencia: 'SG-0407', notificationUrl: 'https://x/mp-webhook', itens: [{ description: 'Cartão de visita 500 un', qty: 1, unit_price: 197.8 }, { description: 'Criação de arte', qty: 1, unit_price: 39.9 }],
  pagador: { email: 'Paulo@Exemplo.com', nome: 'Paulo Moreira Silva', documento: '529.982.247-25' },
}
const pix = corpoPagamento({ ...base, entrada: { ok: true, tipo: 'pix' }, expiraPix: new Date('2026-11-19T10:00:00Z') }) as Record<string, any>
assert.equal(pix.transaction_amount, 236.8)
assert.equal(pix.external_reference, 'SG-0407')
assert.equal(pix.payment_method_id, 'pix')
assert.equal(pix.date_of_expiration, '2026-11-19T10:00:00.000+00:00')
assert.equal(pix.payer.email, 'paulo@exemplo.com')
assert.deepEqual(pix.payer.identification, { type: 'CPF', number: '52998224725' })
assert.equal(pix.payer.last_name, 'Moreira Silva')
const soma = pix.additional_info.items.reduce((n: number, i: any) => n + Math.round(i.unit_price * 100) * i.quantity, 0)
assert.equal(soma, 23_680, 'itens fecham no total em centavos')
assert.equal(pix.token, undefined)
const card = corpoPagamento({ ...base, pagador: { ...base.pagador, documento: '58.481.181/0001-03' }, entrada: { ok: true, tipo: 'cartao', cardToken: 'tok12345', metodo: 'master', issuer: '24', parcelas: 2 } }) as Record<string, any>
assert.equal(card.installments, 2)
assert.equal(card.token, 'tok12345')
assert.equal(card.issuer_id, 24)
assert.equal(card.payer.identification.type, 'CNPJ')
assert.equal(card.statement_descriptor, 'SUAGRAFICABH')
assert.ok(!JSON.stringify(card).includes('custo'))

// Desfechos e mensagens
assert.equal(desfechoCartao({ status: 'approved' }).status, 'approved')
assert.equal(desfechoCartao({ status: 'in_process' }).status, 'in_process')
const rec = desfechoCartao({ status: 'rejected', status_detail: 'cc_rejected_insufficient_amount' })
assert.equal(rec.status, 'rejected')
assert.match(rec.mensagem, /Saldo ou limite insuficiente/)
assert.match(mensagemRecusa('qualquer_coisa'), /recusado/)
assert.match(mensagemRecusa('cc_rejected_bad_filled_security_code'), /código de segurança/)

// Juros: total pago maior que o valor do pedido vira alerta
assert.equal(pagouComJuros({ transaction_amount: 100, transaction_details: { total_paid_amount: 100 } }), null)
assert.deepEqual(pagouComJuros({ transaction_amount: 100, transaction_details: { total_paid_amount: 104.5 } }), { juros: 4.5 })
assert.equal(pagouComJuros({}), null)

// Contrato: a página e as funções não carregam dado interno nem a chave secreta
for (const f of ['supabase/functions/checkout-dados/index.ts', 'supabase/functions/checkout-mp-processar/index.ts', 'supabase/functions/_shared/checkout.ts']) {
  const src = readFileSync(new URL('../' + f, import.meta.url), 'utf8')
  assert.ok(!/console\.(log|error)\([^)]*\b(email|documento|nome)\b/.test(src), `${f} não registra dado pessoal`)
}
// Checkout espelha o negociado: lote de 5 un. (qty 1) mostra 5 un. x valor unitário, nunca "1 un."; o total não muda
const pag = readFileSync(new URL('../ecommerce/lib/pagar.ts', import.meta.url), 'utf8')
assert.match(pag, /i\.unidades && i\.unidades > 0 \? i\.unidades/, 'unidadesDoItem prefere as unidades do banco')
const mig = readFileSync(new URL('../supabase/migrations/20261223000001_checkout_unidades_do_cliente.sql', import.meta.url), 'utf8')
assert.match(mig, /unidades_cliente/, 'unidades vêm do orçamento')
const camp = readFileSync(new URL('../supabase/migrations/20261223000002_checkout_campanha_de_volta.sql', import.meta.url), 'utf8')
assert.match(camp, /loja_campanha\(\)/, 'checkout_carregar devolve a campanha')
console.log('test-checkout: ok')
