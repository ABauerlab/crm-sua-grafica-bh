// Gera os PDFs de exemplo do orçamento em docs/exemplos-orcamento/ (Node >= 22; Playwright e Postgres local descartável).
// Uso: supabase/tests/rodar-local.sh && node scripts/gerar-exemplos-orcamento.ts [pasta-de-saida]
// Os dados são do catálogo FICTÍCIO de teste, não do fornecedor. O Gotenberg usa o mesmo Chromium, então o resultado é equivalente.
import { execFileSync } from 'node:child_process'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { orcamentoHtml, type OrcamentoDoc } from '../supabase/functions/_shared/orcamento-html.ts'

const { chromium } = createRequire(import.meta.url)('playwright')
const saida = process.argv[2] ?? 'docs/exemplos-orcamento'
mkdirSync(saida, { recursive: true })

const psql = execFileSync('psql', ['-h', '/tmp', '-p', '54329', '-U', 'postgres', '-d', 'gbh', '-At', '-f', 'scripts/exemplos-orcamento.sql'], { encoding: 'utf8' })
const json = psql.split('\n').find((l) => l.startsWith('[{'))
if (!json) throw new Error('A consulta não devolveu os exemplos:\n' + psql)
const exemplos = JSON.parse(json) as { nome: string; doc: OrcamentoDoc }[]

const browser = await chromium.launch()
for (const { nome, doc } of exemplos) {
  const page = await browser.newPage()
  await page.setContent(orcamentoHtml(doc), { waitUntil: 'networkidle', timeout: 15000 }).catch(() => page.waitForTimeout(500))
  const pdf = await page.pdf({ format: 'A4', printBackground: true, preferCSSPageSize: true })
  writeFileSync(`${saida}/${nome}.pdf`, pdf)
  writeFileSync(`${saida}/${nome}.json`, JSON.stringify(doc, null, 2))
  await page.close()
  console.log(`${nome}.pdf  ${(pdf.length / 1024).toFixed(0)} KB`)
}
await browser.close()
void readFileSync
