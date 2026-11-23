// GERADO por "node scripts/bundle-funcao.ts meta-conversions-api". NÃO edite aqui: edite supabase/functions/ e gere de novo.
// Painel do Supabase > Edge Functions > Deploy a new function (ou Code > Deploy updates) > Via Editor. Nome: meta-conversions-api. "Verify JWT" desligado (a função confere o dono ou a service role).
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

// Conversions API da Meta: monta o corpo de POST /{pixel}/events a partir da fila meta_eventos. Funções puras (testadas em Node).

interface EventoFila {
  id: number; event_id: string; event_name: string; event_time: string; action_source: string
  event_source_url: string | null; messaging_channel?: string | null; user_data: Record<string, string>; custom_data: Record<string, unknown>
}

const HASHEADOS = ['em', 'ph', 'external_id', 'ct', 'st', 'zp', 'country']

/** Formato da Meta: campos com hash vão em lista; ip, user agent, fbp e fbc em texto; event_time em segundos. */
function eventoMeta(e: EventoFila, waba?: string | null) {
  const u: Record<string, string | string[]> = {}
  for (const [k, v] of Object.entries(e.user_data ?? {})) {
    if (!v) continue
    if (HASHEADOS.includes(k)) { if (/^[0-9a-f]{64}$/.test(v)) u[k] = [v] } else u[k] = v
  }
  // Business Messaging (WhatsApp): a Meta atribui pelo ctwa_clid e pelo WABA, em texto puro, e não aceita URL de origem.
  const chat = e.action_source === 'business_messaging'
  if (chat && waba) u.whatsapp_business_account_id = waba
  return {
    event_name: e.event_name,
    event_time: Math.floor(new Date(e.event_time).getTime() / 1000),
    event_id: e.event_id,
    action_source: e.action_source,
    ...(chat ? { messaging_channel: e.messaging_channel || 'whatsapp' } : {}),
    ...(e.event_source_url && !chat ? { event_source_url: e.event_source_url } : {}),
    user_data: u,
    ...(Object.keys(e.custom_data ?? {}).length ? { custom_data: e.custom_data } : {}),
  }
}

function corpoMeta(eventos: EventoFila[], testCode?: string | null, waba?: string | null) {
  return { data: eventos.map((e) => eventoMeta(e, waba)), ...(testCode ? { test_event_code: testCode } : {}) }
}

/** SHA-256 em hex de texto normalizado (minúsculas, sem espaços nas pontas), como a Meta pede. */
async function sha256(texto: string): Promise<string> {
  const d = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(texto.trim().toLowerCase()))
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, '0')).join('')
}

// E-commerce Fase 7: envia a fila meta_eventos para a Conversions API da Meta (deduplicada com o Pixel pelo event_id).
// Chamada pelo agendamento (x-cron-secret) ou pelo dono/service role. Sem META_PIXEL_ID e META_CAPI_TOKEN não consome a fila
// e avisa o dono uma vez por dia (Fase 1 do Plano de Ação: antes o retorno era silencioso e a fila nunca era conferida).
// Logs sem dados pessoais.
const VERSAO = 'v21.0'

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)
  const db = serviceClient()
  const cron = Deno.env.get('CRON_SECRET')
  const enviado = req.headers.get('x-cron-secret')
  const doCron = !!cron && !!enviado && enviado.length === cron.length && enviado === cron
  if (!doCron && !(await requireOwnerOrServer(req, db))) return json({ error: 'Não autorizado.' }, 401)

  const pixel = Deno.env.get('META_PIXEL_ID')
  const token = Deno.env.get('META_CAPI_TOKEN')
  if (!pixel || !token) {
    const { count } = await db.from('meta_eventos').select('id', { count: 'exact', head: true }).eq('status', 'pendente')
    const hoje = new Date().toISOString().slice(0, 10)
    const faltando = [!pixel && 'META_PIXEL_ID', !token && 'META_CAPI_TOKEN'].filter(Boolean).join(' e ')
    await db.rpc('alerta_criar', {
      p_tipo: 'meta_capi_sem_segredo', p_gravidade: 'alta', p_contact: null, p_conversation: null, p_order: null,
      p_motivo: `A Conversions API da Meta está sem ${faltando}: ${count ?? 0} eventos de venda parados na fila, sem chegar à Meta. Cadastre o(s) segredo(s) nas Secrets das Edge Functions do Supabase.`,
      p_dados: { pendentes: count ?? 0, faltando: faltando }, p_chave: `meta_capi_sem_segredo:${hoje}`, p_canais: ['whatsapp'],
    }).then(({ error }) => { if (error) console.error('meta-conversions-api: alerta falhou', error.message) })
    return json({ ok: true, configurado: false })
  }
  const { data: cfg } = await db.from('app_settings').select('value').eq('key', 'meta_capi').maybeSingle()
  const c = (cfg?.value ?? {}) as { ligado?: boolean; test_event_code?: string | null }
  if (c.ligado === false) return json({ ok: true, desligado: true })

  const { data: lote, error } = await db.rpc('meta_eventos_lote', { p_n: 500 })
  if (error) return json({ error: 'Não foi possível ler a fila.' }, 500)
  const todos = (lote ?? []) as EventoFila[]
  if (!todos.length) return json({ ok: true, enviados: 0 })
  // Business Messaging exige o WABA; sem ele o evento volta para a fila com o motivo, sem ir quebrado para a Meta.
  const waba = Deno.env.get('WHATSAPP_WABA_ID') || null
  const semWaba = waba ? [] : todos.filter((e) => e.action_source === 'business_messaging')
  if (semWaba.length) await db.rpc('meta_eventos_resultado', { p_ids: semWaba.map((e) => e.id), p_ok: false, p_erro: 'sem WHATSAPP_WABA_ID' })
  const eventos = todos.filter((e) => !semWaba.includes(e))
  if (!eventos.length) return json({ ok: true, enviados: 0, sem_waba: semWaba.length })
  // Chat (Business Messaging) e site vão em pedidos separados: um evento recusado de um lado não derruba o outro.
  const grupos = [eventos.filter((e) => e.action_source !== 'business_messaging'), eventos.filter((e) => e.action_source === 'business_messaging')].filter((g) => g.length)
  let enviados = 0
  let falhas = 0
  for (const g of grupos) {
    const ids = g.map((e) => e.id)
    try {
      const res = await fetch(`https://graph.facebook.com/${VERSAO}/${pixel}/events?access_token=${encodeURIComponent(token)}`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(corpoMeta(g, c.test_event_code, waba)),
      })
      const r = await res.json().catch(() => ({})) as { events_received?: number; error?: { message?: string; code?: number } }
      if (!res.ok) {
        falhas++
        await db.rpc('meta_eventos_resultado', { p_ids: ids, p_ok: false, p_erro: `${res.status} ${r.error?.code ?? ''} ${r.error?.message ?? ''}`.trim() })
        console.error('meta-conversions-api: recusado', res.status, r.error?.code)
        continue
      }
      await db.rpc('meta_eventos_resultado', { p_ids: ids, p_ok: true })
      enviados += r.events_received ?? ids.length
    } catch {
      falhas++
      await db.rpc('meta_eventos_resultado', { p_ids: ids, p_ok: false, p_erro: 'falha de rede' })
    }
  }
  console.log(`meta-conversions-api: ${enviados} eventos recebidos, ${falhas} lotes com falha`)
  if (falhas && !enviados) return json({ error: 'A Meta recusou o lote.' }, 502)
  return json({ ok: true, enviados, lotes_com_falha: falhas })
})
