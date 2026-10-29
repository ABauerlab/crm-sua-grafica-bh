// Junta a Edge Function orcamento-pdf e seus módulos em UM arquivo, para colar no painel do Supabase (Edge Functions > Via Editor).
// Uso: npm run bundle:orcamento-pdf   (o deploy normal continua sendo a CLI: supabase functions deploy orcamento-pdf --no-verify-jwt)
import { readFileSync, writeFileSync } from 'node:fs'

const raiz = new URL('../supabase/functions/', import.meta.url).pathname
const ler = (f: string) => readFileSync(raiz + f, 'utf8')
const semImportsLocais = (src: string) => src.replace(/^import [^\n]*from '\.{1,2}\/[^\n]*\n/gm, '')

const http = ler('_shared/http.ts')
const html = ler('_shared/orcamento-html.ts')
const index = ler('orcamento-pdf/index.ts')

const npmImport = /^import \{ createClient, type SupabaseClient \} from 'npm:@supabase\/supabase-js@2'\n/m
if (!npmImport.test(http)) throw new Error('import do supabase-js não encontrado em _shared/http.ts')

const corpo = [
  '// GERADO por "npm run bundle:orcamento-pdf" (scripts/bundle-orcamento-pdf.ts). NÃO edite aqui: edite supabase/functions/ e gere de novo.',
  '// Painel do Supabase > Edge Functions > Deploy a new function > Via Editor. Nome: orcamento-pdf. Desligue "Verify JWT" (a função confere o dono ou a service role).',
  "import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2'",
  semImportsLocais(http.replace(npmImport, '')),
  semImportsLocais(html),
  semImportsLocais(index),
].join('\n')

// nomes duplicados entre os módulos quebrariam o arquivo único
const nomes = [...corpo.matchAll(/^(?:export )?(?:async )?(?:function|const|interface|type) ([A-Za-z0-9_]+)/gm)].map((m) => m[1])
const repetidos = nomes.filter((n, i) => nomes.indexOf(n) !== i)
if (repetidos.length) throw new Error('nomes repetidos: ' + [...new Set(repetidos)].join(', '))

writeFileSync(new URL('../docs/agente/funcoes/orcamento-pdf.bundle.ts', import.meta.url).pathname, corpo.replace(/^export /gm, ''))
console.log('ok: docs/agente/funcoes/orcamento-pdf.bundle.ts', corpo.length, 'bytes')
