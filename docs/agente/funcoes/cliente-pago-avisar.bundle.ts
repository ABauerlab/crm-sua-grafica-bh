// GERADO por "node scripts/bundle-funcao.ts cliente-pago-avisar". NÃO edite aqui: edite supabase/functions/ e gere de novo.
// Painel do Supabase > Edge Functions > Deploy a new function (ou Code > Deploy updates) > Via Editor. Nome: cliente-pago-avisar. "Verify JWT" desligado (a função confere o dono ou a service role).
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2'
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-cron-secret',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}

/** Cliente com service role: ignora RLS. Use apenas dentro das Edge Functions. */
function serviceClient(): SupabaseClient {
  return createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
    auth: { persistSession: false, autoRefreshToken: false },
  })
}

interface Staff {
  userId: string
  role: 'admin' | 'agent'
}

/** Valida o JWT do chamador e exige que ele exista em profiles. */
async function requireStaff(req: Request, db: SupabaseClient): Promise<Staff | null> {
  const token = req.headers.get('Authorization')?.replace(/^Bearer\s+/i, '')
  if (!token) return null
  const { data: userData, error } = await db.auth.getUser(token)
  if (error || !userData.user) return null
  const { data: profile } = await db.from('profiles').select('id, role').eq('id', userData.user.id).maybeSingle()
  if (!profile) return null
  return { userId: profile.id, role: profile.role }
}

function requireEnv(...names: string[]): Record<string, string> | null {
  const out: Record<string, string> = {}
  for (const n of names) {
    const v = Deno.env.get(n)
    if (!v) {
      console.error(`Segredo ausente: ${n}`)
      return null
    }
    out[n] = v
  }
  return out
}

/** Confere uma chave de serviço perguntando ao próprio Supabase: só a service role passa no endpoint de administração do Auth. */
async function ehServiceRole(token: string): Promise<boolean> {
  const url = Deno.env.get('SUPABASE_URL')
  if (!url || token.length < 20) return false
  try {
    const res = await fetch(`${url}/auth/v1/admin/users?page=1&per_page=1`, { headers: { apikey: token, Authorization: `Bearer ${token}` } })
    return res.ok
  } catch {
    return false
  }
}

/** Chamador autorizado a cobrar: o dono logado (JWT) ou outro servidor da própria Sua Gráfica usando a service role key. */
async function requireOwnerOrServer(req: Request, db: SupabaseClient): Promise<'dono' | 'servidor' | null> {
  const token = req.headers.get('Authorization')?.replace(/^Bearer\s+/i, '')
  if (!token) return null
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
  if (serviceKey && token.length === serviceKey.length && token === serviceKey) return 'servidor'
  const { data: userData, error } = await db.auth.getUser(token)
  // Não é um usuário: pode ser a service role de outro formato (a injetada na função nem sempre é igual à do painel)
  if (error || !userData.user) return (await ehServiceRole(token)) ? 'servidor' : null
  const { data: profile } = await db.from('profiles').select('id').eq('id', userData.user.id).maybeSingle()
  if (!profile) return null
  const { data: owner } = await db.from('app_settings').select('value').eq('key', 'owner').maybeSingle()
  const ownerEmail = String((owner?.value as { email?: string } | null)?.email ?? '').toLowerCase()
  if (ownerEmail && (userData.user.email ?? '').toLowerCase() !== ownerEmail) return null
  return 'dono'
}

/** Só a service role (outro servidor da própria Sua Gráfica, como o n8n). Nenhum usuário logado passa. */
async function requireServiceRole(req: Request): Promise<boolean> {
  const token = req.headers.get('Authorization')?.replace(/^Bearer\s+/i, '')
  if (!token) return false
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
  if (serviceKey && token.length === serviceKey.length && token === serviceKey) return true
  return ehServiceRole(token)
}

// Montagem dos avisos ao dono (push e WhatsApp). Funções puras: testadas em Node (scripts/test-alertas.ts), usadas pela Edge Function alertas-enviar.
// Nunca entram aqui custo, piso, margem de fornecedor nem endereço de retirada: o lucro líquido é do dono e só vai para o número dele.

interface AlertaFila {
  id: string
  tipo: string
  gravidade: 'alta' | 'baixa'
  motivo: string
  dados: Record<string, unknown>
  conversation_id?: string | null
  order_id?: string | null
  enviar_push: boolean
  enviar_whatsapp: boolean
  badge?: number
}

interface PushPayload {
  title: string
  body: string
  url: string
  tag: string
  tipo: string
  badge: number
  gravidade: string
}

const str = (v: unknown, fallback = ''): string => (typeof v === 'string' && v.trim() ? v.trim() : fallback)
const corta = (s: string, n: number): string => (s.length <= n ? s : s.slice(0, n - 1).trimEnd() + '…')

function montarPush(a: AlertaFila): PushPayload {
  const d = a.dados ?? {}
  const cliente = str(d.cliente, 'Cliente')
  const url = str(d.url, '/painel')
  let title: string
  let body: string
  switch (a.tipo) {
    case 'pedido_pago':
      title = `${d.teste ? '[TESTE] ' : ''}Pedido pago: ${str(d.pedido, 'novo pedido')}`
      body = `${cliente} pagou ${str(d.valor, '')}. Lucro líquido ${str(d.lucro_liquido, 'a confirmar')}. Previsão ${str(d.previsao, 'a confirmar')}.`
      break
    case 'nova_mensagem_humano':
      title = 'Nova mensagem'
      body = `${cliente} escreveu e está esperando você.`
      break
    case 'resumo':
      title = 'Resumo de avisos'
      body = a.motivo
      break
    case 'teste_notificacao':
      title = 'Notificação de teste'
      body = 'Deu certo: este aparelho recebe os avisos da Sua Gráfica BH.'
      break
    default:
      title = `Atenção: ${cliente}`
      body = a.motivo
  }
  return {
    title: corta(title, 60),
    body: corta(body, 170),
    url,
    // mesmo tipo e mesma conversa/pedido: a notificação nova substitui a anterior
    tag: `${a.tipo}:${a.conversation_id ?? a.order_id ?? 'geral'}`,
    tipo: a.tipo,
    badge: Math.max(0, Number(a.badge ?? 0)),
    gravidade: a.gravidade,
  }
}

/** Variáveis de template: sem quebra de linha, tabulação nem 4 espaços seguidos (regra da Meta); nunca vazias. */
function varTemplate(v: unknown, max = 200): string {
  const s = String(v ?? '').replace(/[\r\n\t]+/g, ' ').replace(/ {2,}/g, ' ').trim()
  return corta(s || '-', max)
}

type TemplateDono = { name: 'pedido_pago_dono' | 'alerta_atencao_dono'; params: string[] }

/** pedido_pago_dono: cliente, itens, valor, lucro líquido, previsão, link. alerta_atencao_dono: cliente, motivo, link. */
function montarTemplate(a: AlertaFila): TemplateDono {
  const d = a.dados ?? {}
  if (a.tipo === 'pedido_pago') {
    return {
      name: 'pedido_pago_dono',
      params: [d.cliente, d.itens, d.valor, d.lucro_liquido, d.previsao, d.url].map((v, i) => varTemplate(v, i === 1 ? 300 : 200)),
    }
  }
  return { name: 'alerta_atencao_dono', params: [varTemplate(d.cliente ?? 'Resumo', 80), varTemplate(a.motivo, 300), varTemplate(d.url)] }
}

/** Texto livre (janela de 24 h do dono aberta). */
function montarTexto(a: AlertaFila): string {
  const d = a.dados ?? {}
  const url = str(d.url)
  if (a.tipo === 'pedido_pago') {
    return [
      `${d.teste ? '[TESTE] ' : ''}Pedido pago por ${str(d.cliente, 'cliente')}.`,
      `Itens: ${str(d.itens, '-')}`,
      `Valor: ${str(d.valor, '-')} (${str(d.metodo, 'método não informado')})`,
      `Lucro líquido: ${str(d.lucro_liquido, 'a confirmar')}`,
      `Previsão: ${str(d.previsao, 'a confirmar')}`,
      `Abra o pedido no CRM: ${url}`,
    ].join('\n')
  }
  if (a.tipo === 'resumo') return `Resumo de avisos (${a.motivo})\nAbra o CRM: ${url}`
  return `Atenção no atendimento. Cliente: ${str(d.cliente, '-')}.\nMotivo: ${a.motivo}\nAbra no CRM: ${url}`
}

/** Mensagem ao cliente depois do pagamento. Sem SKU, custo, margem ou lucro. Endereço só aqui, depois de pago. */
function montarConfirmacaoCliente(i: {
  nome: string
  pedido: string
  previsao: string
  arte_status?: string | null
  entrega?: string | null
  /** Persona do pós-pagamento (ex.: João Victor) e o artigo ("o" ou "a"). Sem persona, a mensagem é a de sempre. */
  persona?: string | null
  artigo?: string | null
}): string {
  const arte =
    i.arte_status === 'aprovada'
      ? 'A sua arte já está aprovada.'
      : i.arte_status === 'enviada' || i.arte_status === 'em_criacao'
        ? 'A arte está em andamento e eu te aviso por aqui para você aprovar.'
        : 'Se você já tem a arte, é só enviar o arquivo aqui na conversa. Se ainda não tem, me avisa que a gente cria.'
  const entrega =
    i.entrega === 'uber'
      ? 'A entrega a gente combina por aqui assim que o pedido ficar pronto.'
      : 'Quando ficar pronto eu te aviso por aqui com o endereço e o horário de retirada.'
  const quem = i.persona ? `Aqui é ${i.artigo ? i.artigo + ' ' : ''}${i.persona}, assistente virtual da Sua Gráfica BH. ` : ''
  return `${i.persona ? `Oi, ${i.nome}! ` : ''}${quem}${i.persona ? 'Seu pagamento foi confirmado' : `Pagamento confirmado, ${i.nome}`}! Seu pedido ${i.pedido} já entrou na fila. Previsão de ficar pronto: ${i.previsao}. ${arte} ${entrega}`
}

/** Variáveis do template pedido_pago_confirmacao: nome, número do pedido, previsão. */
function templateConfirmacaoCliente(i: { nome: string; pedido: string; previsao: string }): string[] {
  return [varTemplate(i.nome, 60), varTemplate(i.pedido, 30), varTemplate(i.previsao, 30)]
}

/** O erro da Meta é definitivo para este canal (não adianta repetir)? Hoje: nenhum; o recuo do banco decide. */
function janelaAberta(janelaAte: string | null | undefined, agora = Date.now()): boolean {
  if (!janelaAte) return false
  const t = Date.parse(janelaAte)
  return Number.isFinite(t) && t > agora
}

// Envio pela API oficial do WhatsApp (Graph) usado pelos alertas e pela confirmação ao cliente. O token fica só no servidor.
const GRAPH = 'https://graph.facebook.com/v21.0'

interface WaEnv {
  WHATSAPP_TOKEN: string
  WHATSAPP_PHONE_NUMBER_ID: string
  WHATSAPP_WABA_ID?: string
}

interface WaResultado {
  ok: boolean
  wa_message_id?: string
  codigo?: number | null
  erro?: string
}

async function post(env: WaEnv, body: unknown): Promise<WaResultado> {
  try {
    const res = await fetch(`${GRAPH}/${env.WHATSAPP_PHONE_NUMBER_ID}/messages`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${env.WHATSAPP_TOKEN}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    })
    const r = await res.json().catch(() => ({}))
    if (!res.ok) {
      const codigo = Number(r?.error?.code) || null
      console.error('Erro da Meta ao enviar aviso:', codigo)
      return { ok: false, codigo, erro: `meta_${codigo ?? res.status}` }
    }
    return { ok: true, wa_message_id: r?.messages?.[0]?.id as string | undefined }
  } catch {
    return { ok: false, erro: 'rede' }
  }
}

const enviarTexto = (env: WaEnv, to: string, text: string) =>
  post(env, { messaging_product: 'whatsapp', to, type: 'text', text: { body: text, preview_url: false } })

const enviarTemplate = (env: WaEnv, to: string, name: string, params: string[], language = 'pt_BR') =>
  post(env, {
    messaging_product: 'whatsapp',
    to,
    type: 'template',
    template: {
      name,
      language: { code: language },
      components: [{ type: 'body', parameters: params.map((text) => ({ type: 'text', text })) }],
    },
  })

/** Status atual do template na Meta (atualiza o cache). null = não foi possível consultar (tenta enviar mesmo assim). */
async function statusTemplate(env: WaEnv, db: SupabaseClient, name: string, language = 'pt_BR'): Promise<string | null> {
  if (!env.WHATSAPP_WABA_ID) return null
  try {
    const res = await fetch(`${GRAPH}/${env.WHATSAPP_WABA_ID}/message_templates?name=${encodeURIComponent(name)}&fields=name,status,language,category,components&limit=10`, {
      headers: { Authorization: `Bearer ${env.WHATSAPP_TOKEN}` },
    })
    if (!res.ok) return null
    const r = await res.json()
    // deno-lint-ignore no-explicit-any
    const t = (r?.data ?? []).find((x: any) => x.name === name && x.language === language)
    if (!t) return 'NAO_ENCONTRADO'
    // deno-lint-ignore no-explicit-any
    const body = (t.components ?? []).find((c: any) => c.type === 'BODY')?.text as string | undefined
    await db.from('templates_cache').upsert({ name, language, category: t.category ?? null, status: t.status, body: body ?? null, synced_at: new Date().toISOString() })
    return String(t.status)
  } catch {
    return null
  }
}

// WF5: UMA mensagem ao cliente depois do pagamento confirmado. Texto livre se a janela de 24 h estiver aberta, senão o template
// pedido_pago_confirmacao. Só a service role chama. O banco reserva o envio (sem duplicar) e conta as tentativas (máximo 3).
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)
  if (!(await requireServiceRole(req))) return json({ error: 'Não autorizado.' }, 401)
  const env = requireEnv('WHATSAPP_TOKEN', 'WHATSAPP_PHONE_NUMBER_ID') as WaEnv | null
  if (!env) return json({ error: 'Integração com o WhatsApp não configurada no servidor.' }, 500)
  env.WHATSAPP_WABA_ID = Deno.env.get('WHATSAPP_WABA_ID') ?? undefined

  const input = (await req.json().catch(() => ({}))) as { order_id?: string }
  if (!UUID.test(String(input.order_id ?? ''))) return json({ error: 'order_id inválido.' }, 400)

  const db = serviceClient()
  const { data: r, error } = await db.rpc('pagamento_pos_reservar_msg', { p_order: input.order_id })
  if (error) return json({ error: 'Não foi possível reservar o envio.' }, 500)
  if (!r?.enviar) return json({ ok: true, enviado: false, msg_status: r?.msg_status ?? null })

  const dados = { nome: r.nome as string, pedido: r.pedido as string, previsao: r.previsao as string, arte_status: r.arte_status, entrega: r.entrega, persona: (r.persona as string | undefined) ?? null, artigo: (r.artigo as string | undefined) ?? null }
  let corpo = ''
  let tipo: 'text' | 'template' = 'text'
  let envio = { ok: false, wa_message_id: undefined as string | undefined, erro: undefined as string | undefined }

  if (janelaAberta(r.janela_ate)) {
    corpo = montarConfirmacaoCliente(dados)
    const x = await enviarTexto(env, r.wa_id, corpo)
    envio = { ok: x.ok, wa_message_id: x.wa_message_id, erro: x.erro }
  }
  if (!envio.ok) {
    const st = await statusTemplate(env, db, 'pedido_pago_confirmacao')
    if (st && st !== 'APPROVED') {
      await db.rpc('pagamento_pos_msg_resultado', { p_order: input.order_id, p_status: 'falhou_temp', p_erro: `template pedido_pago_confirmacao: ${st}` })
      return json({ ok: false, error: 'O template pedido_pago_confirmacao ainda não foi aprovado pela Meta.' }, 409)
    }
    const params = templateConfirmacaoCliente(dados)
    const x = await enviarTemplate(env, r.wa_id, 'pedido_pago_confirmacao', params)
    envio = { ok: x.ok, wa_message_id: x.wa_message_id, erro: x.erro }
    tipo = 'template'
    const { data: tpl } = await db.from('templates_cache').select('body').eq('name', 'pedido_pago_confirmacao').eq('language', 'pt_BR').maybeSingle()
    corpo = (tpl?.body ?? 'Pagamento confirmado, {{1}}! Seu pedido {{2}} já entrou na fila. Previsão de ficar pronto: {{3}}.').replace(/\{\{(\d+)\}\}/g, (_m: string, n: string) => params[Number(n) - 1] ?? '')
  }

  if (!envio.ok) {
    await db.rpc('pagamento_pos_msg_resultado', { p_order: input.order_id, p_status: 'falhou_temp', p_erro: envio.erro ?? 'erro' })
    return json({ ok: false, error: 'Não foi possível enviar a confirmação ao cliente agora.' }, 502)
  }

  const now = new Date().toISOString()
  await db.from('messages').insert({
    conversation_id: r.conversation_id, wa_message_id: envio.wa_message_id ?? null, direction: 'out', type: tipo, body: corpo,
    template_name: tipo === 'template' ? 'pedido_pago_confirmacao' : null, status: 'sent', created_at: now,
  })
  await db.from('conversations').update({ last_message_at: now, last_message_preview: corpo.slice(0, 120) }).eq('id', r.conversation_id)
  await db.rpc('pagamento_pos_msg_resultado', { p_order: input.order_id, p_status: 'enviado' })
  return json({ ok: true, enviado: true, via: tipo })
})
