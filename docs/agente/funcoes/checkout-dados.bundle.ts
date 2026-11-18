// GERADO por "node scripts/bundle-funcao.ts checkout-dados". NÃO edite aqui: edite supabase/functions/ e gere de novo.
// Painel do Supabase > Edge Functions > Deploy a new function (ou Code > Deploy updates) > Via Editor. Nome: checkout-dados. "Verify JWT" desligado (a função confere o dono ou a service role).
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

// Checkout próprio (/pagar/<token>): carrega o resumo público do pedido, salva os dados do cliente no CRM,
// muda a arte, adiciona ou remove sugestões e informa o status do pagamento. Público (o token é o comprovante),
// sem nenhum dado interno na resposta. Logs sem dados pessoais.
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)
  let b: Record<string, any>
  try {
    b = await req.json()
  } catch {
    return json({ error: 'Corpo da requisição inválido.' }, 400)
  }
  const token = String(b.token ?? '')
  if (!TOKEN_CHECKOUT.test(token)) return json({ ok: false, erro: 'link_invalido' }, 404)
  const db = serviceClient()

  const rpc = async (fn: string, args: Record<string, unknown>) => {
    const { data, error } = await db.rpc(fn, args)
    if (error) {
      console.error('checkout-dados: falha no banco', fn, error.code)
      return json({ ok: false, erro: 'indisponivel', mensagem: 'Não conseguimos carregar agora. Tente de novo em instantes.' }, 503)
    }
    const r = data as Record<string, any>
    return json(r, r?.ok === false ? (r.erro === 'link_invalido' ? 404 : 409) : 200)
  }

  switch (b.acao) {
    case 'carregar': {
      const { data, error } = await db.rpc('checkout_carregar', { p_token: token })
      if (error) {
        console.error('checkout-dados: carregar falhou', error.code)
        return json({ ok: false, erro: 'indisponivel', mensagem: 'Não conseguimos carregar o pedido agora. Tente de novo em instantes.' }, 503)
      }
      const r = data as Record<string, any>
      if (r?.ok === false) return json(r, 404)
      // A chave PÚBLICA do Mercado Pago é feita para ir ao navegador; a de acesso nunca sai daqui
      const cfg = mpConfig()
      const chave = cfg.modo ? Deno.env.get(`MP_PUBLIC_KEY_${cfg.modo === 'teste' ? 'TESTE' : 'PRODUCAO'}`) ?? null : null
      return json({ ...r, mp: { chave_publica: chave, modo: cfg.modo } })
    }
    case 'status':
      return rpc('checkout_status', { p_token: token })
    case 'salvar': {
      if (String(b.nome ?? '').trim().length < 3) return json({ ok: false, erro: 'nome_invalido', mensagem: 'Informe seu nome completo.' }, 400)
      if (!emailValido(b.email)) return json({ ok: false, erro: 'email_invalido', mensagem: 'Confira o e-mail.' }, 400)
      if (!documentoValido(b.documento)) return json({ ok: false, erro: 'documento_invalido', mensagem: 'CPF ou CNPJ inválido. Confira os números.' }, 400)
      return rpc('checkout_salvar_dados', { p_token: token, p_nome: String(b.nome), p_email: String(b.email), p_documento: String(b.documento) })
    }
    case 'arte':
      return rpc('checkout_definir_arte', { p_token: token, p_arte: String(b.arte ?? '') })
    case 'adicionar':
      return rpc('checkout_adicionar_produto', { p_token: token, p_ref: String(b.ref ?? '').slice(0, 40) })
    case 'remover':
      if (!UUID.test(String(b.item ?? ''))) return json({ ok: false, erro: 'item_invalido' }, 400)
      return rpc('checkout_remover_item', { p_token: token, p_item: String(b.item) })
    default:
      return json({ error: 'Ação inválida.' }, 400)
  }
})
