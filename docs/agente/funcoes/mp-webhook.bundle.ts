// GERADO por "node scripts/bundle-funcao.ts mp-webhook". NÃO edite aqui: edite supabase/functions/ e gere de novo.
// Painel do Supabase > Edge Functions > Deploy a new function (ou Code > Deploy updates) > Via Editor. Nome: mp-webhook. "Verify JWT" desligado (a função confere o dono ou a service role).
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2'
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2'
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

/** Máximo de parcelas permitido no link (parametros_comerciais.parcelas_sem_juros_max). */
const MAX_PARCELAS = 2

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
    // Pix e cartão. Boleto e lotérica ficam de fora. No máximo 2 parcelas (as sem juros que a conta absorve);
    // acima disso só por decisão do dono. O "sem juros" em si é configurado na conta (Seu negócio > Parcelamento sem juros).
    payment_methods: { excluded_payment_types: [{ id: 'ticket' }, { id: 'atm' }], installments: MAX_PARCELAS },
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

type Resultado = { status: number; body: Record<string, unknown> }

async function mpGet(path: string, token: string): Promise<{ status: number; data: Record<string, any> }> {
  const res = await fetch(`${API}${path}`, { headers: { Authorization: `Bearer ${token}` } })
  return { status: res.status, data: await res.json().catch(() => ({})) }
}

function metodoDe(p: Record<string, any>): string | null {
  if (p.payment_method_id === 'pix') return 'pix'
  if (p.payment_type_id === 'credit_card') return 'cartao_credito'
  if (p.payment_type_id === 'debit_card') return 'cartao_debito'
  return p.payment_method_id ?? null
}

/** Taxa REAL cobrada pelo Mercado Pago (soma de fee_details) e valor líquido recebido. Null se a API não informou. */
function taxaRealDe(p: Record<string, any>): { taxa: number; liquido: number | null; parcelas: number | null } | null {
  const det = Array.isArray(p.fee_details) ? p.fee_details : []
  const taxas = det.map((d: any) => Number(d?.amount)).filter((n: number) => Number.isFinite(n) && n >= 0)
  if (!taxas.length) return null
  const liquido = Number(p.transaction_details?.net_received_amount)
  const parcelas = Number(p.installments)
  return {
    taxa: Math.round(taxas.reduce((a: number, b: number) => a + b, 0) * 100) / 100,
    liquido: Number.isFinite(liquido) ? liquido : null,
    parcelas: Number.isInteger(parcelas) && parcelas >= 1 && parcelas <= 12 ? parcelas : null,
  }
}

/** Grava um pagamento já lido da API do Mercado Pago (webhook e "Conferir agora" usam este mesmo caminho). */
async function registrarObjeto(db: SupabaseClient, p: Record<string, any>, modo: MpModo): Promise<Resultado> {
  const { data, error } = await db.rpc('mp_registrar_pagamento', {
    p_mp_payment_id: String(p.id),
    p_mp_status: String(p.status ?? ''),
    p_status_detail: p.status_detail ?? null,
    p_referencia: p.external_reference ?? '',
    p_valor: typeof p.transaction_amount === 'number' ? p.transaction_amount : null,
    p_moeda: p.currency_id ?? null,
    p_metodo: metodoDe(p),
    p_live: p.live_mode === true,
    p_modo: modo,
    p_aprovado_em: p.date_approved ?? null,
  })
  if (error) {
    console.error('Falha ao registrar pagamento', error.code)
    return { status: 500, body: { error: 'Falha ao registrar o pagamento.' } }
  }
  // Pagamento aprovado: grava a taxa real (fee_details) e o líquido no pedido e no lucro. Falha aqui não desfaz o pagamento.
  const real = p.status === 'approved' ? taxaRealDe(p) : null
  if (real) {
    const { error: e2 } = await db.rpc('pagamento_taxa_real', { p_mp_payment_id: String(p.id), p_taxa: real.taxa, p_liquido: real.liquido, p_parcelas: real.parcelas })
    if (e2) console.error('Falha ao gravar a taxa real do pagamento', e2.code)
  }
  return { status: 200, body: { ok: true, ...(data as Record<string, unknown>) } }
}

const ID = /^\d{1,20}$/

/** Nunca confia no corpo do aviso: consulta o pagamento no Mercado Pago e só então grava. */
async function processarPagamento(db: SupabaseClient, id: string, token: string, modo: MpModo): Promise<Resultado> {
  if (!ID.test(id)) return { status: 200, body: { ignorado: 'id_invalido' } }
  const { status, data: p } = await mpGet(`/v1/payments/${id}`, token)
  if (status === 404) return { status: 200, body: { ignorado: 'pagamento_nao_encontrado' } } // ex.: simulação do painel
  if (status === 401 || status === 403) {
    console.error('Mercado Pago recusou o token ao consultar o pagamento', status)
    return { status: 500, body: { error: 'Credenciais do Mercado Pago inválidas.' } }
  }
  if (status !== 200) return { status: 502, body: { error: 'Mercado Pago indisponível, tente de novo.' } }
  return registrarObjeto(db, { ...p, id: p.id ?? id }, modo)
}

const ID_NUMERICO = /^\d{1,20}$/

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)

  const cfg = mpConfig()
  if (!cfg.modo || !cfg.token || !cfg.signatureSecret) {
    console.error('Mercado Pago não configurado. Faltam:', cfg.faltando.join(', '))
    return json({ error: 'Integração não configurada.' }, 500)
  }

  const url = new URL(req.url)
  const raw = await req.text()
  let body: Record<string, any> = {}
  try {
    body = raw ? JSON.parse(raw) : {}
  } catch {
    /* corpo inválido: a assinatura decide */
  }
  const dataId = url.searchParams.get('data.id') ?? (body?.data?.id != null ? String(body.data.id) : null)

  const sig = await verifyMpSignature({
    secret: cfg.signatureSecret,
    signatureHeader: req.headers.get('x-signature'),
    requestId: req.headers.get('x-request-id'),
    dataId,
  })
  if (!sig.ok) {
    console.error('Aviso rejeitado:', sig.reason)
    return json({ error: 'Assinatura inválida.' }, 401)
  }
  if (!dataId) return json({ ok: true, ignorado: 'sem_id' })

  const db = serviceClient()
  const tipo = String(body.type ?? url.searchParams.get('type') ?? url.searchParams.get('topic') ?? '')

  let r: Resultado
  if (tipo === 'payment') {
    r = await processarPagamento(db, dataId, cfg.token, cfg.modo)
  } else if (tipo === 'topic_chargebacks_wh' || tipo === 'chargebacks') {
    // Contestação: descobre os pagamentos envolvidos e processa cada um (o status vira charged_back)
    const cb = ID_NUMERICO.test(dataId) ? await mpGet(`/v1/chargebacks/${dataId}`, cfg.token) : { status: 404, data: {} as Record<string, any> }
    const ids: string[] = (Array.isArray(cb.data.payments) ? cb.data.payments : []).map(String).filter((x: string) => ID_NUMERICO.test(x))
    r = { status: 200, body: { ok: true, ignorado: ids.length ? undefined : 'contestacao_sem_pagamento' } }
    for (const pid of ids) {
      await db.rpc('mp_registrar_alerta', { p_tipo: 'contestacao', p_mp_payment_id: pid, p_chave: `chargeback:${dataId}`, p_mensagem: 'Contestação aberta em um pagamento. Responda no painel do Mercado Pago. O pedido não foi alterado.', p_detalhes: { chargeback_id: dataId } })
      r = await processarPagamento(db, pid, cfg.token, cfg.modo)
      if (r.status !== 200) break
    }
  } else if (tipo === 'topic_claims_integration_wh' || tipo === 'claims') {
    const cl = ID_NUMERICO.test(dataId) ? await mpGet(`/post-purchase/v1/claims/${dataId}`, cfg.token) : { status: 404, data: {} as Record<string, any> }
    const pid = cl.data.resource === 'payment' && ID_NUMERICO.test(String(cl.data.resource_id ?? '')) ? String(cl.data.resource_id) : null
    if (pid) {
      await db.rpc('mp_registrar_alerta', { p_tipo: 'reclamacao', p_mp_payment_id: pid, p_chave: `claim:${dataId}:${cl.data.status ?? ''}`, p_mensagem: 'Reclamação do comprador em um pagamento. Responda no painel do Mercado Pago. O pedido não foi alterado.', p_detalhes: { claim_id: dataId, etapa: cl.data.stage ?? null } })
      r = { status: 200, body: { ok: true, alerta: 'reclamacao' } }
    } else {
      r = { status: 200, body: { ok: true, ignorado: 'reclamacao_sem_pagamento' } }
    }
  } else {
    r = { status: 200, body: { ok: true, ignorado: 'tipo_nao_tratado' } }
  }
  return json(r.body, r.status)
})
