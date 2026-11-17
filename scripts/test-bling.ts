// Fase 6 (Bling e marketplaces): assinatura do webhook e textos de anúncio. npm run test:bling
import assert from 'node:assert/strict'
import { createHash, createHmac } from 'node:crypto'
import { corpoMeta, eventoMeta, sha256 } from '../supabase/functions/_shared/meta.ts'
import { lerNota, notaEmitida, rotuloSituacaoNota, escolherFormaPagamento, parcelasComForma, bloqueios, celularBling, corpoContato, ehServicoDeArte, ncmSugerido, corpoProduto, extrairCodigo, textoErroBling } from '../supabase/functions/_shared/bling-envio.ts'
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

// ---- envio ao Bling: bloqueios, corpos e leitura do código de autorização
assert.deepEqual(bloqueios(['cpf_ou_cnpj', 'cep', 'email']), [], 'dados fiscais incompletos não impedem o envio (viram aviso)')
assert.deepEqual(bloqueios(['nome', 'ncm_de_item', 'cep']), ['ncm_de_item'], 'sem nome vai com nome provisório')
assert.deepEqual(bloqueios(['pedido_nao_pago']), ['pedido_nao_pago'])
const ct = corpoContato({ nome: 'Maria', codigo: 'SG-1', numeroDocumento: '', tipo: 'F', indicadorIe: 9, ie: null, celular: '5531999998888', email: '', endereco: { geral: { endereco: 'Rua A', numero: '', cep: '30130000' } } })
assert.equal(ct.numeroDocumento, undefined, 'campos vazios saem do corpo')
assert.equal(ct.email, undefined)
assert.deepEqual((ct.endereco as any).geral, { endereco: 'Rua A', cep: '30130000' })
assert.equal(ct.celular, '31999998888', 'o 55 do país não vai ao Bling')
assert.equal(celularBling('5531971494800'), '31971494800')
assert.equal(celularBling('553132232356'), '3132232356')
assert.equal(celularBling('31 97149-4800'), '31971494800')
assert.equal(celularBling('12345'), undefined, 'número que não fecha não vai')
assert.equal(corpoContato({ nome: 'X', celular: '999' }).celular, undefined)
const pr = corpoProduto({ codigo: 'CV4X11000C', descricao: 'Cartão de visita 4x1 1000un', valor: 150.5, unidade: 'UN', ncm: '4911.99.00', origem: 0 })
assert.deepEqual((pr as any).tributacao, { origem: 0, ncm: '49119900' })
assert.equal((pr as any).codigo, 'CV4X11000C')
assert.equal((corpoProduto({ codigo: 'X', valor: 1, ncm: '123' }) as any).tributacao.ncm, undefined, 'NCM inválido não vai')
assert.deepEqual(extrairCodigo('https://suagraficabh.com.br/?code=abc123DEF456ghi789&state=xyz'), { code: 'abc123DEF456ghi789', state: 'xyz' })
assert.deepEqual(extrairCodigo('abc123DEF456ghi789jk'), { code: 'abc123DEF456ghi789jk' })
assert.equal(extrairCodigo('oi'), null)
assert.match(textoErroBling({ status: 400, data: { error: { type: 'VALIDATION_ERROR', description: 'Dados inválidos', fields: [{ msg: 'NCM obrigatório' }] } } }), /Dados inválidos \(NCM obrigatório\)/)
assert.equal(textoErroBling({ status: 500, data: {} }), 'HTTP 500')
assert.equal(ncmSugerido('Placa Cemass'), '39269090')
assert.equal(ncmSugerido('Placa Iracema FRENTE E VERSO'), '39269090')
assert.equal(ncmSugerido('CARTÕES DE VISITA COUCHÊ 250G LAMINAÇÃO'), '49119900')
assert.equal(ncmSugerido('Jornal 12 páginas'), '49111090')
assert.equal(ncmSugerido('Serviço qualquer'), undefined)
assert.equal(ehServicoDeArte('Criação de arte básica'), true)
assert.equal(ehServicoDeArte('Placa Mr Barbosa'), false)
console.log('OK: envio ao Bling (bloqueios, corpos, código de autorização, erros)')

// ---- forma de pagamento do pedido no Bling (vai na parcela e daí para a NF-e)
{
  const formas = [
    { id: 1, descricao: 'Dinheiro', tipoPagamento: 1, situacao: 1 },
    { id: 2, descricao: 'Cartão de Crédito', tipoPagamento: 3, situacao: 1 },
    { id: 3, descricao: 'Cartão de Débito', tipoPagamento: 4, situacao: 1 },
    { id: 4, descricao: 'PIX', tipoPagamento: 17, situacao: 1 },
    { id: 5, descricao: 'Pix antigo', tipoPagamento: 17, situacao: 0 },
  ]
  assert.equal(escolherFormaPagamento(formas, 'pix'), 4, 'Pix pelo nome, ignorando forma inativa')
  assert.equal(escolherFormaPagamento(formas, 'cartao_credito'), 2)
  assert.equal(escolherFormaPagamento(formas, 'cartao'), 2, 'método antigo "cartao" vale crédito')
  assert.equal(escolherFormaPagamento(formas, 'cartao_debito'), 3)
  assert.equal(escolherFormaPagamento([{ id: 9, descricao: 'Outros meios', tipoPagamento: 17, situacao: 1 }], 'pix'), 9, 'sem nome claro, cai no tipo da NF-e')
  assert.equal(escolherFormaPagamento(formas, 'outro'), undefined)
  assert.equal(escolherFormaPagamento([], 'pix'), undefined)
  const par = parcelasComForma([{ valor: 78.9, dataVencimento: '2026-11-17' }], 4, 'pix')
  assert.deepEqual(par[0].formaPagamento, { id: 4 })
  assert.equal(parcelasComForma([{ valor: 1 }], undefined, 'pix')[0].formaPagamento, undefined, 'sem forma achada não manda id 0')
}

// ---- nota fiscal do pedido lida do Bling (NFC-e ou NF-e)
{
  const n = lerNota({ data: { numero: '000071', situacao: 5, chaveAcesso: '31261158481181000103650010000000711384476170' } })
  assert.deepEqual(n, { numero: '71', situacao: 5, chave: '31261158481181000103650010000000711384476170' }, 'número sem zeros à esquerda')
  assert.equal(lerNota({ data: { numero: '', situacao: 5 } }), null, 'sem número não é nota')
  assert.equal(lerNota(null), null)
  assert.equal(lerNota({ data: { numero: '12', situacao: 6, chaveAcesso: 'curta' } })?.chave, null, 'chave inválida é ignorada')
  assert.equal(notaEmitida(5) && notaEmitida(6), true)
  assert.equal(notaEmitida(4) || notaEmitida(1) || notaEmitida(2) || notaEmitida(9), false, 'rejeitada, pendente, cancelada e denegada não contam como emitida')
  assert.equal(rotuloSituacaoNota(4), 'Rejeitada')
}
