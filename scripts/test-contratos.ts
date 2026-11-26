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
// Regressão 24/11/2026 (Jordan, Alice, Paulo + cron): busca por medida/frente e verso, guarda de loop, pedido pago e permissão do cron
const mReg = readFileSync(join(raiz, 'supabase/migrations/20261224020000_regressao_busca_loop_pos_pagamento_cron.sql'), 'utf8')
for (const marca of ['medida_axb_cm', "then '4X4'", 'v_tam2', 'max_ferramenta_por_rodada = 20', 'max_chamadas_por_rodada = 50', 'alteracao_pos_pagamento', "session_user in ('postgres', 'supabase_admin')"]) {
  if (!mReg.includes(marca)) falhas.push(`migration de regressão 24/11 perdeu "${marca}"`)
}
// "10x15cm frente e verso" tem que virar 100 x 150 (PA65G6, 4X4): reproduz a conta da migration em TypeScript
const medida = (t: string) => { const m = t.match(/(?:^| )([0-9]{1,2}(?:[.,][0-9])?) ?x ?([0-9]{1,2}(?:[.,][0-9])?)( ?cm)?(?: |$)/); if (!m) return null; const a = Number(m[1].replace(',', '.')), b = Number(m[2].replace(',', '.')); return m[3] || Math.min(a, b) >= 5 ? `${Math.round(a * 10)} x ${Math.round(b * 10)}` : null }
if (medida('panfleto 10x15cm frente e verso') !== '100 x 150') falhas.push('medida 10x15cm deve virar 100 x 150')
if (medida('panfleto 10 x 15 cm') !== '100 x 150') falhas.push('medida "10 x 15 cm" deve virar 100 x 150')
if (medida('flyer 4x4') !== null || medida('cartao 4x0') !== null) falhas.push('cores 4x4 e 4x0 não podem virar medida')
// Lista grande: o despachante não pode voltar ao limite curto e o prompt libera uma busca por item distinto
if (!wf2.includes('uma busca por item distinto') || !wf2.includes('UM único montar_orcamento')) falhas.push('WF2 perdeu a regra de lista grande (uma busca por item e um único orçamento)')
if (wf2.includes('no máximo 2 chamadas por resposta')) falhas.push('WF2 voltou ao limite de 2 buscas por resposta')
// Pedido pago nunca altera
for (const r of ['PEDIDO PAGO: NUNCA confirme alteração']) if (!wf2.includes(r)) falhas.push(`WF2 perdeu a regra pós-pagamento "${r}"`)
if (!existsSync(join(raiz, 'supabase/tests/regressao_24nov.sql'))) falhas.push('supabase/tests/regressao_24nov.sql não existe')
// Lote 1 (26/11/2026): blindagem da API do WhatsApp. Confere a migration, o servidor de envio, o modal, o WF2 e o despachante.
const mL1 = readFileSync(join(raiz, 'supabase/migrations/20261226000001_lote1_blindagem_whatsapp.sql'), 'utf8')
for (const marca of ['msg_recusa_forte', 'proativas_hoje', 'contato_bloqueado_proativo', 'recusa_desde_proativa', 'trava_diaria_global', 'optout_total', 'messages_recusa_cancela_followups',
  'reativacao_reservar', 'reativacao_cancelar', 'orcamento_pronto_vencido', 'margem_financeira', 'saida_rascunho_bloqueado', 'busca_repetida', 'busca_sem_progresso', 'buscas_sem_retorno',
  'agente_vigia_rodadas', 'agente_lento', 'timeout_vigia']) {
  if (!mL1.includes(marca)) falhas.push(`migration do Lote 1 perdeu "${marca}"`)
}
if (!existsSync(join(raiz, 'supabase/tests/lote1_blindagem.sql'))) falhas.push('supabase/tests/lote1_blindagem.sql não existe')
// O regex de recusa é o mesmo no banco e aqui: \m e \M do Postgres viram \b no JavaScript
const pgParaJs = (re: string) => new RegExp(re.replace(/\\m/g, '\\b').replace(/\\M/g, '\\b'), 'i')
const reRecusa = mL1.match(/create or replace function private\.msg_recusa_forte[\s\S]*?~\* '(.+?)';\n\$f\$/)
if (!reRecusa) falhas.push('não achei o regex de msg_recusa_forte na migration do Lote 1')
else {
  const rec = pgParaJs(reRecusa[1])
  for (const frase of ['Agora não', 'agora nao', 'Depois eu vejo', 'No momento não', 'no momento nao', 'Por enquanto não', 'por enquanto nao', 'Não quero', 'nao quero mais', 'Não tenho interesse', 'nao tenho interesse']) {
    if (!rec.test(frase)) falhas.push(`recusa não reconhecida: "${frase}"`)
  }
  for (const frase of ['Quero 500 cartões', 'Pode mandar o link?', 'Ok, vou pagar agora', 'Qual o prazo de entrega?', '🤍']) {
    if (rec.test(frase)) falhas.push(`falso positivo de recusa: "${frase}"`)
  }
}
// vazamento:margem só em contexto financeiro (Wesley e Waner)
const reMargem = mL1.match(/array\['margem', '(.+?)'\], \/\* margem_financeira \*\//)
if (!reMargem) falhas.push('não achei o regex de margem financeira na migration do Lote 1')
else {
  const mg = pgParaJs(reMargem[1])
  for (const ok of ['a frente tem a margem diferente do verso', 'Fique atento às margens de segurança', 'deixe uma margem de segurança de 3 mm', 'a margem de corte fica livre']) {
    if (mg.test(ok)) falhas.push(`margem técnica não pode ser bloqueada: "${ok}"`)
  }
  for (const ruim of ['nossa margem de lucro é de 65 reais', 'a nossa margem é pequena', 'meu lucro mínimo é 65', 'a margem líquida é 40%']) {
    if (!mg.test(ruim)) falhas.push(`margem financeira deveria ser bloqueada: "${ruim}"`)
  }
}
// Trava pós-pagamento (Paulo): bloqueia promessa de logística/priorização, deixa passar "vou verificar com o responsável"
const rePago = mL1.match(/saida_sem_verificacao\(p_texto\) ~\* '(.+?)' then/)
if (!rePago) falhas.push('não achei o regex pós-pagamento na migration do Lote 1')
else {
  const pg = pgParaJs(rePago[1].replace(/\\y/g, '\\b'))
  const semVerificacao = (t: string) => t.split(/(?<=[.!?])\s+|\n+/).filter((x) => !/(verific|ver se|confer|checar|saber se|se (ainda )?(d[aá]|é poss[ií]vel|consigo|conseguimos|podemos|posso))/i.test(x)).join(' ')
  for (const ruim of ['Já anotei aqui para priorizarmos a saída depois das 17h.', 'Já estou organizando o envio das suas carteirinhas.', 'Confirmei com a produção para saírem sem furo.', 'Já alterei a cor do texto na arte.']) {
    if (!pg.test(semVerificacao(ruim))) falhas.push(`promessa pós-pagamento deveria ser bloqueada: "${ruim}"`)
  }
  for (const ok of ['Vou verificar com o responsável se ainda dá tempo.', 'Seu pedido já entrou na fila e te aviso quando estiver pronto.']) {
    if (pg.test(semVerificacao(ok))) falhas.push(`resposta neutra não pode ser bloqueada: "${ok}"`)
  }
}
// Envio: a reativação passa pela reserva do servidor (trava diária, opt-out, orcamento_pronto velho) antes de falar com a Meta
const send = readFileSync(join(raiz, 'supabase/functions/whatsapp-send/index.ts'), 'utf8')
if (!send.includes("rpc('reativacao_reservar'") || !send.includes("rpc('reativacao_cancelar'")) falhas.push('whatsapp-send perdeu a reserva da reativação')
if (send.indexOf("rpc('reativacao_reservar'") > send.indexOf('await fetch(`${GRAPH}/${env.WHATSAPP_PHONE_NUMBER_ID}/messages`')) falhas.push('whatsapp-send precisa reservar a reativação ANTES de enviar à Meta')
const modal = readFileSync(join(raiz, 'src/features/orders/ReativarPagamentosPendentes.tsx'), 'utf8')
if (!modal.includes('proativo') || !modal.includes('ORCAMENTO_RECENTE_HORAS') || modal.includes('useRegistrarReativacao')) falhas.push('modal de reativação precisa usar o envio com trava no servidor (proativo, 24 h) e não registrar no navegador')
// WF2 e despachante
const wf2L1 = JSON.parse(wf2) as { nodes: { name: string; maxTries?: number; retryOnFail?: boolean }[]; settings: { executionTimeout?: number } }
const agente = wf2L1.nodes.find((n) => n.name === 'Agente de atendimento')
if (!agente || agente.maxTries !== 2 || !agente.retryOnFail) falhas.push('agente do WF2 precisa de exatamente 1 retry (maxTries 2)')
if ((wf2L1.settings.executionTimeout ?? 999) > 300) falhas.push('WF2 precisa de teto de execução de 300 s')
const desp = readFileSync(join(n8n, 'GBH-FERRAMENTA-despachar.json'), 'utf8')
if (!desp.includes('p_args: { termo: String($json.termo')) falhas.push('despachante precisa enviar termo e quantidade ao agente_tool_inicio (freio de buscas)')
// Lote 2 (26/11/2026): sinônimos, acabamento por ficha e prefixo, SKUs gêmeos, anúncio determinístico e tokens do WF2.
const mL2 = readFileSync(join(raiz, 'supabase/migrations/20261227000001_lote2_catalogo_acabamento.sql'), 'utf8')
const mL2b = readFileSync(join(raiz, 'supabase/migrations/20261227000002_lote2_gemeos_completar.sql'), 'utf8')
for (const marca of ["'raspadinha'", "'carteirinha'", "'plaquinha'", "('CVL',", "'verniz_localizado_fv'", "('COM0013', 'SÓ A LONA / REFIL, SEM ESTRUTURA'", "('ROLLUP001', 'KIT COMPLETO: ESTRUTURA + LONA'", 'acabamento_nao_encontrado', 'orientacao_acabamento', "v_origem := 'anuncio'", 'buscar_produto_base', "cron.schedule('catalogo-acabamento'"]) {
  if (!mL2.includes(marca)) falhas.push(`migration do Lote 2 perdeu "${marca}"`)
}
if (!mL2b.includes('buscar_completar_gemeos') || !mL2b.includes("lucro_ok")) falhas.push('migration dos gêmeos precisa completar os SKUs gêmeos com calcular_preco e a trava de lucro')
if (!/NUNCA diga "hoje só trabalhamos com/.test(mL2)) falhas.push('a orientação de acabamento precisa proibir "hoje só trabalhamos com..."')
// Regex de acabamento: pedido do cliente e título do anúncio
const acabs: Record<string, RegExp> = {}
for (const m of mL2.matchAll(/^\s*\('([a-z_]+)', '[^']+', '(.+?)', (?:true|false)\)[,]?$/gm)) acabs[m[1]] = pgParaJs(m[2].replace(/\\s/g, '\\s'))
if (!acabs.verniz_localizado?.test('cartao de visita verniz localizado frente e verso') || !acabs.verniz_localizado.test('brilho especial nos detalhes')) falhas.push('regex de verniz localizado precisa casar o pedido do cliente e o título da ficha')
if (!acabs.hot_stamping?.test('cartao de visita com hot stamping') || !acabs.hot_stamping.test('hotstamping')) falhas.push('regex de hot stamping precisa casar as duas grafias')
if (acabs.hot_stamping?.test('cartao de visita fosco')) falhas.push('regex de hot stamping casou texto sem hot stamping')
// WF2: tokens no campo certo do nó Gemini (options.maxOutputTokens, nunca parameters.options)
const wf2L2 = JSON.parse(wf2) as { nodes: { name: string; parameters: { options?: { maxOutputTokens?: number }; parameters?: unknown } }[] }
const gem = wf2L2.nodes.find((n) => n.name.startsWith('Modelo Gemini'))
if (!gem || gem.parameters.options?.maxOutputTokens !== 4096 || gem.parameters.parameters !== undefined) falhas.push('nó Gemini do WF2 precisa de options.maxOutputTokens = 4096 e sem parameters.options perdido')
const promptL2 = wf2L2.nodes.find((n) => n.name === 'Prompt consolidado (Fase 1)') as unknown as { parameters: { jsCode: string } } | undefined
if (!promptL2 || !promptL2.parameters.jsCode.includes('acabamento_nao_encontrado') || !promptL2.parameters.jsCode.includes('hoje só trabalhamos com') || !promptL2.parameters.jsCode.includes('orientacao_gemeos')) falhas.push('prompt do WF2 perdeu as regras de acabamento e de SKUs gêmeos')
// Sub-workflow e despachante levam acabamento, anúncio e diferencial até a Laura
const subL2 = readFileSync(join(n8n, 'GBH-FERRAMENTA-buscar_produto.json'), 'utf8')
for (const marca of ['filtros.acabamento', 'filtros.conversation_id', 'diferencial: o.diferencial', 'orientacao_acabamento', 'orientacao_gemeos']) {
  if (!subL2.includes(marca)) falhas.push(`sub-workflow buscar_produto perdeu "${marca}"`)
}
if (!desp.includes('f.conversation_id = $json.conversation_id')) falhas.push('despachante precisa enviar conversation_id nos filtros da busca (anúncio determinístico)')
if (falhas.length) { console.error('FALHOU contratos:\n- ' + falhas.join('\n- ')); process.exit(1) }
console.log(`OK: contratos (${rpcs.size} RPCs e ${edges.size} Edge Functions do n8n conferidas, prompt sem instruções conflitantes)`)
