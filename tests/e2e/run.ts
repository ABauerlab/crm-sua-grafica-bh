// Teste ponta a ponta do atendimento (Etapa 8B). Uso:
//   npm run e2e                         tudo (3 formulações por cenário)
//   npm run e2e -- --critico            só cenários que podem gerar falha crítica
//   npm run e2e -- --categoria=objecao,pagamento
//   npm run e2e -- --cenario=excecao-e-robo --formulacao=1
//   npm run e2e -- --sem-juiz           só verificações determinísticas
//   npm run e2e -- --exportar-juiz      grava os prompts do juiz em resultados/<rodada>/juiz/ (para julgar por outro agente)
//   npm run e2e -- --importar-juiz=DIR  lê vereditos JSON (um por conversa) de DIR em vez de chamar a API
//   npm run e2e -- --limpar             só apaga os contatos de teste (is_teste) e sai
// Variáveis: E2E_SUPABASE_URL, E2E_SERVICE_KEY, E2E_N8N_TESTE_URL, ANTHROPIC_API_KEY (juiz), E2E_TETO_TOKENS (padrão 600000).
import { mkdirSync, writeFileSync, readFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { CENARIOS } from './cenarios.ts'
import { Banco, Orcamento, executar, lerConfig } from './executor.ts'
import { julgarComApi, lerVeredito, montarPromptJuiz } from './juiz.ts'
import { matrizMarkdown, resumir, todasFalhas } from './relatorio.ts'
import type { ResultadoConversa } from './tipos.ts'

const args = process.argv.slice(2)
const flag = (nome: string) => args.includes(`--${nome}`)
const valor = (nome: string) => args.find((a) => a.startsWith(`--${nome}=`))?.split('=')[1]

const cfg = lerConfig()
const banco = new Banco(cfg.supabaseUrl, cfg.chaveServico)

if (flag('limpar')) {
  console.log('Limpeza (somente is_teste):', await banco.rpc('e2e_limpar'))
  process.exit(0)
}

let lista = CENARIOS
if (flag('critico')) lista = lista.filter((c) => c.critico)
const cats = valor('categoria')?.split(',')
if (cats) lista = lista.filter((c) => cats.includes(c.categoria))
const ids = valor('cenario')?.split(',')
if (ids) lista = lista.filter((c) => ids.includes(c.id))
const formulacoes = (valor('formulacao') ? [Number(valor('formulacao'))] : [1, 2, 3])
const paralelo = Number(valor('paralelo') ?? 3)
if (!lista.length) { console.error('nenhum cenário selecionado'); process.exit(2) }

const dir = join(import.meta.dirname, 'resultados', cfg.rodada)
mkdirSync(join(dir, 'juiz'), { recursive: true })
const orc = new Orcamento(Number(process.env.E2E_TETO_TOKENS ?? 600000))
const tarefas = lista.flatMap((c) => formulacoes.map((f) => ({ c, f })))
console.log(`Rodada ${cfg.rodada}: ${tarefas.length} conversas (${lista.length} cenários x ${formulacoes.length} formulações), teto ${orc.teto} tokens.`)

const resultados: ResultadoConversa[] = []
const fila = [...tarefas]
async function trabalhador() {
  for (let t = fila.shift(); t; t = fila.shift()) {
    if (orc.estourou) { console.error('Teto de tokens atingido: interrompendo.'); return }
    const r = await executar(t.c, t.f, cfg, banco, orc)
    const dirJuiz = valor('importar-juiz')
    try {
      if (flag('exportar-juiz')) {
        const p = montarPromptJuiz(r, t.c)
        writeFileSync(join(dir, 'juiz', `${t.c.id}.f${t.f}.json`), JSON.stringify({ ...p, cenario: t.c.id, formulacao: t.f }, null, 1))
      } else if (dirJuiz) {
        const arq = join(dirJuiz, `${t.c.id}.f${t.f}.json`)
        if (existsSync(arq)) r.veredito = lerVeredito(readFileSync(arq, 'utf8'))
      } else if (!flag('sem-juiz') && process.env.ANTHROPIC_API_KEY) {
        const j = await julgarComApi(r, t.c)
        r.veredito = j.veredito
        orc.gastar(j.tokens)
      }
    } catch (e) { r.erro = `juiz: ${(e as Error).message}` }
    resultados.push(r)
    const crit = todasFalhas(r).filter((f) => f.gravidade === 'critica').length
    console.log(`${r.erro ? 'ERRO' : crit ? 'CRIT' : 'ok  '} ${t.c.id} f${t.f} (${r.tokens} tokens)${r.erro ? ' ' + r.erro : ''}`)
    writeFileSync(join(dir, `${t.c.id}.f${t.f}.json`), JSON.stringify(r, null, 1))
  }
}
await Promise.all(Array.from({ length: Math.max(1, paralelo) }, trabalhador))

const resumo = resumir(resultados)
writeFileSync(join(dir, 'resumo.json'), JSON.stringify(resumo, null, 1))
writeFileSync(join(dir, 'matriz.md'), matrizMarkdown(resultados))
console.log('\n' + JSON.stringify(resumo, null, 2))
console.log(`\nTokens usados: ${orc.usado}. Resultados em ${dir}`)
console.log('Limpando contatos de teste:', await banco.rpc('e2e_limpar'))
process.exit(resumo.aprovada || flag('sem-juiz') ? (resumo.criticas ? 1 : 0) : 1)
