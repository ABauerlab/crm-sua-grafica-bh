// GERADO por "node scripts/bundle-funcao.ts whatsapp-webhook". NÃO edite aqui: edite supabase/functions/ e gere de novo.
// Painel do Supabase > Edge Functions > Deploy a new function (ou Code > Deploy updates) > Via Editor. Nome: whatsapp-webhook. "Verify JWT" desligado (a função confere o dono ou a service role).
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2'
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2'
// Aciona o WF1 (n8n) depois que o webhook da Meta gravou uma mensagem de entrada.
// Não existe outro webhook na Meta: este é o único receptor, e ele só avisa o n8n com o id da mensagem (nunca o conteúdo).
// Nunca lança e nunca atrasa a resposta à Meta por mais que o tempo limite: o n8n lê tudo do banco e é idempotente por mensagem.
const AGENTE_TIMEOUT_MS = 3000

async function acionarAgente(
  messageId: string,
  env: { url?: string | null; token?: string | null },
  doFetch: typeof fetch = fetch,
): Promise<'enviado' | 'desligado' | 'falhou'> {
  if (!env.url || !env.token) return 'desligado' // sem segredos configurados o agente fica fora do caminho
  const ctl = new AbortController()
  const t = setTimeout(() => ctl.abort(), AGENTE_TIMEOUT_MS)
  try {
    const res = await doFetch(env.url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-gbh-token': env.token },
      body: JSON.stringify({ message_id: messageId }),
      signal: ctl.signal,
    })
    if (!res.ok) {
      console.error('WF1 recusou o aviso:', res.status)
      return 'falhou'
    }
    return 'enviado'
  } catch {
    console.error('Não foi possível avisar o WF1 (a mensagem já está gravada).')
    return 'falhou'
  } finally {
    clearTimeout(t)
  }
}

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

const GRAPH = 'https://graph.facebook.com/v21.0'

const OPT_OUT_CONFIRMATION =
  'Pronto! Você não receberá mais mensagens promocionais da Sua Gráfica BH. Avisos sobre pedidos em andamento continuam normalmente. Para voltar a receber, é só nos avisar por aqui.'

/**
 * Confirma o descadastro dentro da janela de 24h (o cliente acabou de escrever) e registra a resposta no chat.
 * Nunca lança: falha aqui não pode fazer a Meta reenviar o webhook. Logs sem conteúdo de mensagens.
 */
async function confirmOptOut(db: SupabaseClient, contactId: string, waId: string): Promise<void> {
  const token = Deno.env.get('WHATSAPP_TOKEN')
  const phoneNumberId = Deno.env.get('WHATSAPP_PHONE_NUMBER_ID')
  if (!token || !phoneNumberId) return

  try {
    const res = await fetch(`${GRAPH}/${phoneNumberId}/messages`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        messaging_product: 'whatsapp',
        to: waId,
        type: 'text',
        text: { body: OPT_OUT_CONFIRMATION, preview_url: false },
      }),
    })
    const result = await res.json().catch(() => ({}))
    if (!res.ok) {
      console.error('Confirmação de descadastro recusada pela Meta:', result?.error?.code)
      return
    }

    const { data: conv } = await db.from('conversations').select('id').eq('contact_id', contactId).maybeSingle()
    if (!conv) return
    const now = new Date().toISOString()
    await db.from('messages').insert({
      conversation_id: conv.id,
      wa_message_id: result?.messages?.[0]?.id ?? null,
      direction: 'out',
      type: 'text',
      body: OPT_OUT_CONFIRMATION,
      status: 'sent',
      created_at: now,
    })
    await db
      .from('conversations')
      .update({ last_message_at: now, last_message_preview: OPT_OUT_CONFIRMATION.slice(0, 120) })
      .eq('id', conv.id)
  } catch (err) {
    console.error('Falha ao confirmar descadastro:', err instanceof Error ? err.message : 'erro desconhecido')
  }
}

// Extração dos eventos do payload do webhook do WhatsApp Cloud API (sem dependências de Deno).

type InboundType = 'text' | 'image' | 'document' | 'audio' | 'other'

interface InboundMessage {
  waId: string
  name: string | null
  waMessageId: string
  type: InboundType
  body: string
  mediaId: string | null
  timestamp: Date
  /** Origem do anúncio (click to WhatsApp), presente só na primeira mensagem vinda de anúncio. */
  referral: Referral | null
}

interface Referral {
  sourceUrl: string | null
  sourceId: string | null
  sourceType: string | null
  headline: string | null
  body: string | null
  mediaType: string | null
  ctwaClid: string | null
}

interface StatusUpdate {
  waMessageId: string
  status: 'sent' | 'delivered' | 'read' | 'failed'
  error: string | null
}

// deno-lint-ignore no-explicit-any
type Json = any

const MEDIA_LABELS: Record<string, [InboundType, string]> = {
  image: ['image', '[imagem recebida]'],
  document: ['document', '[documento recebido]'],
  audio: ['audio', '[áudio recebido]'],
  video: ['other', '[vídeo recebido]'],
  sticker: ['other', '[figurinha recebida]'],
}

function extractReferral(r: Json): Referral | null {
  if (!r || typeof r !== 'object') return null
  const str = (v: Json) => (typeof v === 'string' && v ? v : null)
  const out = {
    sourceUrl: str(r.source_url),
    sourceId: str(r.source_id),
    sourceType: str(r.source_type),
    headline: str(r.headline),
    body: str(r.body),
    mediaType: str(r.media_type),
    ctwaClid: str(r.ctwa_clid),
  }
  return Object.values(out).some(Boolean) ? out : null
}

function extractEvents(payload: Json): { messages: InboundMessage[]; statuses: StatusUpdate[] } {
  const messages: InboundMessage[] = []
  const statuses: StatusUpdate[] = []

  for (const entry of payload?.entry ?? []) {
    for (const change of entry?.changes ?? []) {
      const value = change?.value
      if (!value) continue

      const names = new Map<string, string>()
      for (const c of value.contacts ?? []) {
        if (c?.wa_id && c?.profile?.name) names.set(String(c.wa_id), String(c.profile.name))
      }

      for (const m of value.messages ?? []) {
        if (!m?.id || !m?.from) continue
        const waId = String(m.from).replace(/\D/g, '')
        if (!waId) continue
        const ts = new Date(Number(m.timestamp) * 1000)
        const base = {
          waId,
          name: names.get(String(m.from)) ?? null,
          waMessageId: String(m.id),
          timestamp: Number.isNaN(ts.getTime()) ? new Date() : ts,
          referral: extractReferral(m.referral),
        }

        const media = MEDIA_LABELS[m.type]
        if (m.type === 'text') {
          messages.push({ ...base, type: 'text', body: String(m.text?.body ?? ''), mediaId: null })
        } else if (media) {
          const caption = m[m.type]?.caption
          messages.push({
            ...base,
            type: media[0],
            body: caption ? `${media[1]} ${caption}` : media[1],
            mediaId: m[m.type]?.id ?? null,
          })
        } else if (m.type === 'location' && m.location) {
          const { latitude, longitude, name, address } = m.location
          const label = [name, address].filter(Boolean).join(', ')
          messages.push({
            ...base,
            type: 'other',
            body: `[localização] ${label ? `${label} ` : ''}https://www.google.com/maps?q=${latitude},${longitude}`,
            mediaId: null,
          })
        } else if (m.type === 'button' && m.button?.text) {
          messages.push({ ...base, type: 'text', body: String(m.button.text), mediaId: null })
        } else if (m.type === 'interactive') {
          const title = m.interactive?.button_reply?.title ?? m.interactive?.list_reply?.title
          messages.push({ ...base, type: 'text', body: title ? String(title) : '[mensagem não suportada]', mediaId: null })
        } else {
          messages.push({ ...base, type: 'other', body: '[mensagem não suportada]', mediaId: null })
        }
      }

      for (const s of value.statuses ?? []) {
        if (!s?.id || !['sent', 'delivered', 'read', 'failed'].includes(s.status)) continue
        const err = s.errors?.[0]
        statuses.push({
          waMessageId: String(s.id),
          status: s.status,
          error: err ? [err.code, err.title ?? err.message].filter(Boolean).join(' - ') : null,
        })
      }
    }
  }

  return { messages, statuses }
}

const RANK: Record<string, number> = { sent: 1, delivered: 2, read: 3 }

/** Eventos da Meta podem chegar fora de ordem: 'read' nunca volta para 'delivered'. */
function shouldApplyStatus(current: string | null, next: StatusUpdate['status']): boolean {
  if (next === 'failed') return current !== 'read'
  if (!current || current === 'failed') return true
  return (RANK[next] ?? 0) > (RANK[current] ?? 0)
}

const OPT_OUT_KEYWORDS = new Set([
  'PARAR',
  'SAIR',
  'STOP',
  'DESCADASTRAR',
  'PARAR DE RECEBER',
  'SAIR DA LISTA',
  'CANCELAR INSCRICAO',
  'PARAR PROMOCOES',
  'PARAR DE RECEBER PROMOCOES',
  'NAO QUERO RECEBER',
  'NAO QUERO MAIS',
  'NAO QUERO MAIS RECEBER',
  'NAO QUERO MAIS MENSAGENS',
  'PARE',
])

/** Pedido de descadastro das promoções: a mensagem inteira precisa ser a palavra-chave (evita "quero parar o pedido"). */
function isOptOutMessage(body: string): boolean {
  const normalized = body
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toUpperCase()
    .replace(/[^A-Z0-9 ]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
  return OPT_OUT_KEYWORDS.has(normalized)
}

// Validação do X-Hub-Signature-256 da Meta (HMAC SHA256 do corpo bruto com o App Secret).
// Sem dependências de Deno: roda também no Node para os testes.

const encoder = new TextEncoder()

function hexToBytes(hex: string): Uint8Array | null {
  if (hex.length % 2 !== 0 || !/^[0-9a-f]+$/i.test(hex)) return null
  const out = new Uint8Array(hex.length / 2)
  for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16)
  return out
}

async function hmacSha256Hex(secret: string, body: string): Promise<string> {
  const key = await crypto.subtle.importKey('raw', encoder.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
  const sig = new Uint8Array(await crypto.subtle.sign('HMAC', key, encoder.encode(body)))
  return Array.from(sig, (b) => b.toString(16).padStart(2, '0')).join('')
}

/** Compara em tempo constante usando crypto.subtle.verify. */
async function verifySignature(rawBody: string, header: string | null, appSecret: string): Promise<boolean> {
  if (!header || !appSecret || !header.startsWith('sha256=')) return false
  const provided = hexToBytes(header.slice('sha256='.length))
  if (!provided) return false
  const key = await crypto.subtle.importKey('raw', encoder.encode(appSecret), { name: 'HMAC', hash: 'SHA-256' }, false, ['verify'])
  return crypto.subtle.verify('HMAC', key, provided, encoder.encode(rawBody))
}

// verify_jwt = false: quem chama é a Meta. A autenticidade vem do X-Hub-Signature-256.
Deno.serve(async (req) => {
  const url = new URL(req.url)

  if (req.method === 'GET') {
    const verifyToken = Deno.env.get('WHATSAPP_VERIFY_TOKEN')
    if (
      verifyToken &&
      url.searchParams.get('hub.mode') === 'subscribe' &&
      url.searchParams.get('hub.verify_token') === verifyToken
    ) {
      return new Response(url.searchParams.get('hub.challenge') ?? '', { status: 200 })
    }
    return new Response('Forbidden', { status: 403 })
  }

  if (req.method !== 'POST') return new Response('Method Not Allowed', { status: 405 })

  const appSecret = Deno.env.get('META_APP_SECRET')
  if (!appSecret) {
    console.error('Segredo ausente: META_APP_SECRET')
    return new Response('Server misconfigured', { status: 500 })
  }

  // Corpo bruto: a assinatura é calculada sobre os bytes exatos recebidos.
  const raw = await req.text()
  if (!(await verifySignature(raw, req.headers.get('X-Hub-Signature-256'), appSecret))) {
    return new Response('Invalid signature', { status: 401 })
  }

  let payload
  try {
    payload = JSON.parse(raw)
  } catch {
    return new Response('Bad request', { status: 400 })
  }

  const db = serviceClient()
  const { messages, statuses } = extractEvents(payload)

  try {
    for (const m of messages) {
      const { data: gravada, error } = await db.rpc('ingest_inbound_message', {
        p_wa_id: m.waId,
        p_name: m.name,
        p_wa_message_id: m.waMessageId,
        p_type: m.type,
        p_body: m.body,
        p_media_id: m.mediaId,
        p_ts: m.timestamp.toISOString(),
        p_referral: m.referral
          ? {
              source_url: m.referral.sourceUrl,
              source_id: m.referral.sourceId,
              source_type: m.referral.sourceType,
              headline: m.referral.headline,
              body: m.referral.body,
              media_type: m.referral.mediaType,
              ctwa_clid: m.referral.ctwaClid,
            }
          : null,
      })
      if (error) throw error

      // "PARAR": registra o descadastro das promoções (mensagens de pedido seguem normalmente)
      if (m.type === 'text' && isOptOutMessage(m.body)) {
        // só na mudança de estado: reenvio do webhook ou PARAR repetido não gera nova confirmação
        const { data: changed, error: optErr } = await db
          .from('contacts')
          .update({ marketing_consent: 'opted_out', marketing_consent_at: new Date().toISOString(), marketing_consent_source: 'whatsapp' })
          .eq('wa_id', m.waId)
          .neq('marketing_consent', 'opted_out')
          .select('id')
        if (optErr) throw optErr
        if (changed?.length) await confirmOptOut(db, changed[0].id, m.waId)
      }

      // Mensagem nova (a duplicada devolve null) e que não é o PARAR: avisa o WF1 do n8n, depois do descadastro (o agente confere o optout).
      // O agente decide se responde; falha aqui nunca derruba o webhook.
      if (gravada && !(m.type === 'text' && isOptOutMessage(m.body))) {
        await acionarAgente(String(gravada), { url: Deno.env.get('N8N_WF1_URL'), token: Deno.env.get('N8N_WF1_TOKEN') })
      }
    }

    for (const s of statuses) {
      const { data: current } = await db.from('messages').select('status').eq('wa_message_id', s.waMessageId).maybeSingle()
      if (!current || !shouldApplyStatus(current.status, s.status)) continue
      const { error } = await db
        .from('messages')
        .update({ status: s.status, error: s.status === 'failed' ? s.error : null })
        .eq('wa_message_id', s.waMessageId)
      if (error) throw error
    }
  } catch (err) {
    // Sem conteúdo de mensagens nos logs. A Meta reenvia em caso de 500 (gravação é idempotente).
    console.error('Falha ao processar webhook:', err instanceof Error ? err.message : 'erro desconhecido')
    return new Response('Error', { status: 500 })
  }

  return new Response('OK', { status: 200 })
})
