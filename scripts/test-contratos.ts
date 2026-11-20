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
for (const obrigatorio of ['espere a resposta do cliente antes de orçar', 'largura, profundidade e altura finais', 'conferindo que nenhum ficou de fora', 'Nunca envie link do site', 'Não use o nome do perfil do WhatsApp', 'nunca repita pergunta já respondida', 'em_palavras, descricao, numero', 'Cupom VOLTEI5']) {
  if (!wf2.includes(obrigatorio)) falhas.push(`WF2 perdeu a regra "${obrigatorio}"`)
}
// A loja ainda não está aberta: nenhum fluxo do agente pode mandar link do site ao cliente
if (/a assistente virtual da Sua/.test(wf2)) falhas.push('WF2 voltou a dizer que a Laura é assistente virtual')
if (wf2.includes('link_produto')) falhas.push('WF2 voltou a mandar link_produto (a loja ainda não está aberta ao público)')
const bp = readFileSync(join(n8n, 'GBH-FERRAMENTA-buscar_produto.json'), 'utf8')
if (bp.includes('link_produto')) falhas.push('buscar_produto voltou a devolver link_produto')
if (!bp.includes('em_palavras')) falhas.push('buscar_produto deve entregar em_palavras (descrição oficial da impressão) ao agente')
// Gatilhos de desconto fixo (cupom e relâmpago): a ferramenta aceita e o banco decide
const ce = readFileSync(join(n8n, 'GBH-FERRAMENTA-condicao_especial.json'), 'utf8')
for (const g of ['RELAMPAGO', 'VOLTEI5']) if (!ce.includes(g)) falhas.push(`condicao_especial não aceita o gatilho ${g}`)
if (!/VOLTEI5/.test(wf2)) falhas.push('WF2 perdeu a descrição do gatilho VOLTEI5')
// Contrato do contexto: o bloco base lê estas chaves
for (const chave of ['campos_ja_cadastrados_nao_repetir_pergunta', 'campos_faltantes_crm', 'ultimas_mensagens', 'orcamento_aberto', 'pedido_ativo']) {
  if (!wf2.includes(chave)) falhas.push(`WF2 não lê mais a chave de contexto ${chave}`)
}

// Fase 1 (20/11/2026): prompt consolidado num bloco só, sem os rótulos antigos por rodada;
// confere a SUBSTÂNCIA de cada regra que antes vinha de rounds separados (ver docs/n8n-mapa.md).
for (const r of ['ENCERRAMENTO:', 'pedir aprovação ou confirmação', 'Kit cracha + cordão', '[respondendo a:', 'chame chamar_dono (gravidade alta)', 'nunca prometa entrega ou serviço que a ferramenta não trouxe', 'nota fiscal é padrão em todo pedido', 'chame agendar_followup e não faça pergunta nova', 'explique a diferença em uma frase simples', 'sugira uma vez um complemento natural', 'a equipe confere sangria e corte de todo pedido', 'urgência só real']) {
  if (!wf2.includes(r)) falhas.push(`WF2 perdeu a regra "${r}"`)
}
const mig18c = readFileSync(join(raiz, 'supabase', 'migrations', '20261218000003_orcamento_alinhado_ao_chat_e_motivo_de_perda.sql'), 'utf8')
for (const marca of ['montar_orcamento_base', 'alinhado_ao_chat', 'motivo_perda_trg']) if (!mig18c.includes(marca)) falhas.push(`migration do orçamento alinhado ao chat perdeu ${marca}`)
const mig18 = readFileSync(join(raiz, 'supabase', 'migrations', '20261218000002_atendimento_rodada_18.sql'), 'utf8')
for (const marca of ['fiscal_extrair', 'condicao_fora_padrao_trg', 'saida_travas_extra', 'saida_repeticao', 'dedupe_orientacao', 'aprov_pagamento_v2']) {
  if (!mig18.includes(marca)) falhas.push(`migration da rodada 18/11 perdeu ${marca}`)
}

// Botão Responder com IA: gatilho de rascunho no WF1, regra do modo rascunho no WF2 (voz da Laura, nunca João Victor) e função do servidor
const wf1 = readFileSync(join(n8n, 'GBH-WF1-Entrada-e-roteamento.json'), 'utf8')
for (const no of ['Rascunho: receber pedido', 'Rascunho: chamar o agente', 'Rascunho: extrair o texto', 'Rascunho: salvar para o atendente']) if (!wf1.includes(no)) falhas.push(`WF1 perdeu o nó do botão Responder com IA: ${no}`)
if (!wf2.includes('MODO RASCUNHO') || !/NUNCA assine nem se apresente como Jo[ãa]o Victor/.test(wf2)) falhas.push('WF2 perdeu a regra do modo rascunho (voz da Laura, nunca João Victor)')
if (!existsSync(join(raiz, 'supabase/functions/ia-rascunho/index.ts'))) falhas.push('Edge Function ia-rascunho não existe')

// Decisão do dono (20/11/2026): nunca dizer "de qualquer banco" ao citar o Pix. O prompt mantém um filtro
// defensivo (comentário "frase proibida") mas o texto de regra não deve mais instruir isso.
const wf2SemFiltro = wf2.replace(/frase proibida: Pix em qualquer banco/i, '').replace(/\/qualquer banco\/i/i, '')
if (/\bqualquer banco\b/i.test(wf2SemFiltro)) falhas.push('WF2 voltou a instruir "qualquer banco" no texto da regra')
if (falhas.length) { console.error('FALHOU contratos:\n- ' + falhas.join('\n- ')); process.exit(1) }
console.log(`OK: contratos (${rpcs.size} RPCs e ${edges.size} Edge Functions do n8n conferidas, prompt sem instruções conflitantes)`)
