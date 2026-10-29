// Junta uma Edge Function e seus módulos locais (../_shared/*) em UM arquivo, para colar no painel do Supabase (Edge Functions > Via Editor).
// Uso: node scripts/bundle-funcao.ts <nome-da-funcao>   ->  docs/agente/funcoes/<nome>.bundle.ts
// O deploy normal continua sendo a CLI: supabase functions deploy <nome> --no-verify-jwt
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { dirname, resolve } from 'node:path'

const nome = process.argv[2]
if (!nome) throw new Error('Informe o nome da função. Ex.: node scripts/bundle-funcao.ts orcamento-pdf')
const raiz = new URL('../supabase/functions/', import.meta.url).pathname
const visitados: string[] = []
const npmImports = new Set<string>()
const corpos: string[] = []

const IMPORT = /^import\s+([^;\n]*?)\s+from\s+'([^']+)'\s*\n/gm
function incluir(arquivo: string): void {
  if (visitados.includes(arquivo)) return
  visitados.push(arquivo)
  const src = readFileSync(arquivo, 'utf8')
  const filhos: string[] = []
  const limpo = src.replace(IMPORT, (_m, _nomes, de: string) => {
    if (de.startsWith('.')) filhos.push(resolve(dirname(arquivo), de))
    else npmImports.add(_m.trim())
    return ''
  })
  for (const f of filhos) incluir(f) // dependências primeiro
  corpos.push(limpo.replace(/^export /gm, ''))
}
incluir(`${raiz}${nome}/index.ts`)

const corpo = [
  `// GERADO por "node scripts/bundle-funcao.ts ${nome}". NÃO edite aqui: edite supabase/functions/ e gere de novo.`,
  `// Painel do Supabase > Edge Functions > Deploy a new function (ou Code > Deploy updates) > Via Editor. Nome: ${nome}. "Verify JWT" desligado (a função confere o dono ou a service role).`,
  ...npmImports,
  ...corpos,
].join('\n')

const nomes = [...corpo.matchAll(/^(?:async )?(?:function|const|interface|type) ([A-Za-z0-9_]+)/gm)].map((m) => m[1])
const repetidos = nomes.filter((n, i) => nomes.indexOf(n) !== i)
if (repetidos.length) throw new Error('nomes repetidos entre os módulos: ' + [...new Set(repetidos)].join(', '))

const saida = new URL(`../docs/agente/funcoes/${nome}.bundle.ts`, import.meta.url).pathname
mkdirSync(dirname(saida), { recursive: true })
writeFileSync(saida, corpo)
console.log(`ok: docs/agente/funcoes/${nome}.bundle.ts (${corpo.length} bytes, ${visitados.length} arquivos)`)
