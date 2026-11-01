// GERADO por "node scripts/bundle-funcao.ts proativo-enviar". NÃO edite aqui: edite supabase/functions/ e gere de novo.
// Painel do Supabase > Edge Functions > Deploy a new function (ou Code > Deploy updates) > Via Editor. Nome: proativo-enviar. "Verify JWT" desligado (a função confere o dono ou a service role).
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

// Regras puras do envio proativo (follow-ups, pós-venda e avisos de status). Testadas em scripts/test-proativo.ts.
const JANELA_MS = 24 * 60 * 60 * 1000

/** A janela de atendimento de 24 h (texto livre) está aberta? Só a mensagem do cliente abre; o clique no anúncio só barateia template. */
function janelaAberta(lastInboundAt: string | null | undefined, agora = Date.now()): boolean {
  return !!lastInboundAt && new Date(lastInboundAt).getTime() + JANELA_MS > agora
}

/** Variável de template aceita pela Meta: sem quebra de linha, sem tabulação, sem 4 espaços seguidos, não vazia. */
function limparParametro(valor: unknown): string {
  const t = String(valor ?? '').replace(/[\r\n\t]+/g, ' ').replace(/ {2,}/g, ' ').trim().slice(0, 900)
  return t || '-'
}

type Decisao =
  | { acao: 'livre' }
  | { acao: 'template' }
  | { acao: 'recusar'; motivo: string; permanente: boolean }

interface EntradaDecisao {
  via: 'livre' | 'template'
  janelaAberta: boolean
  temTemplate: boolean
  categoria: string | null // categoria do template na Meta (MARKETING, UTILITY...)
  optout: boolean
  consentimento: string | null // none | opted_in | opted_out
  exigirOptin: boolean
}

/** Decide como (e se) enviar. Utilidade (avisos de pedido) não depende de promoções; marketing exige opt-in. */
function decidirEnvio(e: EntradaDecisao): Decisao {
  if (e.via === 'livre' && e.janelaAberta) return { acao: 'livre' }
  if (!e.temTemplate) return { acao: 'recusar', motivo: 'janela_fechada', permanente: true }
  const marketing = (e.categoria ?? '').toUpperCase() === 'MARKETING'
  if (marketing) {
    if (e.optout || e.consentimento === 'opted_out') return { acao: 'recusar', motivo: 'optout', permanente: true }
    if (e.exigirOptin && e.consentimento !== 'opted_in') return { acao: 'recusar', motivo: 'sem_optin_marketing', permanente: true }
  }
  return { acao: 'template' }
}

/** Erros da Meta que não adianta repetir. */
function erroPermanente(codigo: number | null | undefined): boolean {
  return codigo != null && [131026, 131049, 131050, 131051, 132000, 132001, 132005, 132007, 132012, 132015, 132016].includes(codigo)
}

// Envio proativo (follow-ups, pós-venda e avisos de status): só a service role (WF6, WF7, WF8 do n8n). O token da Meta fica só aqui.
// Texto livre apenas com a janela de 24 h aberta; senão template aprovado. Marketing exige opt-in; contato de teste nunca vai à Meta.
// A reserva (sem duplicar) e o registro do resultado são do banco (followup_* e pedido_aviso_*); esta função só envia e grava a mensagem.
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)
  if (!(await requireServiceRole(req))) return json({ error: 'Não autorizado.' }, 401)
  const env = requireEnv('WHATSAPP_TOKEN', 'WHATSAPP_PHONE_NUMBER_ID') as WaEnv | null
  if (!env) return json({ error: 'Integração com o WhatsApp não configurada no servidor.' }, 500)
  env.WHATSAPP_WABA_ID = Deno.env.get('WHATSAPP_WABA_ID') ?? undefined

  const input = (await req.json().catch(() => ({}))) as { conversation_id?: string; via?: string; texto?: string; template?: string | null; params?: unknown[] | null }
  if (!UUID.test(String(input.conversation_id ?? ''))) return json({ error: 'conversation_id inválido.' }, 400)
  const via = input.via === 'template' ? 'template' : 'livre'
  const texto = String(input.texto ?? '').trim()
  const template = input.template ? String(input.template) : null
  if (!texto) return json({ error: 'Texto vazio.' }, 400)
  if (texto.length > 1500) return json({ error: 'Texto longo demais (limite de 1500 caracteres).' }, 400)

  const db = serviceClient()
  const { data: conv } = await db
    .from('conversations')
    .select('id, last_inbound_at, contact:contacts(wa_id, optout, marketing_consent, tags)')
    .eq('id', input.conversation_id)
    .maybeSingle()
  // deno-lint-ignore no-explicit-any
  const ct = (conv as any)?.contact as { wa_id: string; optout: boolean; marketing_consent: string; tags: string[] | null } | undefined
  if (!conv || !ct?.wa_id) return json({ error: 'Conversa não encontrada.' }, 404)
  if ((ct.tags ?? []).includes('teste')) return json({ ok: true, simulado: true, via: 'simulado' })

  const { data: cfgRow } = await db.from('app_settings').select('value').eq('key', 'followup').maybeSingle()
  const exigirOptin = (cfgRow?.value as { exigir_optin_marketing?: boolean } | null)?.exigir_optin_marketing !== false

  let categoria: string | null = null
  if (template) {
    const { data: tpl } = await db.from('templates_cache').select('category').eq('name', template).eq('language', 'pt_BR').maybeSingle()
    categoria = (tpl?.category as string | null) ?? null
  }
  const decisao = decidirEnvio({
    via, janelaAberta: janelaAberta(conv.last_inbound_at), temTemplate: !!template, categoria,
    optout: !!ct.optout, consentimento: ct.marketing_consent, exigirOptin,
  })
  if (decisao.acao === 'recusar') return json({ ok: false, recusado: true, motivo: decisao.motivo, permanente: decisao.permanente })

  let usado: 'livre' | 'template' = decisao.acao
  let corpo = texto
  let r = { ok: false, wa_message_id: undefined as string | undefined, codigo: null as number | null | undefined, erro: undefined as string | undefined }

  if (usado === 'livre') {
    r = await enviarTexto(env, ct.wa_id, texto)
    // a janela pode ter fechado no meio do caminho (131047): tenta o template se houver
    if (!r.ok && r.codigo === 131047 && template) {
      const d2 = decidirEnvio({ via: 'template', janelaAberta: false, temTemplate: true, categoria, optout: !!ct.optout, consentimento: ct.marketing_consent, exigirOptin })
      if (d2.acao === 'recusar') return json({ ok: false, recusado: true, motivo: d2.motivo, permanente: d2.permanente })
      usado = 'template'
    }
  }
  if (usado === 'template' && template) {
    const st = await statusTemplate(env, db, template)
    if (st && st !== 'APPROVED') {
      return json({ ok: false, permanente: false, motivo: `template_${st.toLowerCase()}`, error: `O template ${template} ainda não está aprovado na Meta (${st}).` })
    }
    const params = (input.params ?? []).map(limparParametro)
    r = await enviarTemplate(env, ct.wa_id, template, params)
    const { data: tpl } = await db.from('templates_cache').select('body').eq('name', template).eq('language', 'pt_BR').maybeSingle()
    corpo = (tpl?.body ? String(tpl.body).replace(/\{\{(\d+)\}\}/g, (_m: string, n: string) => params[Number(n) - 1] ?? '') : texto)
  }
  if (!r.ok) return json({ ok: false, permanente: erroPermanente(r.codigo), motivo: r.erro ?? 'falha', meta_code: r.codigo ?? null })

  const now = new Date().toISOString()
  const { error: insErr } = await db.from('messages').insert({
    conversation_id: conv.id, wa_message_id: r.wa_message_id ?? null, direction: 'out', type: usado === 'template' ? 'template' : 'text', body: corpo,
    template_name: usado === 'template' ? template : null, status: 'sent', created_at: now,
  })
  if (insErr) console.error('Mensagem proativa enviada, mas falhou ao gravar:', insErr.message)
  await db.from('conversations').update({ last_message_at: now, last_message_preview: corpo.slice(0, 120) }).eq('id', conv.id)
  return json({ ok: true, via: usado, wa_message_id: r.wa_message_id ?? null })
})
