// GERADO por "node scripts/bundle-funcao.ts checkout-mp-processar". NÃO edite aqui: edite supabase/functions/ e gere de novo.
// Painel do Supabase > Edge Functions > Deploy a new function (ou Code > Deploy updates) > Via Editor. Nome: checkout-mp-processar. "Verify JWT" desligado (a função confere o dono ou a service role).
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2'
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

/** Parcelas sem juros (a taxa é absorvida e já está no preço). Configurado na conta do Mercado Pago (Seu negócio > Parcelamento sem juros). */
const MAX_PARCELAS_SEM_JUROS = 2
/** Máximo de parcelas que o link mostra (app_settings.parcelamento.maximo_link). Acima de 2x os juros são do cliente e aparecem no link. */
const MAX_PARCELAS = 12

function buildPreference(opts: {
  items: ItemPreferencia[]
  reference: string
  notificationUrl: string
  backBase: string
  now: Date
  horas: number
  maxParcelas?: number
  /** Resumo curto da política (produto personalizado, refação, cancelamento). Vai na descrição do link. */
  politica?: string | null
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
    // Pix e cartão. Boleto e lotérica ficam de fora. Até 2x sem juros (a conta absorve); acima disso o cliente vê as parcelas e os
    // juros no próprio link e escolhe lá. O "sem juros" é configurado na conta (Seu negócio > Parcelamento sem juros).
    payment_methods: { excluded_payment_types: [{ id: 'ticket' }, { id: 'atm' }], installments: Math.min(Math.max(Math.trunc(opts.maxParcelas ?? MAX_PARCELAS), 1), 12) },
    ...(opts.politica ? { additional_info: opts.politica.slice(0, 600) } : {}),
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

// E-commerce Fase 9: Pix direto (copia e cola) pela API de pagamentos do Mercado Pago. Funções puras (testadas em Node).

interface PagadorPix { email: string; nome: string; documento: string | null }

function corpoPix(o: { valor: number; referencia: string; descricao: string; notificationUrl: string; pagador: PagadorPix; expiraEm: Date }) {
  const partes = o.pagador.nome.trim().split(/\s+/)
  const doc = (o.pagador.documento ?? '').replace(/\D/g, '')
  return {
    transaction_amount: Math.round(o.valor * 100) / 100,
    description: o.descricao.slice(0, 200),
    payment_method_id: 'pix',
    external_reference: o.referencia,
    notification_url: o.notificationUrl,
    // o Mercado Pago pede o fuso explícito
    date_of_expiration: o.expiraEm.toISOString().replace('Z', '+00:00'),
    payer: {
      email: o.pagador.email,
      first_name: partes[0],
      last_name: partes.slice(1).join(' ') || partes[0],
      ...(doc.length === 11 || doc.length === 14 ? { identification: { type: doc.length === 11 ? 'CPF' : 'CNPJ', number: doc } } : {}),
    },
  }
}

interface PixPronto { pagamento_id: string; copia_e_cola: string; qr_base64: string | null; expira_em: string | null }

/** Lê a resposta do Mercado Pago. Null se o Pix não veio (sem código copia e cola não há o que mostrar). */
function lerPix(p: Record<string, any> | null): PixPronto | null {
  const t = p?.point_of_interaction?.transaction_data
  if (!p?.id || typeof t?.qr_code !== 'string' || !t.qr_code) return null
  return { pagamento_id: String(p.id), copia_e_cola: t.qr_code, qr_base64: typeof t.qr_code_base64 === 'string' ? t.qr_code_base64 : null, expira_em: p.date_of_expiration ?? null }
}

// Checkout próprio (/pagar/<token>): regras puras. Sem APIs de Deno, para rodar também nos testes em Node.
const CHECKOUT_BASE_PADRAO = 'https://suagraficabh.com.br'
const TOKEN_CHECKOUT = /^[0-9a-f]{32}$/

const urlCheckout = (token: string, base: string = CHECKOUT_BASE_PADRAO): string => `${base.replace(/\/+$/, '')}/pagar/${token}`

/** CPF ou CNPJ com dígitos verificadores corretos (só números ou com pontuação). */
function documentoValido(valor: string | null | undefined): boolean {
  const d = String(valor ?? '').replace(/\D/g, '')
  if (/^(\d)\1+$/.test(d)) return false
  if (d.length === 11) {
    const dv = (n: number) => {
      let s = 0
      for (let i = 0; i < n; i++) s += Number(d[i]) * (n + 1 - i)
      const r = (s * 10) % 11
      return r === 10 ? 0 : r
    }
    return dv(9) === Number(d[9]) && dv(10) === Number(d[10])
  }
  if (d.length === 14) {
    const dv = (n: number) => {
      const pesos = n === 12 ? [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2] : [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]
      const s = pesos.reduce((acc, p, i) => acc + p * Number(d[i]), 0)
      const r = s % 11
      return r < 2 ? 0 : 11 - r
    }
    return dv(12) === Number(d[12]) && dv(13) === Number(d[13])
  }
  return false
}

const emailValido = (v: string | null | undefined): boolean => /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(String(v ?? '').trim()) && String(v).length <= 160

interface FormBrick {
  token?: unknown
  issuer_id?: unknown
  payment_method_id?: unknown
  installments?: unknown
}

type Entrada =
  | { ok: true; tipo: 'pix' }
  | { ok: true; tipo: 'cartao'; cardToken: string; metodo: string; issuer: string | null; parcelas: number }
  | { ok: false; mensagem: string }

/**
 * Lê só o que importa do payload do Payment Brick. O valor, a referência e o pagador NUNCA vêm daqui.
 * Parcelas acima do limite sem juros são recusadas (nunca arredondadas em silêncio).
 */
function lerEntrada(form: FormBrick | null | undefined, maxParcelas: number): Entrada {
  const metodo = String(form?.payment_method_id ?? '')
  if (metodo === 'pix') return { ok: true, tipo: 'pix' }
  const cardToken = typeof form?.token === 'string' ? form.token : ''
  if (!cardToken || !/^[A-Za-z0-9_-]{8,128}$/.test(cardToken)) return { ok: false, mensagem: 'Não conseguimos ler os dados do cartão. Confira e tente de novo.' }
  if (!/^[a-z0-9_]{2,30}$/.test(metodo)) return { ok: false, mensagem: 'Forma de pagamento inválida.' }
  const parcelas = Number(form?.installments ?? 1)
  if (!Number.isInteger(parcelas) || parcelas < 1) return { ok: false, mensagem: 'Número de parcelas inválido.' }
  if (parcelas > maxParcelas) return { ok: false, mensagem: `Parcelamos em até ${maxParcelas}x sem juros.` }
  const issuer = form?.issuer_id != null && /^\d{1,10}$/.test(String(form.issuer_id)) ? String(form.issuer_id) : null
  return { ok: true, tipo: 'cartao', cardToken, metodo, issuer, parcelas }
}

interface Pagador { email: string; nome: string; documento: string }

function pagadorMp(p: Pagador) {
  const partes = p.nome.trim().split(/\s+/)
  const doc = p.documento.replace(/\D/g, '')
  return {
    email: p.email.trim().toLowerCase(),
    first_name: partes[0],
    last_name: partes.slice(1).join(' ') || partes[0],
    identification: { type: doc.length === 14 ? 'CNPJ' : 'CPF', number: doc },
  }
}

interface DadosCobranca {
  valorCents: number
  referencia: string
  notificationUrl: string
  pagador: Pagador
  itens: { description: string; qty: number; unit_price: number }[]
  entrada: Extract<Entrada, { ok: true }>
  expiraPix?: Date
}

/** Corpo de POST /v1/payments. Valor e referência vêm do banco; itens ajudam o antifraude (taxa de aprovação). */
function corpoPagamento(d: DadosCobranca): Record<string, unknown> {
  const pag = pagadorMp(d.pagador)
  const base: Record<string, unknown> = {
    transaction_amount: d.valorCents / 100,
    description: `Pedido ${d.referencia} - Sua Gráfica BH`,
    external_reference: d.referencia,
    notification_url: d.notificationUrl,
    statement_descriptor: 'SUAGRAFICABH',
    payer: { email: pag.email, first_name: pag.first_name, last_name: pag.last_name, identification: pag.identification },
    additional_info: {
      items: buildItems(d.itens, d.valorCents).map((i) => ({ id: i.id, title: i.title, description: i.description, category_id: i.category_id, quantity: i.quantity, unit_price: i.unit_price })),
      payer: { first_name: pag.first_name, last_name: pag.last_name },
    },
  }
  if (d.entrada.tipo === 'pix') {
    return { ...base, payment_method_id: 'pix', ...(d.expiraPix ? { date_of_expiration: d.expiraPix.toISOString().replace('Z', '+00:00') } : {}) }
  }
  return {
    ...base,
    token: d.entrada.cardToken,
    installments: d.entrada.parcelas,
    payment_method_id: d.entrada.metodo,
    ...(d.entrada.issuer ? { issuer_id: Number(d.entrada.issuer) } : {}),
  }
}

/** Texto amigável para o cliente quando o cartão é recusado. */
function mensagemRecusa(statusDetail: string | null | undefined): string {
  switch (statusDetail) {
    case 'cc_rejected_insufficient_amount': return 'Saldo ou limite insuficiente neste cartão. Tente outro cartão ou pague no Pix.'
    case 'cc_rejected_bad_filled_card_number':
    case 'cc_rejected_bad_filled_date':
    case 'cc_rejected_bad_filled_security_code':
    case 'cc_rejected_bad_filled_other': return 'Confira os dados do cartão (número, validade e código de segurança) e tente de novo.'
    case 'cc_rejected_call_for_authorize': return 'O banco precisa autorizar este pagamento. Fale com o banco, use outro cartão ou pague no Pix.'
    case 'cc_rejected_card_disabled': return 'Este cartão está desabilitado. Ative-o no banco, use outro cartão ou pague no Pix.'
    case 'cc_rejected_high_risk': return 'Por segurança, este cartão não foi aprovado. Pague no Pix ou tente outro cartão.'
    case 'cc_rejected_duplicated_payment': return 'Já recebemos uma tentativa igual a esta. Confira se não houve cobrança ou use outro cartão.'
    case 'cc_rejected_max_attempts': return 'Muitas tentativas com este cartão. Use outro cartão ou pague no Pix.'
    case 'cc_rejected_invalid_installments': return 'Este cartão não aceita esse parcelamento. Tente à vista ou outro cartão.'
    default: return 'O cartão foi recusado. Tente outro cartão ou pague no Pix, que aprova na hora.'
  }
}

type DesfechoCartao = { status: 'approved' | 'in_process' | 'rejected'; mensagem: string }

function desfechoCartao(p: Record<string, any>): DesfechoCartao {
  if (p.status === 'approved') return { status: 'approved', mensagem: 'Pagamento aprovado!' }
  if (p.status === 'in_process' || p.status === 'pending' || p.status === 'authorized') {
    return { status: 'in_process', mensagem: 'Estamos analisando o pagamento. Assim que confirmar, avisamos no seu WhatsApp.' }
  }
  return { status: 'rejected', mensagem: mensagemRecusa(p.status_detail) }
}

/** Cliente pagou parcelado com juros (a conta do Mercado Pago não está com 2x sem juros): total pago maior que o valor do pedido. */
function pagouComJuros(p: Record<string, any>): { juros: number } | null {
  const total = Number(p.transaction_details?.total_paid_amount)
  const valor = Number(p.transaction_amount)
  if (!Number.isFinite(total) || !Number.isFinite(valor)) return null
  const juros = Math.round((total - valor) * 100) / 100
  return juros > 0.01 ? { juros } : null
}


// Checkout próprio: cobra Pix ou cartão (até 2x sem juros) pela API de pagamentos do Mercado Pago, sem redirecionar o cliente.
// O VALOR e a REFERÊNCIA vêm sempre do banco (nunca do navegador). O resultado entra pelo mesmo caminho do webhook
// (mp_registrar_pagamento), então o pedido vira Pago e a mensagem de confirmação no WhatsApp sai como sempre.
// Problema técnico, recusa repetida ou juros fora do combinado viram alerta ao dono (popup no app + WhatsApp). Logs sem dados pessoais.
type Pedido = { id: string; number: number; teste: boolean; payment_status: string; cancelado_em: string | null; excluido_em: string | null; contact_id: string; conversation_id: string | null; contacts: { name: string | null; email: string | null; document: string | null } | null }

const erro = (status: number, mensagem: string, extra: Record<string, unknown> = {}) => json({ ok: false, mensagem, ...extra }, status)

/** Aviso ao dono (popup no app e WhatsApp). Chave estável evita repetir o mesmo aviso. */
async function alertar(db: SupabaseClient, o: Pedido, motivo: string, chave: string, dados: Record<string, unknown> = {}) {
  const { error } = await db.rpc('alerta_criar', {
    p_tipo: 'pagamento_problema', p_gravidade: 'alta', p_contact: o.contact_id, p_conversation: o.conversation_id, p_order: o.id,
    p_motivo: motivo, p_dados: { pedido: formatReference(o.number), origem: 'checkout_proprio', ...dados }, p_chave: chave,
  })
  if (error) console.error('checkout-mp-processar: alerta não criado', error.code)
}

const evento = (db: SupabaseClient, token: string, tipo: string, detalhe: Record<string, unknown> = {}) =>
  db.rpc('checkout_registrar_evento', { p_token: token, p_tipo: tipo, p_detalhe: detalhe }).then(() => null, () => null)

/** Cancela Pix ainda pendente do pedido depois que o cartão foi aprovado, para ninguém pagar duas vezes. */
async function cancelarPixPendentes(db: SupabaseClient, orderId: string, token: string, modo: string) {
  const { data } = await db.from('pagamentos').select('mp_payment_id').eq('order_id', orderId).eq('modo', modo).eq('metodo', 'pix').eq('status', 'pendente').not('mp_payment_id', 'is', null)
  for (const x of data ?? []) {
    await fetch(`${API}/v1/payments/${x.mp_payment_id}`, { method: 'PUT', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ status: 'cancelled' }) }).catch(() => null)
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)
  let b: Record<string, any>
  try {
    b = await req.json()
  } catch {
    return erro(400, 'Corpo da requisição inválido.')
  }
  const token = String(b.token ?? '')
  if (!TOKEN_CHECKOUT.test(token)) return erro(404, 'Link inválido.')
  const db = serviceClient()

  const { data: pedido } = await db.from('orders')
    .select('id, number, teste, payment_status, cancelado_em, excluido_em, contact_id, conversation_id, contacts(name, email, document)')
    .eq('checkout_token', token).maybeSingle()
  const o = pedido as unknown as Pedido | null
  if (!o) return erro(404, 'Link inválido.')
  if (o.payment_status === 'aprovado') return erro(409, 'Este pedido já foi pago.', { pago: true })
  if (o.cancelado_em || o.excluido_em) return erro(409, 'Este pedido foi cancelado. Fale com a gente no WhatsApp.')

  const { data: link } = await db.from('pagamentos').select('expira_em').eq('order_id', o.id).eq('eh_link', true).eq('link_ativo', true).order('criado_em', { ascending: false }).limit(1).maybeSingle()
  if (!link?.expira_em || new Date(link.expira_em).getTime() <= Date.now()) return erro(410, 'Este link de pagamento venceu. Peça um novo no WhatsApp.', { expirado: true })

  const cfg = mpConfig()
  if (!cfg.modo || !cfg.token) {
    console.error('checkout-mp-processar: Mercado Pago sem configuração', cfg.faltando.join(','))
    await alertar(db, o, `Checkout fora do ar no pedido ${formatReference(o.number)}: o Mercado Pago não está configurado no servidor (${cfg.faltando.join(', ')}).`, `chk_config:${new Date().toISOString().slice(0, 13)}`)
    return erro(503, 'O pagamento está em manutenção. Fale com a gente no WhatsApp que resolvemos agora.')
  }
  if (cfg.modo === 'producao' && o.teste) return erro(422, 'Pedido de teste.')

  // Dados do pagador: se vieram na tela, salva no CRM antes de cobrar; depois confere o que está no cadastro
  if (b.dados) {
    const d = b.dados as Record<string, unknown>
    if (!documentoValido(String(d.documento ?? '')) || !emailValido(String(d.email ?? '')) || String(d.nome ?? '').trim().length < 3) return erro(400, 'Confira nome, e-mail e CPF/CNPJ.')
    const { data: s, error: se } = await db.rpc('checkout_salvar_dados', { p_token: token, p_nome: String(d.nome), p_email: String(d.email), p_documento: String(d.documento) })
    if (se || !(s as Record<string, any>)?.ok) return erro(409, 'Não foi possível salvar seus dados. Confira e tente de novo.')
    const { data: c } = await db.from('contacts').select('name, email, document').eq('id', o.contact_id).maybeSingle()
    o.contacts = c
  }
  const c = o.contacts
  if (!c || String(c.name ?? '').trim().length < 3 || !emailValido(c.email) || !documentoValido(c.document)) return erro(422, 'Faltam seus dados (nome, e-mail e CPF/CNPJ) para liberar o pagamento.', { faltam_dados: true })

  const { data: recusa, error: valErr } = await db.rpc('validar_antes_de_cobrar', { p_order: o.id })
  if (valErr) return erro(500, 'Não foi possível validar o pedido. Tente de novo.')
  if (recusa) return erro(422, String(recusa))

  const [{ data: fin }, { data: itens }, { data: pc }] = await Promise.all([
    db.from('order_financials').select('total').eq('order_id', o.id).maybeSingle(),
    db.from('order_items').select('description, qty, unit_price').eq('order_id', o.id).order('created_at'),
    db.from('parametros_comerciais').select('parcelas_sem_juros_max').eq('id', 1).maybeSingle(),
  ])
  const valorCents = toCents(Number(fin?.total ?? 0))
  if (valorCents <= 0 || !itens?.length) return erro(422, 'O pedido precisa ter itens e valor maior que zero.')
  const maxParcelas = Math.min(Math.max(Number(pc?.parcelas_sem_juros_max ?? 2), 1), 2)

  const entrada = lerEntrada(b.form, maxParcelas)
  if (!entrada.ok) return erro(400, entrada.mensagem)
  const referencia = formatReference(o.number)
  const pagador = { email: String(c.email), nome: String(c.name), documento: String(c.document) }

  // Pix já gerado e ainda válido para o mesmo valor: devolve o mesmo QR Code
  if (entrada.tipo === 'pix') {
    const { data: antigos } = await db.from('pagamentos').select('mp_payment_id, valor').eq('order_id', o.id).eq('modo', cfg.modo).eq('metodo', 'pix').eq('status', 'pendente')
      .not('mp_payment_id', 'is', null).gt('criado_em', new Date(Date.now() - 23 * 3600_000).toISOString()).order('criado_em', { ascending: false }).limit(1)
    const antigo = antigos?.[0]
    if (antigo && toCents(Number(antigo.valor)) === valorCents) {
      const { status, data: p } = await mpGet(`/v1/payments/${antigo.mp_payment_id}`, cfg.token)
      const pix = status === 200 && p.status === 'pending' ? lerPix(p) : null
      if (pix) return json({ ok: true, status: 'pendente', metodo: 'pix', pix, reutilizado: true })
    }
  }

  const corpo = corpoPagamento({
    valorCents, referencia, notificationUrl: `${webhookUrl()}?source_news=webhooks`, pagador, entrada,
    itens: itens.map((i) => ({ description: i.description, qty: i.qty, unit_price: Number(i.unit_price) })),
    expiraPix: new Date(Date.now() + 24 * 3600_000),
  })
  const chaveIdem = entrada.tipo === 'pix' ? `chk-pix-${o.id}-${valorCents}-${Math.floor(Date.now() / 60_000)}` : `chk-${o.id}-${valorCents}-${entrada.cardToken}`
  const device = typeof b.device_id === 'string' && /^[\w-]{8,120}$/.test(b.device_id) ? b.device_id : null

  let res: Response
  try {
    res = await fetch(`${API}/v1/payments`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${cfg.token}`, 'Content-Type': 'application/json', 'X-Idempotency-Key': chaveIdem, ...(device ? { 'X-meli-session-id': device } : {}) },
      body: JSON.stringify(corpo),
      signal: AbortSignal.timeout(28_000),
    })
  } catch (e) {
    console.error('checkout-mp-processar: sem resposta do Mercado Pago', (e as Error).name)
    await evento(db, token, 'erro_tecnico', { motivo: 'sem_resposta' })
    await alertar(db, o, `Cliente do pedido ${referencia} não conseguiu pagar: o Mercado Pago não respondeu a tempo. Confira se houve cobrança e fale com ele.`, `chk_erro:${o.id}:${Math.floor(Date.now() / 600_000)}`, { motivo: 'sem_resposta' })
    return erro(502, 'Não conseguimos confirmar o pagamento agora. Se houver cobrança, o pedido será confirmado sozinho. Se preferir, fale com a gente no WhatsApp.')
  }
  const p = await res.json().catch(() => ({})) as Record<string, any>

  if (!res.ok || !p.id) {
    const causa = Array.isArray(p.cause) ? String(p.cause[0]?.code ?? '') : ''
    console.error('checkout-mp-processar: Mercado Pago recusou a requisição', res.status, causa, typeof p.message === 'string' ? p.message : '')
    await evento(db, token, 'erro_tecnico', { status: res.status, causa })
    // 3xxx = dado do cartão ou do pagador que o cliente pode corrigir; o resto é problema nosso e o dono é avisado
    const corrigivel = res.status === 400 && /^(3|2067|2062|4)/.test(causa)
    if (!corrigivel) await alertar(db, o, `Cliente do pedido ${referencia} não conseguiu pagar: erro técnico no Mercado Pago (${res.status}${causa ? ' ' + causa : ''}). Fale com ele e confira as credenciais.`, `chk_erro:${o.id}:${Math.floor(Date.now() / 600_000)}`, { status: res.status, causa })
    return erro(res.status >= 500 ? 502 : 422, corrigivel ? 'Confira os dados do cartão e do pagador e tente de novo.' : 'Não conseguimos processar o pagamento agora. Tente o Pix ou fale com a gente no WhatsApp.')
  }

  // Mesmo caminho do webhook: confirma o pedido, grava taxa real e dispara a mensagem de confirmação
  const reg = await registrarObjeto(db, p, cfg.modo)
  if (reg.status !== 200) console.error('checkout-mp-processar: pagamento criado mas não gravado', reg.status)

  if (entrada.tipo === 'pix') {
    const pix = lerPix(p)
    await evento(db, token, 'pix_gerado', { mp: String(p.id) })
    if (!pix) {
      await alertar(db, o, `Pix do pedido ${referencia} foi criado no Mercado Pago, mas não veio o código copia e cola. Fale com o cliente.`, `chk_pix:${o.id}:${p.id}`)
      return erro(502, 'Não conseguimos gerar o Pix agora. Tente de novo ou pague no cartão.')
    }
    return json({ ok: true, status: 'pendente', metodo: 'pix', pix })
  }

  const r = desfechoCartao(p)
  await evento(db, token, r.status === 'approved' ? 'cartao_aprovado' : r.status === 'in_process' ? 'cartao_em_analise' : 'cartao_recusado', { mp: String(p.id), detalhe: p.status_detail ?? null, parcelas: entrada.parcelas })
  if (r.status === 'approved') {
    await cancelarPixPendentes(db, o.id, cfg.token, cfg.modo)
    const juros = pagouComJuros(p)
    if (juros) await alertar(db, o, `Pedido ${referencia} pago em ${entrada.parcelas}x COM JUROS para o cliente (R$ ${juros.juros.toFixed(2).replace('.', ',')} a mais). Ative o parcelamento sem juros na conta do Mercado Pago.`, `chk_juros:${p.id}`, { juros: juros.juros })
  } else if (r.status === 'rejected') {
    const { count } = await db.from('checkout_eventos').select('id', { count: 'exact', head: true }).eq('order_id', o.id).eq('tipo', 'cartao_recusado').gt('criado_em', new Date(Date.now() - 30 * 60_000).toISOString())
    if ((count ?? 0) >= 2) await alertar(db, o, `Cliente do pedido ${referencia} teve ${count} recusas de cartão em 30 minutos. Chame no WhatsApp e ofereça o Pix.`, `chk_dificuldade:${o.id}:${Math.floor(Date.now() / 1_800_000)}`, { recusas: count })
  }
  return json({ ok: true, status: r.status, metodo: 'cartao', mensagem: r.mensagem, parcelas: entrada.parcelas, status_detalhe: r.status === 'rejected' ? p.status_detail ?? null : null })
})
