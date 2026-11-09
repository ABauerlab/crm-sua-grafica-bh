// Regras de preço e de transição do kanban (Node >= 22): npm run test:rules
import assert from 'node:assert/strict'
import { readdirSync, readFileSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { blockReason, DEFAULT_KANBAN, formatDuration, isStalled, metodoLabel, metodoValido, pedidoAtrasado } from '../src/lib/orders.ts'
import { DEFAULT_PRICING, previewNetProfit, priceAlerts, unitFloor } from '../src/lib/pricing.ts'
import { parseMoney } from '../src/lib/money.ts'
import { lockSeconds } from '../src/lib/lock.ts'
import { parsePdfPages, type PdfItem } from '../src/lib/catalog-pdf.ts'
import { buildProducts, extractGrammage, guessHeaderRow, guessMapping, readTable } from '../src/lib/spreadsheet.ts'
import { goalState, groupCampaigns, metrics } from '../src/lib/campaigns.ts'
import { AGENT_TEMPLATES, templateProblems } from '../src/lib/agent-templates.ts'
import { conferirLinhas, linhasDaPlanilha } from '../src/lib/planilha-precos.ts'

const fmt = (v: number) => `R$ ${v.toFixed(2)}`

// Piso = custo x 1,5
assert.equal(unitFloor(100, DEFAULT_PRICING), 150)
assert.equal(unitFloor(33.33, DEFAULT_PRICING), 50)

// Item abaixo do piso gera alerta; no piso não gera
const below = priceAlerts({ items: [{ description: 'Cartões', unit_cost: 100, unit_price: 149.99 }], discountPct: 0, netProfit: 500 }, DEFAULT_PRICING, fmt)
assert.deepEqual(below.map((a) => a.code), ['below_floor'])
const ok = priceAlerts({ items: [{ description: 'Cartões', unit_cost: 100, unit_price: 150 }], discountPct: 10, netProfit: 60 }, DEFAULT_PRICING, fmt)
assert.equal(ok.length, 0, 'no limite exato não alerta')

// Desconto acima de 10% e lucro abaixo de R$ 60
const many = priceAlerts({ items: [{ description: 'X', unit_cost: 10, unit_price: 20 }], discountPct: 10.5, netProfit: 59.99 }, DEFAULT_PRICING, fmt)
assert.deepEqual(many.map((a) => a.code).sort(), ['discount_too_high', 'profit_too_low'])

// Pedido sem itens não alerta lucro
assert.equal(priceAlerts({ items: [], discountPct: 0, netProfit: 0 }, DEFAULT_PRICING, fmt).length, 0)

// Lucro: total * (1 - 7,5%) - custo
assert.equal(previewNetProfit([{ qty: 2, unit_cost: 50, unit_price: 100 }], 0, 6, 1.5), 85)
assert.equal(previewNetProfit([{ qty: 1, unit_cost: 100, unit_price: 200 }], 10, 6, 1.5), 66.5)

// Transições
const base = { payment_status: 'pendente', payment_manual: false, art_status: 'aguardando' } as const
assert.match(blockReason(base, 'pago') ?? '', /pagamento/)
assert.equal(blockReason({ ...base, payment_status: 'aprovado' }, 'pago'), null)
assert.equal(blockReason({ ...base, payment_manual: true }, 'pago'), null, 'confirmação manual libera')
assert.match(blockReason(base, 'producao') ?? '', /arte/)
assert.equal(blockReason({ ...base, art_status: 'aprovada' }, 'producao'), null)
assert.equal(blockReason(base, 'cotando'), null)

// Pedidos parados
const now = Date.now()
const h = (n: number) => new Date(now - n * 3_600_000).toISOString()
assert.equal(isStalled({ stage: 'novo', stage_entered_at: h(5) }, DEFAULT_KANBAN, now), true)
assert.equal(isStalled({ stage: 'novo', stage_entered_at: h(3) }, DEFAULT_KANBAN, now), false)
assert.equal(isStalled({ stage: 'entregue', stage_entered_at: h(900) }, DEFAULT_KANBAN, now), false, 'limite 0 = sem alerta')
assert.equal(formatDuration(0.2), '12 min')
assert.equal(formatDuration(30), '30 h')
assert.equal(formatDuration(72), '3 d')

// Dinheiro digitado
assert.equal(parseMoney('1.234,56'), 1234.56)
assert.equal(parseMoney('12,5'), 12.5)
assert.equal(parseMoney('R$ 99'), 99)
assert.equal(parseMoney(''), 0)

// Bloqueio progressivo do login
assert.equal(lockSeconds(2), 0)
assert.equal(lockSeconds(3), 10)
assert.equal(lockSeconds(5), 40)
assert.equal(lockSeconds(20), 300)

// Campanhas: custo por conversa/venda, ROAS e lucro depois do anúncio
const m = metrics({ spend: 100, conversations: 20, quotes: 10, paid_orders: 4, revenue: 800, net_profit: 360 })
assert.equal(m.cpc, 5)
assert.equal(m.cps, 25)
assert.equal(m.roas, 8)
assert.equal(m.profitAfterAds, 260)
assert.equal(m.quoteRate, 50)
assert.equal(m.paidRate, 20)
assert.equal(metrics({ spend: 50, conversations: 0, quotes: 0, paid_orders: 0, revenue: 0, net_profit: 0 }).cpc, null, 'sem conversas não divide por zero')
assert.equal(metrics({ spend: 0, conversations: 3, quotes: 1, paid_orders: 1, revenue: 100, net_profit: 50 }).roas, null)
assert.equal(goalState('cost', 5, 6), 'good')
assert.equal(goalState('cost', 7, 6), 'bad')
assert.equal(goalState('roas', 4, 4), 'good')
assert.equal(goalState('roas', 3.9, 4), 'bad')
assert.equal(goalState('cost', null, 6), 'none')

const ad = (id: string, campaign: string, spend: number, paid: number, revenue: number) => ({
  ad_id: id, ad_name: id, adset_id: 's', adset_name: 's', campaign_id: campaign, campaign_name: `Campanha ${campaign}`, spend, impressions: 0, clicks: 0,
  meta_conversations: 0, conversations: 10, quotes: 5, paid_orders: paid, revenue, net_profit: revenue / 2,
})
const groups = groupCampaigns([ad('a1', 'X', 40, 1, 100), ad('a2', 'X', 60, 2, 300), ad('b1', 'Y', 10, 0, 0)], [
  { id: '1', day: '2026-10-01', campaign_name: 'campanha x', amount: 25, note: null },
  { id: '2', day: '2026-10-01', campaign_name: 'Panfleto de rua', amount: 80, note: null },
])
assert.equal(groups.length, 3)
assert.equal(groups[0].name, 'Campanha X')
assert.equal(groups[0].m.spend, 125, 'gasto da Meta (100) + manual de mesmo nome (25)')
assert.equal(groups[0].m.paid, 3)
assert.equal(groups.find((g) => g.name === 'Panfleto de rua')?.m.spend, 80, 'investimento manual sem anúncio vira linha própria')

// Planilha do fornecedor: .xlsx com título acima, cabeçalho com acentos e números
assert.equal(parseMoney('1.234'), 1234, 'ponto de milhar')
assert.equal(parseMoney('12.5'), 12.5)
assert.equal(parseMoney('1.234,56'), 1234.56)
const XLSX = await import('xlsx')
const wb = XLSX.utils.book_new()
XLSX.utils.book_append_sheet(
  wb,
  XLSX.utils.aoa_to_sheet([
    ['TABELA DE PREÇOS'],
    [],
    ['Código', 'Descrição do Produto', 'Categoria', 'Valor Custo', 'Preço de Venda'],
    ['CV-0500', 'Cartão de visita 500 un', 'Cartões', 48.5, 119],
    ['PF-1000', 'Panfleto A5 1.000 un', 'Panfletos', '95,00', ''],
  ]),
  'Tabela',
)
const buf = XLSX.write(wb, { type: 'array', bookType: 'xlsx' })
const rows = await readTable(new File([buf], 'tabela.xlsx'))
const hdr = guessHeaderRow(rows)
assert.equal(hdr, 1, 'o título (1 célula) é ignorado e o cabeçalho é a linha seguinte')
assert.deepEqual(rows[hdr], ['Código', 'Descrição do Produto', 'Categoria', 'Valor Custo', 'Preço de Venda'])
const map = guessMapping(rows[hdr])
assert.deepEqual(map, { code: 0, description: 1, category: 2, colors: -1, weight: -1, qty: -1, size: -1, lead: -1, cost: 3 })
assert.equal(rows[hdr + 1][3], '48.5')
await assert.rejects(() => readTable(new File(['x'], 'catalogo.doc')), /Formato não suportado/)

// Tabela de preços de fornecedor: HTML salvo como .xls em ISO-8859-1, título e cabeçalho repetido a cada categoria, preço "R$ 1.234,56"
const html = `<html><body><table>
<tr><td>TABELA DE PREÇOS 27/10/2026</td></tr>
<tr><td>ACESSÓRIOS</td></tr>
<tr><td>Código</td><td>Categoria</td><td>Descrição do Serviço</td><td>Cores</td><td>Peso</td><td>Qtde</td><td>Tam</td><td>Prazo</td><td>Preço R$</td></tr>
<tr><td>GIFT1</td><td>ACESSÓRIOS</td><td>CHAVEIRO UV - 10g</td><td>4X0</td><td>1250</td><td>25</td><td>57 x 57</td><td>5</td><td>R$ 1.252,99</td></tr>
<tr><td>GIFT2</td><td>ACESSÓRIOS</td><td>CHAVEIRO UV - 10g</td><td>4X0</td><td>500</td><td>10</td><td>57 x 57</td><td>5</td><td>R$ 106,99</td></tr>
<tr><td>ADESIVOS</td></tr>
<tr><td>Código</td><td>Categoria</td><td>Descrição do Serviço</td><td>Cores</td><td>Peso</td><td>Qtde</td><td>Tam</td><td>Prazo</td><td>Preço R$</td></tr>
<tr><td>ADE9</td><td>ADESIVOS</td><td>ADESIVO REDONDO</td><td>4X0</td><td>100</td><td>200</td><td>50 x 50</td><td>3</td><td>R$ 38,50</td></tr>
</table></body></html>`
const latin1 = new Uint8Array([...html].map((c) => c.charCodeAt(0)))
const sheetHtml = await readTable(new File([latin1], 'TabelaPreco.xls'))
const zh = guessHeaderRow(sheetHtml)
const zmap = guessMapping(sheetHtml[zh])
assert.equal(extractGrammage('CHAVEIRO UV - 10g'), 10)
assert.equal(extractGrammage('PANFLETO 150 g/m² COUCHE'), 150)
assert.equal(extractGrammage('CARTAO 300G LAM'), 300)
assert.equal(extractGrammage('ADESIVO 90 gramas'), 90)
assert.equal(extractGrammage('TAG 250gr'), 250)
assert.equal(extractGrammage('CADERNETA - CAPA COUCHÊ 250G - MIOLO AP 75G - 90g'), 90, 'vale o sufixo final')
assert.equal(extractGrammage('GIFT 4x0 gift'), null, 'sem número de gramatura')
assert.deepEqual(zmap, { code: 0, category: 1, description: 2, colors: 3, weight: 4, qty: 5, size: 6, lead: 7, cost: 8 }, 'cada coluna da planilha tem o seu campo; "Preço R$" do fornecedor é o custo')
const built = buildProducts(sheetHtml, zh, zmap)
assert.equal(built.items.length, 3, 'cabeçalho repetido, título e seções não viram produto')
assert.deepEqual(built.items[0], {
  n: 4, sku: 'GIFT1', categoria: 'ACESSÓRIOS', descricao: 'CHAVEIRO UV - 10g', cores: '4X0', peso_g: 1250, quantidade: 25, tamanho_mm: '57 x 57', prazo: 5, custo: 1252.99,
}, 'nada é comprimido dentro da descrição, os acentos em ISO-8859-1 ficam preservados e a linha guarda o número no arquivo')

// Linhas que não podem sumir: sem código entra como sem_sku; sem preço vai adiante para ser rejeitada com motivo
const rowsRaw = [
  ['Código', 'Categoria', 'Descrição do Serviço', 'Cores', 'Peso', 'Qtde', 'Tam', 'Prazo*', 'Preço'],
  ['PDV'],
  ['CFV02', 'CARTÕES DE VISITA', 'COUCHE BRILHO - 300g', '4X4', '1392', '1000', '91 x 51', '2', '75,99'],
  ['', 'PDV', 'DISPLAY POLIONDA', '4X0', '1500', '10', '300 x 400', '5', '99,90'],
  ['CFV99', 'CARTÕES DE VISITA', 'SEM PREÇO', '4X4', '1392', '1000', '91 x 51', '2', ''],
  ['Código', 'Categoria', 'Descrição do Serviço', 'Cores', 'Peso', 'Qtde', 'Tam', 'Prazo*', 'Preço'],
]
const pdvMap = guessMapping(rowsRaw[0])
const pdv = buildProducts(rowsRaw, 0, pdvMap)
assert.equal(pdv.items.length, 3, 'a linha sem código e a linha sem preço NÃO são descartadas')
assert.equal(pdv.items[1].sku, null, 'sem código = sem_sku, nunca inventar')
assert.equal(pdv.items[2].custo, null, 'sem preço vai com custo vazio para o servidor rejeitar com motivo')
assert.equal(pdv.skipped, 2, 'só o título da seção e o cabeçalho repetido são ignorados')
assert.equal(pdv.items[0].n, 3, 'número da linha no arquivo')

// PDF da tabela do fornecedor: colunas pelo cabeçalho, linha sem código, descrição quebrada em duas linhas e cabeçalho repetido por página
const mk = (y: number, cells: [number, string][]): PdfItem[] => cells.map(([x, str]) => ({ str, x, y, w: str.length * 4 }))
const pdfHead = (y: number) => mk(y, [[20, 'Código'], [70, 'Categoria'], [150, 'Descrição'], [185, 'do'], [195, 'Serviço'], [330, 'Cores'], [370, 'Peso'], [410, 'Qtde'], [450, 'Tam'], [500, 'Prazo*'], [540, 'Preço']])
const parsed = parsePdfPages([
  [...mk(800, [[20, 'Tabela emitida em 25/10/2026']]), ...pdfHead(780),
   ...mk(760, [[20, 'CFV02'], [70, 'CARTÕES DE VISITA'], [150, 'COUCHE BRILHO - 300g'], [330, '4X4'], [370, '1392'], [410, '1000'], [450, '91 x 51'], [500, '2'], [540, '75,99']]),
   ...mk(745, [[20, 'CFV02D'], [70, 'CARTÕES DE VISITA'], [150, 'COUCHE BRILHO - 300g'], [330, '4X4'], [370, '2784'], [410, '2000'], [450, '91 x 51'], [500, '2'], [540, '1.143,99']]),
   ...mk(730, [[70, 'PDV'], [150, 'DISPLAY POLIONDA GRANDE'], [330, '4X0'], [370, '1500'], [410, '10'], [450, '300 x 400'], [500, '5'], [540, '99,90']]),
   ...mk(722, [[150, 'COM SUPORTE']]),
   ...mk(700, [[20, 'ADESIVOS']])],
  [...pdfHead(780),
   ...mk(760, [[20, 'ADV01'], [70, 'ADESIVOS'], [150, 'ADESIVO VINIL'], [330, '4X0'], [370, '100'], [410, '200'], [450, '50 x 50'], [500, '3'], [540, 'R$ 38,50']])],
])
assert.equal(parsed.rows.length, 5, 'cabeçalho + 4 linhas de dados (o cabeçalho repetido na página 2 não duplica)')
assert.equal(parsed.candidatas, 4, 'conferência: 4 linhas terminam em preço')
assert.equal(parsed.rows.length - 1, parsed.candidatas, 'total lido = total de linhas com preço')
assert.deepEqual(parsed.rows[1], ['CFV02', 'CARTÕES DE VISITA', 'COUCHE BRILHO - 300g', '4X4', '1392', '1000', '91 x 51', '2', '75,99'])
assert.equal(parsed.rows[2][8], '1.143,99')
assert.equal(parsed.rows[3][0], '', 'linha sem código no PDF fica com código vazio')
assert.equal(parsed.rows[3][2], 'DISPLAY POLIONDA GRANDE COM SUPORTE', 'descrição quebrada em duas linhas volta a uma só')
assert.equal(parsed.emitidoEm, '2026-10-25')
assert.equal(parsed.titulos, 1, 'o título de seção (ADESIVOS) é só título; a linha da data fica acima do cabeçalho')
const pdfMap = guessMapping(parsed.rows[0])
assert.deepEqual(pdfMap, { code: 0, category: 1, description: 2, colors: 3, weight: 4, qty: 5, size: 6, lead: 7, cost: 8 }, 'o cabeçalho do PDF é reconhecido pela tela de importação')
const pdfBuilt = buildProducts(parsed.rows, 0, pdfMap)
assert.deepEqual(pdfBuilt.items.map((i) => [i.sku, i.custo]), [['CFV02', 75.99], ['CFV02D', 1143.99], [null, 99.9], ['ADV01', 38.5]])

// Templates do agente: 11 templates, nomes únicos e regras da Meta para o corpo (sem variável no começo ou no fim)
assert.equal(AGENT_TEMPLATES.length, 11)
assert.equal(new Set(AGENT_TEMPLATES.map((t) => t.name)).size, 11, 'nomes únicos')
for (const t of AGENT_TEMPLATES) assert.deepEqual(templateProblems(t), [], `template ${t.name}`)
assert.deepEqual(templateProblems({ ...AGENT_TEMPLATES[0], body: '{{1}} começou com variável' }).slice(0, 1), ['começa com variável'])
assert.deepEqual(AGENT_TEMPLATES.filter((t) => t.category === 'MARKETING').map((t) => t.name).sort(),
  ['condicao_especial_orcamento', 'orcamento_vence_hoje', 'recompra_lembrete', 'ultima_chance_orcamento'])

// Regra do negócio: o nome do fornecedor nunca aparece no código, nas telas, nos textos, nas mensagens nem na documentação.
// (O termo é montado em partes para este arquivo não se acusar.)
// Variações de grafia: separadores (ponto, traço, sublinhado, asterisco) e o "a" trocado por 4 ou @. Espaços ficam de fora de propósito (falso positivo em "faz a prova").
const sep = '[._\\-*]{0,2}'
const forbidden = new RegExp(['z', sep, '[a4@]', sep, 'p'].join('') + '(?!pier)', 'i')
const root = new URL('..', import.meta.url).pathname
const skip = new Set(['node_modules', '.git', 'dist', '.next', 'package-lock.json'])
const textExt = /\.(ts|tsx|js|cjs|mjs|json|md|sql|toml|html|css|svg|example|txt|csv|yml|yaml|xml|sh|webmanifest)$/
const leaks: string[] = []
const walk = (dir: string) => {
  for (const name of readdirSync(dir)) {
    if (skip.has(name)) continue
    const full = join(dir, name)
    if (statSync(full).isDirectory()) walk(full)
    else if (textExt.test(name) || name === '.env.example') {
      const text = readFileSync(full, 'utf8')
      if (forbidden.test(text) || forbidden.test(name)) leaks.push(full.replace(root, ''))
    }
  }
}
walk(root)
assert.deepEqual(leaks, [], `nome do fornecedor encontrado em: ${leaks.join(', ')}`)
// O detector pega as variações de grafia e não acusa texto comum 
for (const v of ['z', 'Z'].flatMap((z) => [`${z}ap`, `${z}.a.p`, `${z}-4-p`, `${z}_a_p`])) assert.ok(forbidden.test(`fornecedor ${v} aqui`), `deveria acusar ${v}`)
for (const ok of ['faz a prova', 'pizza pronta', 'zona de risco', 'caza paga']) assert.ok(!forbidden.test(ok), `não deveria acusar ${ok}`)
// Documentos exigidos existem e a lista de exceções é só a de pastas geradas
for (const f of ['docs/agente/decisoes-e-melhorias.md']) assert.ok(statSync(join(root, f)).isFile(), `falta ${f}`)

// Atraso (Etapa 7B): só em produção, não entregue e fora do prazo útil. Antes da produção nunca é atrasado.
const hoje = '2026-11-05'
assert.equal(pedidoAtrasado({ stage: 'producao', due_date: '2026-11-04', delivered_at: null }, hoje), true)
assert.equal(pedidoAtrasado({ stage: 'producao', due_date: '2026-11-05', delivered_at: null }, hoje), false, 'no dia do prazo ainda não é atraso')
for (const stage of ['novo', 'cotando', 'aguardando_pagamento', 'pago', 'arte', 'prova'] as const) assert.equal(pedidoAtrasado({ stage, due_date: '2026-10-01', delivered_at: null }, hoje), false, `${stage} nunca é atrasado`)
assert.equal(pedidoAtrasado({ stage: 'producao', due_date: '2026-10-01', delivered_at: '2026-11-01T10:00:00Z' }, hoje), false, 'entregue não é atrasado')
assert.equal(pedidoAtrasado({ stage: 'producao', due_date: null, delivered_at: null }, hoje), false)

// Pedido manual: método explícito. "manual" legado e vazio não valem.
assert.equal(metodoValido('pix'), true)
assert.equal(metodoValido('manual'), false)
assert.equal(metodoValido(''), false)
assert.equal(metodoValido(null), false)
assert.equal(metodoLabel('dinheiro'), 'Dinheiro')

// A trava de lucro de todos os caminhos tem teste SQL próprio (npm run test:sql) e ele cobre cada caminho exigido
const trava = readFileSync(new URL('../supabase/tests/trava_lucro_caminhos.sql', import.meta.url), 'utf8')
for (const caminho of ['preço unitário', 'orçamento:', 'condição especial', 'link:', 'pedido manual', 'importação do catálogo']) assert.ok(trava.includes(caminho), `trava_lucro_caminhos.sql precisa cobrir: ${caminho}`)

// Planilha oficial de preços de venda: cabeçalho achado abaixo de títulos, colunas de fórmula ignoradas, travas conferidas
{
  const cab = ['Código (SKU)', 'Categoria', 'Descrição do Serviço', 'Cores', 'Formato / Tamanho', 'Quantidade', 'Prazo Fábrica (dias)', 'Prazo Cliente (+1 dia)', 'Peso Total (g)', 'Peso Frete (kg)', 'Tipo Embalagem', 'Embalagem (C x L x A cm)', 'Preço de Custo Total (R$)', 'Custo Unitário (R$)', 'Preço de Mercado Estimado (R$)', 'Preço de Venda Sugerido Total (R$)', 'Preço de Venda Unitário (R$)', 'Lucro Bruto (R$)', 'Margem Bruta (%)', 'Markup Multiplicador', 'Estratégia de Preço']
  const linha = (sku: string, custo: number, venda: number) => [sku, 'CARTÕES DE VISITA', 'COUCHE 300g', '4x4', '91 x 51', 1000, 2, 3, 1392, '=ROUND(I2/1000, 2)', 'Pacote / Caixa', '16 x 11 x 17', custo, '=M2/F2', 164.9, venda, '=P2/F2', '=P2-M2', '=1', '=1', 'Volume B2B']
  const t = linhasDaPlanilha([['Título da planilha'], [], cab, linha('cfv02', 75.99, 151.9), linha('X1', 100, 140.9), linha('X2', 10, 70.5), ['', '', '']])
  assert.equal(t.length, 3, 'linha sem SKU é ignorada')
  assert.equal(t[0].sku, 'CFV02')
  assert.equal(t[0].cores, '4X4')
  assert.equal(t[0].preco_venda, 151.9)
  assert.equal(t[0].prazo_cliente_dias, 3)
  const r = conferirLinhas([...t, t[0]])
  assert.equal(r.resumo.duplicados, 1)
  assert.equal(r.resumo.abaixo_do_piso, 1, 'X1 está abaixo de custo x 1,5')
  assert.equal(r.resumo.lucro_bruto_abaixo_do_minimo, 2, 'X1 e X2 têm lucro bruto menor que R$ 65')
  assert.equal(r.resumo.sem_terminacao_90, 1, 'X2 não termina em ,90')
  assert.throws(() => linhasDaPlanilha([['sem cabeçalho']]), /Código/)
}

console.log('OK: regras de preço, transições do kanban, pedidos parados, login, campanhas, importação de planilha e sigilo do fornecedor')
