// Contratos que mudanças futuras podem quebrar (offline): toda função do banco e toda Edge Function que os workflows do n8n chamam
// precisa existir no repositório; o modelo do agente não pode ser alias; o prompt não pode voltar a mandar cotar sem qualificar.
import { readFileSync, readdirSync, existsSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const raiz = join(dirname(fileURLToPath(import.meta.url)), '..')
const n8n = join(raiz, 'n8n')
const migs = readdirSync(join(raiz, 'supabase/migrations')).map((f) => readFileSync(join(raiz, 'supabase/migrations', f), 'utf8')).join('\n').toLowerCase()
const falhas: string[] = []

// Funções aplicadas direto no banco sem migration no repositório (dívida conhecida): ficam listadas aqui até virarem migration.
const SEM_MIGRATION_CONHECIDAS = new Set(['agente_agendar_followup', 'agente_salvar_contato', 'verificar_frete', 'buscar_conhecimento', 'agente_preco'])

const rpcs = new Set<string>()
const edges = new Set<string>()
for (const f of readdirSync(n8n).filter((x) => x.endsWith('.json'))) {
  const s = readFileSync(join(n8n, f), 'utf8')
  for (const m of s.matchAll(/\/rest\/v1\/rpc\/([a-z_0-9]+)/g)) rpcs.add(m[1])
  for (const m of s.matchAll(/\/functions\/v1\/([a-z\-_0-9]+)/g)) edges.add(m[1])
  if (/gemini-flash-latest/.test(s)) falhas.push(`${f}: usa o alias gemini-flash-latest (fixe a versão)`)
}
for (const r of rpcs) {
  if (SEM_MIGRATION_CONHECIDAS.has(r)) continue
  if (!new RegExp(`function\\s+(public\\.|private\\.)?${r}\\s*\\(`).test(migs)) falhas.push(`RPC ${r} chamada pelo n8n não tem migration`)
}
for (const e of edges) if (!existsSync(join(raiz, 'supabase/functions', e))) falhas.push(`Edge Function ${e} chamada pelo n8n não existe em supabase/functions`)

// Prompt do WF2: sem as instruções antigas que mandavam cotar e enviar PDF de imediato
const wf2 = readFileSync(join(n8n, 'GBH-WF2-Agente.json'), 'utf8')
for (const proibido of ['COTE LOGO, SEM ENROLAR', 'Conduza com fechamento assumido', 'cote tudo, envie o PDF e só depois pergunte', 'AVANCE PARA A COTAÇÃO!']) {
  if (wf2.includes(proibido)) falhas.push(`WF2 voltou a conter a instrução "${proibido}" (conflita com a regra 19: qualificar antes de orçar)`)
}
for (const obrigatorio of ['19) QUALIFIQUE ANTES DE ORÇAR', '22) EMBALAGENS', '24) PRODUTO CERTO COM MUITAS OPÇÕES']) {
  if (!wf2.includes(obrigatorio)) falhas.push(`WF2 perdeu a regra "${obrigatorio}"`)
}
// Contrato do contexto: o bloco base lê estas chaves
for (const chave of ['campos_ja_cadastrados_nao_repetir_pergunta', 'campos_faltantes_crm', 'ultimas_mensagens', 'orcamento_aberto', 'pedido_ativo']) {
  if (!wf2.includes(chave)) falhas.push(`WF2 não lê mais a chave de contexto ${chave}`)
}

if (falhas.length) { console.error('FALHOU contratos:\n- ' + falhas.join('\n- ')); process.exit(1) }
console.log(`OK: contratos (${rpcs.size} RPCs e ${edges.size} Edge Functions do n8n conferidas, prompt sem instruções conflitantes)`)
