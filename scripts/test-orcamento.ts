// Testes locais do orçamento em PDF (Node >= 22): npm run test:orcamento
// Cobrem o modelo HTML (sem dados internos, escape, condição especial, frete, arte) e os PDFs de exemplo versionados.
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { existsSync, readdirSync, readFileSync } from 'node:fs'
import { esc, nomeArquivoOrcamento, orcamentoHtml, type OrcamentoDoc } from '../supabase/functions/_shared/orcamento-html.ts'

const base: OrcamentoDoc = {
  numero: 'SG-0007', versao: 1, data: '2026-10-29', validade_ate: '2026-10-31T18:00:00+00:00',
  cliente: { nome: 'Maria <b>Souza</b> & Filhos' },
  itens: [{ descricao: 'COUCHE BRILHO - 300g', especificacao: '1.000 un. · 300 g · 4X4 · 91 x 51 mm', quantidade: 1, valor_unitario: 153.9, valor_total: 153.9 }],
  subtotal: 153.9, arte: { modo: 'nenhuma', valor: 0, opcoes: [{ texto: 'Só a arte', valor: 39.9 }, { texto: 'Arte com frete grátis na região central', valor: 49.9 }] },
  frete: { modo: 'retirada', valor: 0 }, desconto: 0, total: 153.9, condicao_especial: null,
  data_prevista: '2026-11-05', prazo_inicio: '2026-10-30', hoje: '2026-10-29', corte_hora: 12,
  upsell: { tipo: 'cartao_adesivo_panfleto', texto: 'Que tal incluir adesivos ou panfletos?' },
  empresa: { nome: 'Sua Gráfica BH', cnpj: '58.481.181/0001-03', telefone: '(31) 97561-8243', email: 'contato@suagraficabh.com.br', instagram: null, site: null },
}
const html = (o: Partial<OrcamentoDoc> = {}) => orcamentoHtml({ ...base, ...o })

// escape: nada do cliente vira HTML
assert.equal(esc(`<script>"a" & 'b'</script>`), '&lt;script&gt;&quot;a&quot; &amp; &#39;b&#39;&lt;/script&gt;')
const h = html()
assert.ok(!h.includes('<b>Souza</b>') && h.includes('Maria &lt;b&gt;Souza&lt;/b&gt; &amp; Filhos'), 'nome do cliente escapado')

// conteúdo mínimo
for (const t of ['Orçamento SG-0007', '29/10/2026', '31/10/2026', 'R$ 153,90', 'CNPJ 58.481.181/0001-03', '(31) 97561-8243', 'Pix', 'cartão', 'Retirada grátis no centro de BH', 'depois da confirmação do pagamento'])
  assert.ok(h.includes(t), `falta "${t}"`)
assert.ok(h.includes('Se pagar e enviar a arte até 12h de 30/10, fica pronto em 05/11.'), 'prazo com data de calendário')
assert.ok(html({ prazo_inicio: '2026-10-29' }).includes('até 12h de hoje, fica pronto em 05/11'), 'prazo "hoje"')
assert.ok(h.includes('Precisa de arte?') && h.includes('R$ 39,90') && h.includes('R$ 49,90'), 'opções de arte quando ainda não há arte definida')
assert.ok(h.includes('Que tal incluir adesivos ou panfletos?'), 'upsell discreto')
assert.ok(!h.includes('Instagram') && !h.includes('undefined') && !h.includes('null'), 'campos ausentes não aparecem')
assert.ok(html({ empresa: { ...base.empresa, instagram: '@suagraficabh', site: 'suagraficabh.com.br' } }).includes('@suagraficabh · suagraficabh.com.br'), 'Instagram e site, quando existirem')

// sem dado interno nem endereço de retirada
const proibidos = /(\bsku\b|\bcusto\b|\bmargem\b|\bpiso\b|\blucro\b|fornecedor|rio de janeiro|sala 2|22º|30160)/i
for (const doc of [h, html({ frete: { modo: 'bike_gratis', valor: 0 } }), html({ frete: { modo: 'uber_cliente', valor: 0 } })]) assert.ok(!proibidos.test(doc), 'o HTML não pode conter dado interno nem endereço')

// frete
assert.ok(html({ frete: { modo: 'bike_gratis', valor: 0 } }).includes('Entrega (região central)'), 'frete grátis na região central')
const uber = html({ frete: { modo: 'uber_cliente', valor: 0 } })
assert.ok(uber.includes('Entrega por Uber') && uber.includes('por conta do cliente'), 'Uber por conta do cliente')

// arte
const comArte = html({ arte: { modo: 'paga', valor: 39.9, opcoes: null }, total: 193.8 })
assert.ok(comArte.includes('Criação de arte') && comArte.includes('R$ 39,90') && !comArte.includes('Precisa de arte?'), 'arte paga')
assert.ok(html({ arte: { modo: 'com_frete', valor: 49.9, opcoes: null } }).includes('Arte + frete grátis'), 'arte com frete')
assert.ok(html({ arte: { modo: 'paga', valor: 0, opcoes: null } }).includes('Grátis'), 'arte grátis por condição especial')

// condição especial: validade com data e hora de Brasília, valor final, sem explicar o cálculo
const cond = html({ condicao_especial: { valida_ate: '2026-10-30T18:30:00+00:00', tipo: 'desconto', total: 300.9, texto: 'Desconto especial já aplicado ao total' }, desconto: 10, total: 300.9, versao: 2 })
assert.ok(cond.includes('Condição especial válida até 30/10 às 15:30'), 'linha da condição especial')
assert.ok(cond.includes('Valor final: <b>R$ 300,90</b>') && cond.includes('versão 2'), 'valor final e versão')
assert.ok(!proibidos.test(cond) && !/gordura|degrau|percentual/i.test(cond), 'a condição não mostra como foi calculada')

// nome do arquivo e passos para fechar
assert.equal(nomeArquivoOrcamento('SG-0032', '2026-10-29'), 'Orcamento-SG-0032-29-10-2026.pdf')
assert.equal(nomeArquivoOrcamento('SG-0032<x>', '2026-01-05'), 'Orcamento-SG-0032x-05-01-2026.pdf', 'nome sem caracteres perigosos')
assert.ok(h.includes('Como fechar seu pedido') && h.includes('<title>Orcamento-SG-0007-29-10-2026</title>'))
assert.ok(html({ arte: { modo: 'paga', valor: 39.9, opcoes: null } }).includes('Ou aprove a que criamos para você.'))

// uma página para orçamento comum: 10 itens quebram sem cortar linha (page-break-inside: avoid)
assert.ok(html().includes('page-break-inside: avoid'))

// PDFs de exemplo versionados: 6 arquivos, até 2 páginas, leves e sem dado interno (confere só se o pdftotext existir)
const pasta = new URL('../docs/exemplos-orcamento/', import.meta.url).pathname
const pdfs = existsSync(pasta) ? readdirSync(pasta).filter((f) => f.endsWith('.pdf')) : []
assert.ok(pdfs.length >= 6, 'pelo menos 6 PDFs de exemplo em docs/exemplos-orcamento')
let temPdftotext = true
try {
  execFileSync('pdftotext', ['-v'], { stdio: 'ignore' })
} catch {
  temPdftotext = false
}
for (const f of pdfs) {
  const bytes = readFileSync(pasta + f)
  assert.ok(bytes.length < 400 * 1024, `${f} deve ser leve (< 400 KB)`)
  assert.ok(bytes.subarray(0, 4).toString() === '%PDF', `${f} não é PDF`)
  if (!temPdftotext) continue
  const texto = execFileSync('pdftotext', [pasta + f, '-'], { encoding: 'utf8' })
  assert.ok(!proibidos.test(texto), `${f} contém dado interno ou endereço de retirada`)
  assert.ok(!/\b(CFV|PFL|ADV)\d+/.test(texto), `${f} contém SKU`)
  assert.ok(/Orçamento SG-\d+/.test(texto) && texto.includes('58.481.181/0001-03'), `${f} sem número ou CNPJ`)
  const paginas = Number(/Pages:\s+(\d+)/.exec(execFileSync('pdfinfo', [pasta + f], { encoding: 'utf8' }))?.[1])
  assert.ok(paginas >= 1 && paginas <= 2, `${f} com ${paginas} páginas`)
}
console.log(`OK: modelo do orçamento (escape, arte, frete, condição especial, sem dado interno) e ${pdfs.length} PDFs de exemplo${temPdftotext ? '' : ' (pdftotext ausente: texto dos PDFs não conferido)'}`)
