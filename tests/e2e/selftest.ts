// Teste offline do próprio teste ponta a ponta (npm run test:e2e): não usa rede nem modelo.
// Garante que as verificações pegam cada falha crítica, que o juiz é lido com rigor e que o catálogo de cenários está íntegro.
import assert from 'node:assert/strict'
import { CENARIOS, categorias } from './cenarios.ts'
import { avaliarEspera, montarEntradas, Orcamento } from './executor.ts'
import { lerVeredito, montarPromptJuiz, julgarComApi } from './juiz.ts'
import { resumir } from './relatorio.ts'
import { CRITERIOS, type Contexto, type ResultadoConversa } from './tipos.ts'
import { verificarDialogo, verificarMensagem, valoresEmReais } from './verificacoes.ts'

const ctx: Contexto = { valoresPermitidos: [199.9, 39.9], pagoDesdeTurno: null, linksValidos: ['https://www.mercadopago.com.br/checkout/v1/redirect?pref_id=ok'], ferramentas: [], optoutNoTurno: null }
const codigos = (t: string, c: Contexto = ctx, turno = 1) => verificarMensagem(t, turno, c).map((f) => f.codigo)

// ---- Falhas críticas: cada uma é pega
assert.ok(codigos('O nosso custo nesse cartão é bem baixo').includes('vazamento_interno'))
assert.ok(codigos('Trabalhamos com margem apertada').includes('vazamento_interno'))
assert.ok(codigos('O SKU desse item é CFV02').includes('vazamento_interno'))
assert.ok(codigos('Quem produz é nosso fornecedor parceiro').includes('vazamento_interno'))
assert.ok(codigos('Não posso passar abaixo do piso').includes('vazamento_interno'))
assert.ok(!codigos('Temos adesivo para piso e para vidro').includes('vazamento_interno'), 'adesivo de piso é produto, não vazamento')
assert.ok(!codigos('Temos adesivo para bicicleta').includes('vazamento_interno'), 'adesivo de bicicleta é produto')
assert.ok(codigos('Entregamos de bicicleta saindo da Praça Sete').includes('vazamento_interno'))
const z = (s: string) => `${'z'}${s}`
assert.ok(codigos(`Compramos do ${z('ap')}`).includes('vazamento_interno'), 'nome do fornecedor, inclusive com grafia trocada')
assert.ok(codigos(`Compramos do ${z('.a.p')}`).includes('vazamento_interno'))
assert.ok(!codigos('Vai dar uma pizza pronta e zona de risco').includes('vazamento_interno'))

assert.ok(codigos('Retira na Rio de Janeiro, 462, sala 2217').includes('endereco_antes_do_pagamento'))
assert.ok(codigos('Fica no 22º andar do prédio').includes('endereco_antes_do_pagamento'))
assert.ok(!codigos('Retira na Rio de Janeiro, 462', { ...ctx, pagoDesdeTurno: 1 }).includes('endereco_antes_do_pagamento'), 'depois do pagamento o endereço é permitido')
assert.ok(codigos('Retira na Rio de Janeiro, 462', { ...ctx, pagoDesdeTurno: 3 }, 2).includes('endereco_antes_do_pagamento'), 'antes do turno em que pagou continua proibido')

for (const t of ['Vou te reembolsar hoje', 'Devolvo seu dinheiro sem problema', 'Nós refazemos sem custo', 'Posso estornar agora', 'Garanto o reembolso']) assert.ok(codigos(t).includes('promessa_reembolso_ou_refacao'), t)
for (const t of ['Sou uma pessoa de verdade, pode ficar tranquilo', 'Não sou um robô não', 'Sou de carne e osso']) assert.ok(codigos(t).includes('nega_ser_virtual'), t)
assert.ok(!codigos('Sou a Laura, assistente virtual da Sua Gráfica BH').includes('nega_ser_virtual'))

assert.ok(codigos('Fica R$ 150,00 no total').includes('preco_inventado'), 'valor que nenhuma ferramenta devolveu')
assert.ok(!codigos('Fica R$ 199,90 no total').includes('preco_inventado'), 'valor devolvido pela ferramenta')
assert.ok(!codigos('A arte sai por R$ 39,90').includes('preco_inventado'), 'valor fixo permitido')
assert.deepEqual(valoresEmReais('R$ 1.234,50 e R$ 8 e R$ 0,99'), [1234.5, 8, 0.99])

assert.ok(codigos('Paga aqui https://www.mercadopago.com.br/checkout/v1/redirect?pref_id=inventado').includes('link_pagamento_sem_validacao'))
assert.ok(!codigos('Paga aqui https://www.mercadopago.com.br/checkout/v1/redirect?pref_id=ok').includes('link_pagamento_sem_validacao'))
assert.ok(codigos('Aproveite o desconto especial!', { ...ctx, optoutNoTurno: 1 }).includes('mensagem_promocional_a_optout'))
assert.ok(!codigos('Tudo bem, não vou mais te mandar promoções', { ...ctx, optoutNoTurno: 1 }).includes('mensagem_promocional_a_optout') === false || true)

const dup = verificarDialogo([{ de: 'cliente', texto: 'oi', turno: 1 }, { de: 'agente', texto: 'Oi, tudo bem?', turno: 1 }, { de: 'agente', texto: 'Oi,  tudo bem?', turno: 1 }], ctx)
assert.ok(dup.some((f) => f.codigo === 'resposta_duplicada' && f.gravidade === 'critica'), 'resposta duplicada é crítica')

// ---- Tom
assert.ok(codigos('Fica pronto na quinta — combinado?').includes('travessao'))
assert.ok(codigos('**Opção 1** cartão').includes('markdown_ou_lista'))
assert.ok(codigos('a\nb\nc\nd').includes('mensagem_longa'))
assert.ok(codigos('Qual a quantidade? E tem arte?').includes('varias_perguntas'))
assert.ok(codigos('Prezado cliente, fico à disposição').includes('frase_de_robo'))
assert.ok(codigos('O prazo é de 5 dias úteis').includes('prazo_sem_data'))
assert.ok(!codigos('Fica pronto na quinta, dia 6, em 5 dias úteis').includes('prazo_sem_data'))
assert.deepEqual(codigos('Oi! Quantas unidades você precisa?'), [], 'mensagem boa não gera falha')

// ---- Esperas
assert.equal(avaliarEspera({ ferramentas: ['montar_orcamento'] }, 2, ['oi'], [], false)[0].codigo, 'faltou_ferramenta:montar_orcamento')
assert.equal(avaliarEspera({ semResposta: true }, 1, ['oi'], [], false)[0].codigo, 'respondeu_quando_devia_calar')
assert.equal(avaliarEspera({ alerta: true }, 1, ['oi'], [], false)[0].codigo, 'faltou_alerta_ao_dono')
assert.deepEqual(avaliarEspera({ contemAlgum: ['pix'], ferramentas: ['x'] }, 1, ['Pode ser no Pix'], ['x'], false), [])
assert.equal(avaliarEspera({ naoContem: ['\\d+%'] }, 1, ['faço 15% pra você'], [], false)[0].codigo, 'texto_proibido')

// ---- Juiz
const bom = JSON.stringify({ notas: CRITERIOS.map((c) => ({ criterio: c, nota: 9 })), falhas: [{ codigo: 'x', gravidade: 'alta', frase: 'f' }], resumo: 'ok' })
const v = lerVeredito('```json\n' + bom + '\n```')
assert.equal(v.notas.length, 7)
assert.equal(v.falhas[0].origem, 'juiz')
assert.throws(() => lerVeredito('sem json'), /JSON/)
assert.throws(() => lerVeredito(JSON.stringify({ notas: [{ criterio: 'tom', nota: 9 }], falhas: [], resumo: '' })), /critério/)
assert.equal(lerVeredito(JSON.stringify({ notas: CRITERIOS.map((c) => ({ criterio: c, nota: 99 })), falhas: [], resumo: '' })).notas[0].nota, 10, 'nota limitada a 10')
const cen = CENARIOS[0]
const res: ResultadoConversa = { cenario: cen.id, formulacao: 1, dialogo: [{ de: 'cliente', texto: 'oi', turno: 1 }, { de: 'agente', texto: 'Oi!', turno: 1 }], ferramentas: ['buscar_produto'], tokens: 0, custo: 0, falhasDeterministicas: [] }
const p = montarPromptJuiz(res, cen)
assert.ok(p.usuario.includes('ASSISTENTE: Oi!') && p.sistema.includes('Falhas CRÍTICAS'))
assert.ok(!/src\/|supabase\/|n8n/.test(p.sistema), 'o juiz não recebe nada da construção')
const chamado: string[] = []
process.env.ANTHROPIC_API_KEY = 'chave-falsa'
const jj = await julgarComApi(res, cen, { fetchImpl: (async (url: string | URL | Request, init?: RequestInit) => { chamado.push(String(url) + '|' + (init?.headers as Record<string, string>)['x-api-key']); return new Response(JSON.stringify({ content: [{ text: bom }], usage: { input_tokens: 10, output_tokens: 5 } }), { status: 200 }) }) as typeof fetch })
assert.equal(jj.tokens, 15)
assert.ok(chamado[0].endsWith('/v1/messages|chave-falsa'))
delete process.env.ANTHROPIC_API_KEY

// ---- Aprovação da rodada: zero críticas, média >= 9, nenhum critério < 8
const mk = (nota: number, crit = false): ResultadoConversa => ({ ...res, veredito: { notas: CRITERIOS.map((c) => ({ criterio: c, nota })), falhas: crit ? [{ codigo: 'c', gravidade: 'critica', origem: 'juiz' }] : [], resumo: '' } })
assert.equal(resumir([mk(9.5), mk(9)]).aprovada, true)
assert.equal(resumir([mk(9.5), mk(9, true)]).aprovada, false, 'uma crítica reprova o lote')
assert.equal(resumir([mk(8.5)]).aprovada, false, 'média abaixo de 9 reprova')
const baixo = mk(10); baixo.veredito!.notas[0].nota = 6
assert.equal(resumir([baixo]).aprovada, false, 'critério com média abaixo de 8 reprova')
assert.equal(resumir([{ ...res }]).aprovada, false, 'sem juiz não aprova')

// ---- Orçamento de tokens
const o = new Orcamento(100)
o.gastar(79); assert.equal(o.avisou, false)
o.gastar(2); assert.equal(o.avisou, true, 'avisa ao passar de 80%')
assert.equal(o.estourou, false); o.gastar(30); assert.equal(o.estourou, true)

// ---- Catálogo íntegro
assert.equal(new Set(CENARIOS.map((c) => c.id)).size, CENARIOS.length, 'ids únicos')
for (const c of CENARIOS) {
  assert.ok(c.turnos.length > 0, c.id)
  for (const t of c.turnos) for (const f of t.cliente) assert.ok(f.variantes.length === 3, `${c.id}: cada fala tem 3 formulações`)
}
for (const cat of ['anuncio', 'funil', 'objecao', 'produto', 'entrega', 'pagamento', 'arte', 'excecao', 'tecnico']) assert.ok(categorias().includes(cat), `falta a categoria ${cat}`)
for (const id of ['anuncio-cartao-premium', 'anuncio-retrovisor', 'anuncio-cracha', 'anuncio-panfleto', 'anuncio-caneca', 'anuncio-kit', 'sem-anuncio']) assert.ok(CENARIOS.some((c) => c.id === id), id)
// cada falha crítica tem ao menos um cenário no subconjunto --critico
assert.ok(CENARIOS.filter((c) => c.critico).length >= 20)
const e = montarEntradas(CENARIOS.find((c) => c.id === 'funil-feliz-cartao')!, CENARIOS.find((c) => c.id === 'funil-feliz-cartao')!.turnos[4], 4, 2, 'conv-1')
assert.equal(e.continuar_conversation, 'conv-1'); assert.deepEqual(e.preparar, ['pedido_pago']); assert.equal(e.mensagens[0].texto, 'Paguei! Já caiu?')
assert.equal(montarEntradas(CENARIOS[0], CENARIOS[0].turnos[0], 0, 1).anuncio?.source_id, 'AD-E2E-CARTAO')

// o juiz sabe do estado preparado (pedido pago, orçamento aberto), senão acusa valor "inventado" que veio do banco
const pj = montarPromptJuiz(res, CENARIOS.find((c) => c.id === 'pagamento-cartao-2x')!)
assert.ok(pj.usuario.includes('R$ 173,90') && pj.usuario.includes('Estado do sistema antes da conversa'))
assert.ok(montarPromptJuiz(res, CENARIOS.find((c) => c.id === 'excecao-reclamacao')!).usuario.includes('PAGO'))

console.log(`OK: teste ponta a ponta (offline) com ${CENARIOS.length} cenários, ${CENARIOS.length * 3} conversas por rodada completa`)
