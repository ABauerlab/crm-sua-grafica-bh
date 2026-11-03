// Gera os planos de execução por lote (para rodar os turnos com e2e_criar_caso/e2e_aguardar quando não há chave de serviço).
//   node tests/e2e/plano.ts --rodada=R1 --formulacao=1 [--critico] [--categoria=a,b] [--cenario=x,y] [--lotes=6] --saida=DIR
import { mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { CENARIOS } from './cenarios.ts'
import { planoDoCenario } from './dump.ts'

const args = process.argv.slice(2)
const valor = (n: string) => args.find((a) => a.startsWith(`--${n}=`))?.split('=')[1]
const rodada = valor('rodada') ?? 'r1'
const form = Number(valor('formulacao') ?? 1)
const saida = valor('saida')
if (!saida) { console.error('use --saida=DIR'); process.exit(2) }
let lista = CENARIOS
if (args.includes('--critico')) lista = lista.filter((c) => c.critico)
const cats = valor('categoria')?.split(',')
if (cats) lista = lista.filter((c) => cats.includes(c.categoria))
const ids = valor('cenario')?.split(',')
if (ids) lista = lista.filter((c) => ids.includes(c.id))
const lotes = Number(valor('lotes') ?? 6)
mkdirSync(saida, { recursive: true })
const grupos: ReturnType<typeof planoDoCenario>[][] = Array.from({ length: lotes }, () => [])
lista.forEach((c, i) => grupos[i % lotes].push(planoDoCenario(c, form, rodada)))
grupos.forEach((g, i) => { if (g.length) writeFileSync(join(saida, `lote-${i + 1}.json`), JSON.stringify({ rodada, tarefas: g }, null, 1)) })
console.log(`${lista.length} cenários em ${grupos.filter((g) => g.length).length} lotes em ${saida}`)
