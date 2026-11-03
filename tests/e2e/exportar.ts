// Baixa os retratos de uma rodada executada DENTRO do banco (e2e_avancar) e grava um JSON por conversa,
// no formato que avaliar.ts lê. Uso:
//   E2E_SUPABASE_URL=... E2E_ANON_KEY=<chave publicável> E2E_EXPORT_TOKEN=<token> node tests/e2e/exportar.ts --rodada=c2 --saida=DIR
// O token fica em e2e_config (banco) e nunca vai ao repositório. Só devolve dados de contatos de teste.
import { mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const args = process.argv.slice(2)
const valor = (n: string) => args.find((a) => a.startsWith(`--${n}=`))?.split('=')[1]
const rodada = valor('rodada')
const saida = valor('saida')
const url = process.env.E2E_SUPABASE_URL
const chave = process.env.E2E_ANON_KEY
const token = process.env.E2E_EXPORT_TOKEN
if (!rodada || !saida || !url || !chave || !token) {
  console.error('use --rodada=ID --saida=DIR e defina E2E_SUPABASE_URL, E2E_ANON_KEY e E2E_EXPORT_TOKEN')
  process.exit(2)
}
const r = await fetch(`${url}/rest/v1/rpc/e2e_exportar`, {
  method: 'POST',
  headers: { apikey: chave, authorization: `Bearer ${chave}`, 'content-type': 'application/json' },
  body: JSON.stringify({ p_token: token, p_rodada: rodada }),
})
if (!r.ok) { console.error('falha ao exportar:', r.status); process.exit(1) }
const lista = (await r.json()) as { cenario: string; formulacao: number; persona: string; estado: string; erro: string | null; turnos: unknown[] }[] | null
if (!Array.isArray(lista)) { console.error('token inválido'); process.exit(1) }
mkdirSync(saida, { recursive: true })
let erros = 0
for (const c of lista) {
  if (c.estado !== 'concluida') erros++
  writeFileSync(join(saida, `${c.cenario}.f${c.formulacao}.json`), JSON.stringify({ cenario: c.cenario, formulacao: c.formulacao, persona: c.persona, turnos: c.turnos }, null, 1))
}
console.log(`${lista.length} conversas em ${saida}${erros ? ` (${erros} não concluídas)` : ''}`)
