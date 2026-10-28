// Testes do banco de conhecimento (sem banco): tamanho, tom, vazamento e cobertura das 20 categorias obrigatórias.
// A recuperação (40 perguntas) roda no banco: supabase/tests/conhecimento_recuperacao.sql.
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { AGENT_TEMPLATES } from '../src/lib/agent-templates.ts'
import { KNOWLEDGE_LIMITS, trechoPalavras, trechoProblemas, words, type Trecho } from '../src/lib/knowledge.ts'

const root = new URL('..', import.meta.url).pathname
const trechos: (Trecho & { slug: string; categoria: string; tags: string[]; revisar: boolean })[] = JSON.parse(readFileSync(`${root}supabase/seed/conhecimento.json`, 'utf8'))

// Cobertura: as 20 categorias do roteiro
const CATEGORIAS = ['abertura', 'qualificacao', 'compra', 'pagamento', 'prazos', 'arte', 'frete', 'guia', 'kits', 'upsell', 'objecoes', 'fechamento', 'pos_pagamento', 'dono', 'robo', 'sigilo', 'troca', 'empresa', 'followup', 'posvenda']
assert.deepEqual([...new Set(trechos.map((t) => t.categoria))].sort(), [...CATEGORIAS].sort(), 'todas as 20 categorias obrigatórias têm trecho')
assert.equal(new Set(trechos.map((t) => t.slug)).size, trechos.length, 'slugs únicos')
assert.ok(trechos.every((t) => t.revisar === true), 'todos os trechos nascem com revisar = true')

// Trechos obrigatórios por nome
const slugs = new Set(trechos.map((t) => t.slug))
for (const s of ['abertura-cartao', 'abertura-panfleto', 'abertura-adesivo', 'abertura-banner', 'abertura-kit-barbearia', 'abertura-kit-delivery', 'abertura-kit-loja', 'abertura-kit-lancamento',
  'obj-caro', 'obj-mais-barato', 'obj-vou-pensar', 'obj-prazo-curto', 'obj-confianca', 'obj-qualidade', 'obj-parcelar', 'obj-desconto', 'obj-ver-antes', 'obj-ir-ai',
  'robo-honesto', 'sigilo-regras', 'troca-reclamacao', 'empresa-endereco', 'fu-condicao-a', 'pv-recompra-cartao', 'frete-retirada', 'pos-pagamento', 'dono-regras']) {
  assert.ok(slugs.has(s), `trecho obrigatório ausente: ${s}`)
}
// Objeções que dependem do dono ficam marcadas
for (const s of ['pag-parcelar', 'obj-parcelar', 'troca-reclamacao']) assert.match(trechos.find((t) => t.slug === s)!.fatos ?? '', /\[CONFIRMAR\]/, `${s} precisa de [CONFIRMAR]`)

// Tom de referência do roteiro (frases-modelo)
const por = (s: string) => trechos.find((t) => t.slug === s)!
assert.equal(por('abertura-cartao').resposta_pronta, 'Oi! Aqui é a [Nome], da Sua Gráfica BH. Vi que você veio pelo anúncio de cartão de visita. É pra qual negócio?')
assert.equal(por('frete-retirada').resposta_pronta, 'A retirada é grátis, sim! Assim que o pagamento cair eu te passo o endereço e o horário certinho.')
assert.equal(por('obj-caro').resposta_pronta, 'Entendo! Posso te mostrar uma opção com acabamento mais simples, que fica mais em conta. Quer comparar as duas?')
assert.equal(por('robo-honesto').resposta_pronta, 'Sou o assistente virtual da Sua Gráfica BH, mas se preferir eu chamo o dono pra falar com você. Posso seguir por aqui?')
assert.match(por('obj-vou-pensar').resposta_pronta!, /\{\{validade\}\}/, 'a validade vem de variável')

// Lint de tamanho, tom e vazamento em TODOS os trechos
const falhas: string[] = []
for (const t of trechos) for (const m of trechoProblemas(t)) falhas.push(`${t.slug}: ${m}`)
assert.deepEqual(falhas, [], `trechos com problema:\n${falhas.join('\n')}`)

// O lint de verdade pega o que deve pegar
const ruim: Trecho = { titulo: 't', quando_usar: 'q', proximo_passo: 'p', resposta_pronta: 'Nosso custo é baixo — veja:\n- item um\n- item dois', fatos: 'A margem é boa, o fornecedor entrega em 3 dias. Cartão CFV02 por R$ 75,90.' }
const achados = trechoProblemas(ruim).join(' | ')
for (const re of [/travessão/, /lista/, /custo/, /margem/, /fornecedor/, /valor em reais/, /prazo escrito/, /código de produto/]) assert.match(achados, re, `o lint deveria acusar ${re}`)
assert.match(trechoProblemas({ ...ruim, resposta_pronta: 'a '.repeat(41), fatos: 'ok' }).join(), /resposta pronta passa de 40/)
assert.match(trechoProblemas({ titulo: 't', quando_usar: 'q', proximo_passo: 'p', resposta_pronta: 'ok', fatos: 'x '.repeat(130) }).join(), /passa de 120/)
assert.match(trechoProblemas({ titulo: 't', quando_usar: 'q', proximo_passo: 'p', resposta_pronta: 'Olá {{preco_custo}}', fatos: 'ok' }).join(), /variável desconhecida/)
assert.match(trechoProblemas({ titulo: 't', quando_usar: 'q', proximo_passo: 'p', resposta_pronta: 'Oi [CONFIRMAR]', fatos: 'ok' }).join(), /\[CONFIRMAR\]/)
assert.equal(words('  duas   palavras '), 2)
assert.deepEqual(trechoPalavras({ titulo: 't', quando_usar: 'a b', resposta_pronta: 'c d e', fatos: 'f', proximo_passo: 'g' }), { resposta: 3, fatos: 1, total: 7 })
assert.equal(KNOWLEDGE_LIMITS.total, 120)

// As mensagens que vão ao cliente (templates do WhatsApp) também não vazam custo, margem, piso nem fornecedor
const proibidas = /\b(custo|margem|piso|fornecedor)\b/i
for (const t of AGENT_TEMPLATES) assert.ok(!proibidas.test(`${t.body} ${t.name}`), `template ${t.name} cita termo interno`)

// Nenhum SKU do fornecedor nos textos ao cliente: o orçamento usa o número SG-0001
const ctx = readFileSync(`${root}docs/agente/00-contexto.md`, 'utf8')
assert.match(ctx, /SKU do fornecedor é INTERNO|SKU do fornecedor é interno/i)

// A tabela do fornecedor é PRIVADA: nenhum PDF nem arquivo derivado pode estar no repositório, e o .gitignore precisa bloquear
import { execFileSync } from 'node:child_process'
const rastreados = execFileSync('git', ['ls-files'], { cwd: root, encoding: 'utf8' }).split('\n').filter(Boolean)
const suspeitos = rastreados.filter((f) => /\.pdf$/i.test(f) || /(^|\/)(catalogo|tabela|importacao|linhas-sem-codigo|conflitos|rejeitadas)[-_].*\.(csv|json|xlsx?)$/i.test(f) || /dump-catalogo|\.catalogo\.sql$/i.test(f))
assert.deepEqual(suspeitos, [], `arquivo da tabela do fornecedor no repositório: ${suspeitos.join(', ')}`)
const ignorado = readFileSync(`${root}.gitignore`, 'utf8')
for (const padrao of ['*.pdf', 'catalogo-fornecedor/', 'catalogo-*.csv', 'tabela-fornecedor*', 'dump-catalogo*']) assert.ok(ignorado.includes(padrao), `.gitignore sem ${padrao}`)

console.log(`OK: ${trechos.length} trechos, 20 categorias, tamanho, tom e vazamento conferidos`)
