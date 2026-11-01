// Avalia retratos já coletados (modo sem chave de serviço): aplica as verificações, exporta os prompts do juiz e consolida.
//   node tests/e2e/avaliar.ts --dir=RETRATOS [--exportar-juiz=DIR] [--importar-juiz=DIR] [--saida=DIR]
import { mkdirSync, readFileSync, readdirSync, writeFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { porId } from './cenarios.ts'
import { resultadoDoDump, type DumpConversa } from './dump.ts'
import { lerVeredito, montarPromptJuiz } from './juiz.ts'
import { matrizMarkdown, resumir, todasFalhas } from './relatorio.ts'
import type { ResultadoConversa } from './tipos.ts'

const args = process.argv.slice(2)
const valor = (n: string) => args.find((a) => a.startsWith(`--${n}=`))?.split('=')[1]
const dir = valor('dir')
if (!dir) { console.error('use --dir=RETRATOS'); process.exit(2) }
const rs: ResultadoConversa[] = []
for (const f of readdirSync(dir).filter((x) => x.endsWith('.json') && x.includes('.f')).sort()) {
  const d = JSON.parse(readFileSync(join(dir, f), 'utf8')) as DumpConversa
  const cen = porId(d.cenario)
  if (!cen) { console.warn('cenário desconhecido', d.cenario); continue }
  const r = resultadoDoDump(cen, d)
  const exp = valor('exportar-juiz')
  if (exp) { mkdirSync(exp, { recursive: true }); writeFileSync(join(exp, f), JSON.stringify({ ...montarPromptJuiz(r, cen), cenario: cen.id, formulacao: d.formulacao }, null, 1)) }
  const imp = valor('importar-juiz')
  if (imp && existsSync(join(imp, f))) { try { r.veredito = lerVeredito(readFileSync(join(imp, f), 'utf8')) } catch (e) { r.erro = `juiz: ${(e as Error).message}` } }
  rs.push(r)
}
const resumo = resumir(rs)
const saida = valor('saida') ?? dir
writeFileSync(join(saida, 'resumo.json'), JSON.stringify(resumo, null, 1))
writeFileSync(join(saida, 'matriz.md'), matrizMarkdown(rs))
writeFileSync(join(saida, 'resultados.json'), JSON.stringify(rs, null, 1))
const crit = rs.flatMap((r) => todasFalhas(r).filter((f) => f.gravidade === 'critica').map((f) => `${r.cenario} f${r.formulacao}: ${f.codigo} | ${f.frase ?? f.detalhe ?? ''}`))
console.log(JSON.stringify(resumo, null, 2))
console.log(crit.length ? 'CRÍTICAS:\n' + crit.join('\n') : 'Nenhuma falha crítica.')
