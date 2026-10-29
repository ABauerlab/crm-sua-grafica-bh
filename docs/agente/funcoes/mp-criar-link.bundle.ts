// GERADO por "node scripts/bundle-funcao.ts mp-criar-link". NÃO edite aqui: edite supabase/functions/ e gere de novo.
// Painel do Supabase > Edge Functions > Deploy a new function (ou Code > Deploy updates) > Via Editor. Nome: mp-criar-link. "Verify JWT" desligado (a função confere o dono ou a service role).
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

// Regras puras da integração com o Mercado Pago. Sem APIs de Deno: roda também no Node para os testes.
type MpModo = 'teste' | 'producao'
type PagamentoStatus = 'pendente' | 'em_analise' | 'aprovado' | 'recusado' | 'cancelado' | 'expirado' | 'estornado' | 'contestado'

/** Janela aceita entre o carimbo da assinatura e a hora do servidor (protege contra replay). */
const JANELA_PADRAO_MS = 10 * 60 * 1000

const API = 'https://api.mercadopago.com'

function parseModo(v: string | undefined | null): MpModo | null {
  const m = (v ?? '').trim().toLowerCase()
  return m === 'teste' || m === 'producao' ? m : null
}

/** "SG-0001" para o pedido 1. */
function formatReference(n: number): string {
  return `SG-${String(n).padStart(4, '0')}`
}

function parseReference(ref: string | null | undefined): number | null {
  const m = /^SG-(\d{1,12})$/.exec((ref ?? '').trim())
  return m ? Number(m[1]) : null
}

const toCents = (v: number): number => Math.round(v * 100)

function parseSignatureHeader(header: string | null): { ts: string; v1: string } | null {
  if (!header) return null
  let ts = ''
  let v1 = ''
  for (const part of header.split(',')) {
    const i = part.indexOf('=')
    if (i < 0) continue
    const k = part.slice(0, i).trim()
    const v = part.slice(i + 1).trim()
    if (k === 'ts') ts = v
    else if (k === 'v1') v1 = v
  }
  return ts && v1 ? { ts, v1 } : null
}

/** Manifesto assinado pelo Mercado Pago: id (da URL, minúsculo se alfanumérico), request-id e ts. */
function buildManifest(dataId: string | null, requestId: string | null, ts: string): string {
  let m = ''
  if (dataId) m += `id:${/^[a-z0-9]+$/i.test(dataId) ? dataId.toLowerCase() : dataId};`
  if (requestId) m += `request-id:${requestId};`
  m += `ts:${ts};`
  return m
}

/** O carimbo vem em milissegundos; aceita também segundos. */
function tsToMs(ts: string): number | null {
  const n = Number(ts)
  if (!Number.isFinite(n) || n <= 0) return null
  return n < 1e11 ? n * 1000 : n
}

type SignatureResult = { ok: true } | { ok: false; reason: 'ausente' | 'formato' | 'antiga' | 'invalida' }

async function verifyMpSignature(opts: {
  secret: string
  signatureHeader: string | null
  requestId: string | null
  dataId: string | null
  nowMs?: number
  windowMs?: number
}): Promise<SignatureResult> {
  if (!opts.signatureHeader) return { ok: false, reason: 'ausente' }
  const parsed = parseSignatureHeader(opts.signatureHeader)
  const tsMs = parsed ? tsToMs(parsed.ts) : null
  if (!parsed || tsMs === null || !/^[0-9a-f]{64}$/i.test(parsed.v1)) return { ok: false, reason: 'formato' }
  const expected = await hmacSha256Hex(opts.secret, buildManifest(opts.dataId, opts.requestId, parsed.ts))
  if (!timingSafeEqualHex(expected, parsed.v1.toLowerCase())) return { ok: false, reason: 'invalida' }
  // A janela só vale depois da assinatura conferida, para não revelar nada a quem não a conhece.
  if (Math.abs((opts.nowMs ?? Date.now()) - tsMs) > (opts.windowMs ?? JANELA_PADRAO_MS)) return { ok: false, reason: 'antiga' }
  return { ok: true }
}

function timingSafeEqualHex(a: string, b: string): boolean {
  if (a.length !== b.length) return false
  let diff = 0
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return diff === 0
}

/** Status do Mercado Pago para o status do CRM. */
function mapStatus(status: string, detail?: string | null): PagamentoStatus {
  switch (status) {
    case 'approved':
      return 'aprovado'
    case 'pending':
      return 'pendente'
    case 'authorized':
    case 'in_process':
    case 'in_mediation':
      return 'em_analise'
    case 'rejected':
      return 'recusado'
    case 'cancelled':
      return detail === 'expired' ? 'expirado' : 'cancelado'
    case 'refunded':
      return 'estornado'
    case 'charged_back':
      return 'contestado'
    default:
      return 'pendente'
  }
}

interface LinhaPedido {
  description: string
  qty: number
  unit_price: number
}

interface ItemPreferencia {
  id: string
  title: string
  description: string
  category_id: string
  quantity: 1
  unit_price: number
  currency_id: 'BRL'
}

/**
 * Itens da preferência: uma linha por item do orçamento, já com o desconto, em centavos exatos.
 * O Mercado Pago soma as linhas, então a última absorve o arredondamento e o total fecha com o valor do sistema.
 * Só descrição comercial: nunca código do fornecedor nem custo.
 */
function buildItems(lines: LinhaPedido[], totalCents: number): ItemPreferencia[] {
  const gross = lines.reduce((n, l) => n + toCents(l.unit_price) * l.qty, 0)
  if (!lines.length || gross <= 0 || totalCents <= 0) return []
  let left = totalCents
  return lines.map((l, i) => {
    const raw = toCents(l.unit_price) * l.qty
    const cents = i === lines.length - 1 ? left : Math.round((raw * totalCents) / gross)
    left -= cents
    return {
      id: `item-${i + 1}`,
      title: `${l.qty}x ${l.description}`.slice(0, 250),
      description: l.description.slice(0, 250),
      category_id: 'services', // ajuda o antifraude do Mercado Pago (taxa de aprovação)
      quantity: 1,
      unit_price: cents / 100,
      currency_id: 'BRL',
    }
  })
}

/** Horas de validade do link: padrão 48, aceita menos (mínimo 6 minutos) e no máximo 168. */
function parseExpiraHoras(v: unknown): number {
  if (v === undefined || v === null || v === '') return 48
  const n = Number(v)
  if (!Number.isFinite(n) || n < 0.1 || n > 168) throw new Error('expira_horas deve ficar entre 0,1 e 168.')
  return n
}

function buildPreference(opts: {
  items: ItemPreferencia[]
  reference: string
  notificationUrl: string
  backBase: string
  now: Date
  horas: number
}) {
  const to = new Date(opts.now.getTime() + opts.horas * 3_600_000)
  return {
    items: opts.items,
    external_reference: opts.reference,
    notification_url: opts.notificationUrl,
    back_urls: {
      success: `${opts.backBase}/pagamento/obrigado?r=ok`,
      pending: `${opts.backBase}/pagamento/obrigado?r=pendente`,
      failure: `${opts.backBase}/pagamento/obrigado?r=falhou`,
    },
    auto_return: 'approved',
    expires: true,
    expiration_date_from: opts.now.toISOString(),
    expiration_date_to: to.toISOString(),
    statement_descriptor: 'SUAGRAFICABH',
    // Pix e cartão. Boleto e lotérica ficam de fora.
    payment_methods: { excluded_payment_types: [{ id: 'ticket' }, { id: 'atm' }] },
  }
}

interface MpConfig {
  modo: MpModo | null
  token: string | null
  signatureSecret: string | null
  /** Nomes (nunca valores) dos segredos que faltam para o modo atual. */
  faltando: string[]
}

/** Lê MP_MODO e os segredos do modo escolhido. Teste e produção têm segredos separados. */
function mpConfig(): MpConfig {
  const modo = parseModo(Deno.env.get('MP_MODO'))
  if (!modo) return { modo: null, token: null, signatureSecret: null, faltando: ['MP_MODO (teste ou producao)'] }
  const sufixo = modo === 'teste' ? 'TESTE' : 'PRODUCAO'
  const token = Deno.env.get(`MP_ACCESS_TOKEN_${sufixo}`) || null
  const signatureSecret = Deno.env.get(`MP_WEBHOOK_SECRET_${sufixo}`) || null
  const faltando: string[] = []
  if (!token) faltando.push(`MP_ACCESS_TOKEN_${sufixo}`)
  if (!signatureSecret) faltando.push(`MP_WEBHOOK_SECRET_${sufixo}`)
  return { modo, token, signatureSecret, faltando }
}

const webhookUrl = () => `${Deno.env.get('SUPABASE_URL')}/functions/v1/mp-webhook`

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

interface Body {
  acao?: 'status'
  pedido_id?: string
  orcamento_id?: string // no CRM o orçamento é o próprio pedido; aceito como apelido
  expira_horas?: number
  forcar_novo?: boolean
}

// Cria (ou devolve) o link de pagamento do Checkout Pro de um pedido. O valor vem sempre do banco, nunca do chamador.
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)

  const db = serviceClient()
  if (!(await requireOwnerOrServer(req, db))) return json({ error: 'Não autorizado.' }, 401)

  let input: Body
  try {
    input = await req.json()
  } catch {
    return json({ error: 'Corpo da requisição inválido.' }, 400)
  }

  const cfg = mpConfig()
  if (input.acao === 'status') {
    return json({ modo: cfg.modo, pronto: !!cfg.modo && cfg.faltando.length === 0, faltando: cfg.faltando, webhook_url: webhookUrl() })
  }
  if (!cfg.modo || !cfg.token) return json({ error: `Mercado Pago não configurado no servidor. Faltam: ${cfg.faltando.join(', ')}.` }, 500)

  const orderId = input.pedido_id ?? input.orcamento_id
  if (!orderId || !UUID.test(orderId)) return json({ error: 'Informe pedido_id.' }, 400)
  let horas: number
  try {
    horas = parseExpiraHoras(input.expira_horas)
  } catch (e) {
    return json({ error: (e as Error).message }, 400)
  }

  const { data: order } = await db.from('orders').select('id, number, teste').eq('id', orderId).maybeSingle()
  if (!order) return json({ error: 'Pedido não encontrado.' }, 404)
  if (cfg.modo === 'producao' && order.teste) return json({ error: 'Este é um pedido de teste e o servidor está em modo produção.' }, 422)

  // Ponto de extensão de regras (piso, margem...) antes de qualquer cobrança
  const { data: recusa, error: valErr } = await db.rpc('validar_antes_de_cobrar', { p_order: orderId })
  if (valErr) return json({ error: 'Não foi possível validar o pedido.' }, 500)
  if (recusa) return json({ error: String(recusa) }, 422)

  const [{ data: fin }, { data: itens }] = await Promise.all([
    db.from('order_financials').select('total').eq('order_id', orderId).maybeSingle(),
    db.from('order_items').select('description, qty, unit_price').eq('order_id', orderId).order('created_at'),
  ])
  const totalCents = toCents(Number(fin?.total ?? 0))
  const items = buildItems((itens ?? []).map((i) => ({ description: i.description, qty: i.qty, unit_price: Number(i.unit_price) })), totalCents)
  if (totalCents <= 0 || items.length === 0) return json({ error: 'O pedido precisa ter itens e valor maior que zero.' }, 422)

  let aviso: string | undefined
  const resposta = (l: { id: string; link: string | null; valor: number; expira_em: string | null }, reutilizado: boolean) =>
    json({ link: l.link, pagamento_id: l.id, valor: Number(l.valor), expira_em: l.expira_em, modo: cfg.modo, referencia: formatReference(order.number), reutilizado, ...(aviso ? { aviso } : {}) })

  // Mesmo pedido, mesmo valor, link ainda válido: devolve o mesmo link
  const { data: ativo } = await db.from('pagamentos').select('*').eq('order_id', orderId).eq('modo', cfg.modo).eq('eh_link', true).eq('link_ativo', true).maybeSingle()
  if (ativo) {
    const valido = ativo.expira_em && new Date(ativo.expira_em).getTime() > Date.now()
    if (valido && toCents(Number(ativo.valor)) === totalCents && !input.forcar_novo) return resposta(ativo, true)
    // Valor mudou, expirou ou foi pedido um novo: invalida o anterior (também no Mercado Pago, sem expor nada)
    await db.from('pagamentos').update({ link_ativo: false, status: ativo.mp_payment_id ? ativo.status : 'invalidado', atualizado_em: new Date().toISOString() }).eq('id', ativo.id)
    if (ativo.mp_preference_id && valido) {
      // Expira o link antigo no Mercado Pago para ninguém pagar o valor errado. Confere a resposta e avisa se não deu certo.
      const fim = new Date(Date.now() - 1000).toISOString()
      const put = await fetch(`${API}/checkout/preferences/${encodeURIComponent(ativo.mp_preference_id)}`, {
        method: 'PUT',
        headers: { Authorization: `Bearer ${cfg.token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ expires: true, expiration_date_from: new Date(ativo.criado_em).toISOString(), expiration_date_to: fim }),
      }).catch(() => null)
      if (!put || !put.ok) {
        console.error('Mercado Pago não expirou a preferência anterior', put?.status ?? 'sem resposta')
        aviso = 'O link antigo não foi desativado no Mercado Pago. Se o cliente ainda tiver o link antigo, o pagamento chega como divergência em Alertas e o pedido não muda sozinho.'
      }
    }
  }

  const now = new Date()
  const preference = buildPreference({
    items,
    reference: formatReference(order.number),
    notificationUrl: `${webhookUrl()}?source_news=webhooks`,
    backBase: Deno.env.get('CRM_BASE_URL') ?? 'https://crm.suagraficabh.com.br',
    now,
    horas,
  })
  const res = await fetch(`${API}/checkout/preferences`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${cfg.token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(preference),
  })
  const pref = await res.json().catch(() => ({}))
  if (!res.ok || !pref.id) {
    console.error('Mercado Pago recusou a preferência', res.status, typeof pref?.message === 'string' ? pref.message : '')
    return json({ error: 'O Mercado Pago não aceitou a cobrança. Confira as credenciais e tente de novo.' }, 502)
  }
  const link: string | null = (cfg.modo === 'teste' ? pref.sandbox_init_point : null) ?? pref.init_point ?? null
  if (!link) return json({ error: 'O Mercado Pago não devolveu o link.' }, 502)

  const { data: novo, error: insErr } = await db.from('pagamentos').insert({
    order_id: orderId, eh_link: true, link_ativo: true, mp_preference_id: pref.id, link,
    valor: totalCents / 100, status: 'pendente', modo: cfg.modo, expira_em: preference.expiration_date_to,
  }).select('*').single()
  if (insErr) {
    // Outra chamada criou o link ao mesmo tempo: devolve o dela
    if (insErr.code === '23505') {
      const { data: outro } = await db.from('pagamentos').select('*').eq('order_id', orderId).eq('modo', cfg.modo).eq('eh_link', true).eq('link_ativo', true).maybeSingle()
      if (outro) return resposta(outro, true)
    }
    console.error('Falha ao gravar a cobrança', insErr.code)
    return json({ error: 'Não foi possível gravar a cobrança.' }, 500)
  }

  await db.from('eventos_pagamento').insert({
    chave: `link_criado:${novo.id}`, tipo: 'link_criado', order_id: orderId, pagamento_id: novo.id,
    payload: { pedido_id: orderId, pedido_numero: order.number, referencia: formatReference(order.number), valor: totalCents / 100, modo: cfg.modo, expira_em: preference.expiration_date_to, teste: order.teste },
  })
  await db.from('orders').update({ payment_link: link }).eq('id', orderId)

  return resposta(novo, false)
})
