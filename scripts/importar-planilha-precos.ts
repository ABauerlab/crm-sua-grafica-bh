// Carga da planilha oficial de preços de venda no catálogo (preço de venda, prazo, peso, embalagem).
// A planilha NUNCA entra no repositório: passe o caminho do arquivo local.
//
// Conferir sem enviar nada:
//   node scripts/importar-planilha-precos.ts /caminho/planilha.xlsx --conferir
// Enviar com a service role (nunca grave a chave em arquivo; só na variável de ambiente da sessão):
//   SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... node scripts/importar-planilha-precos.ts /caminho/planilha.xlsx
// No dia a dia o dono importa pela tela Catálogo > Produtos > "Importar planilha de preços".
import { readFileSync } from 'node:fs'
import * as XLSX from 'xlsx'
import { linhasDaPlanilha, conferirLinhas } from '../src/lib/planilha-precos.ts'

const arquivo = process.argv[2]
if (!arquivo) {
  console.error('Uso: node scripts/importar-planilha-precos.ts <planilha.xlsx> [--conferir]')
  process.exit(1)
}
const wb = XLSX.read(readFileSync(arquivo), { type: 'buffer' })
const aba = wb.SheetNames.find((n) => /pre[cç]os de venda/i.test(n)) ?? wb.SheetNames[0]
const tabela = XLSX.utils.sheet_to_json<unknown[]>(wb.Sheets[aba], { header: 1, raw: true, defval: '' })
const linhas = linhasDaPlanilha(tabela)
const r = conferirLinhas(linhas)
console.log(JSON.stringify({ aba, ...r.resumo }, null, 2))
if (r.problemas.length) console.log('Exemplos de problemas:', r.problemas.slice(0, 10))
if (process.argv.includes('--conferir')) process.exit(0)

const url = process.env.SUPABASE_URL
const key = process.env.SUPABASE_SERVICE_ROLE_KEY
const token = null
if (!url || !key) {
  console.error('Defina SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY.')
  process.exit(1)
}
const rpc = async (fn: string, body: unknown) => {
  const res = await fetch(`${url}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  })
  const txt = await res.text()
  if (!res.ok) throw new Error(`${fn}: ${res.status} ${txt.slice(0, 300)}`)
  return JSON.parse(txt)
}
const LOTE = 2000
for (let i = 0; i < linhas.length; i += LOTE) {
  const out = await rpc('importar_precos_planilha', { p_linhas: linhas.slice(i, i + LOTE), p_token: token })
  console.log(`lote ${i / LOTE + 1}: ${out.gravadas} gravadas (${out.na_staging} na staging)`)
}
// aplica em lotes (cada chamada fica abaixo do limite de tempo da API)
let depois: string | null = null
for (;;) {
  const out = await rpc('aplicar_planilha_precos_lote', { p_depois: depois, p_limite: 2000, p_token: token })
  console.log(`aplicado até ${out.ultimo}: ${out.atualizados} atualizados`)
  if (out.fim) break
  depois = out.ultimo
}
