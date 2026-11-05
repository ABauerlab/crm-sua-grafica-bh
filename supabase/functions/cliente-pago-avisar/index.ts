// GERADO por script de atualizacao do cliente-pago-avisar
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

/** Só a service role (outro servidor da própria Sua Gráfica, como o n8n). Nenhum usuário logado passa. */
async function requireServiceRole(req: Request): Promise<boolean> {
  const token = req.headers.get('Authorization')?.replace(/^Bearer\s+/i, '')
  if (!token) return false
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
  if (serviceKey && token.length === serviceKey.length && token === serviceKey) return true
  return ehServiceRole(token)
}

const corta = (s: string, n: number): string => (s.length <= n ? s : s.slice(0, n - 1).trimEnd() + '…')

/** Variáveis de template: sem quebra de linha, tabulação nem 4 espaços seguidos (regra da Meta); nunca vazias. */
function varTemplate(v: unknown, max = 200): string {
  const s = String(v ?? '').replace(/[\r\n\t]+/g, ' ').replace(/ {2,}/g, ' ').trim()
  return corta(s || '-', max)
}

/** Mensagem humanizada e personalizada ao cliente depois do pagamento. Sem 'assistente virtual' e respeitando o checklist da arte e prazo manual. */
function montarConfirmacaoCliente(i: {
  nome: string
  pedido: string
  previsao: string
  prazo_manual?: boolean
  arte_status?: string | null
  entrega?: string | null
  persona?: string | null
  artigo?: string | null
}): string {
  // Versão curta: confirmação, pedido, previsão, uma frase sobre a arte e uma sobre a retirada
  const arte =
    i.arte_status === 'aprovada'
      ? 'Arte aprovada, seguimos para produção.'
      : i.arte_status === 'enviada'
        ? 'Recebemos a sua arte e estamos conferindo.'
        : i.arte_status === 'em_criacao'
          ? 'Estamos montando a arte para você aprovar.'
          : 'Tem arte? É só mandar aqui.'
  const entrega = i.entrega === 'uber' ? 'Combinamos a entrega por aqui.' : 'Aviso aqui quando estiver pronto para retirada.'
  const previsao = i.prazo_manual ? `Prazo combinado: ${i.previsao}.` : `Previsão: ${i.previsao}.`
  const quem = i.persona ? `Aqui é ${i.artigo ? i.artigo + ' ' : ''}${i.persona}. ` : ''
  return `${i.persona ? `Oi, ${i.nome}! ` : ''}${quem}${i.persona ? 'Pagamento confirmado' : `Pagamento confirmado, ${i.nome}`}! Pedido ${i.pedido} na fila. ${previsao} ${arte} ${entrega}`
}

/** Variáveis do template pedido_pago_confirmacao: nome, número do pedido, previsão. */
function templateConfirmacaoCliente(i: { nome: string; pedido: string; previsao: string }): string[] {
  return [varTemplate(i.nome, 60), varTemplate(i.pedido, 30), varTemplate(i.previsao, 30)]
}

function janelaAberta(janelaAte: string | null | undefined, agora = Date.now()): boolean {
  if (!janelaAte) return false
  const t = Date.parse(janelaAte)
  return Number.isFinite(t) && t > agora
}

// Envio pela API oficial do WhatsApp (Graph). O token fica só no servidor.
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

  const dados = {
    nome: r.nome as string,
    pedido: r.pedido as string,
    previsao: r.previsao as string,
    prazo_manual: r.prazo_manual === true,
    arte_status: r.arte_status,
    entrega: r.entrega,
    persona: (r.persona as string | undefined) ?? null,
    artigo: (r.artigo as string | undefined) ?? null,
  }
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
