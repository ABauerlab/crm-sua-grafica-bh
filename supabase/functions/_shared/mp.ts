// Regras puras da integração com o Mercado Pago. Sem APIs de Deno: roda também no Node para os testes.
import { hmacSha256Hex } from './signature.ts'

export type MpModo = 'teste' | 'producao'
export type PagamentoStatus = 'pendente' | 'em_analise' | 'aprovado' | 'recusado' | 'cancelado' | 'expirado' | 'estornado' | 'contestado'

/** Janela aceita entre o carimbo da assinatura e a hora do servidor (protege contra replay). */
export const JANELA_PADRAO_MS = 10 * 60 * 1000

export const API = 'https://api.mercadopago.com'

export function parseModo(v: string | undefined | null): MpModo | null {
  const m = (v ?? '').trim().toLowerCase()
  return m === 'teste' || m === 'producao' ? m : null
}

/** "SG-0001" para o pedido 1. */
export function formatReference(n: number): string {
  return `SG-${String(n).padStart(4, '0')}`
}

export function parseReference(ref: string | null | undefined): number | null {
  const m = /^SG-(\d{1,12})$/.exec((ref ?? '').trim())
  return m ? Number(m[1]) : null
}

export const toCents = (v: number): number => Math.round(v * 100)

export function parseSignatureHeader(header: string | null): { ts: string; v1: string } | null {
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
export function buildManifest(dataId: string | null, requestId: string | null, ts: string): string {
  let m = ''
  if (dataId) m += `id:${/^[a-z0-9]+$/i.test(dataId) ? dataId.toLowerCase() : dataId};`
  if (requestId) m += `request-id:${requestId};`
  m += `ts:${ts};`
  return m
}

/** O carimbo vem em milissegundos; aceita também segundos. */
export function tsToMs(ts: string): number | null {
  const n = Number(ts)
  if (!Number.isFinite(n) || n <= 0) return null
  return n < 1e11 ? n * 1000 : n
}

export type SignatureResult = { ok: true } | { ok: false; reason: 'ausente' | 'formato' | 'antiga' | 'invalida' }

export async function verifyMpSignature(opts: {
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
export function mapStatus(status: string, detail?: string | null): PagamentoStatus {
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

export interface LinhaPedido {
  description: string
  qty: number
  unit_price: number
}

export interface ItemPreferencia {
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
export function buildItems(lines: LinhaPedido[], totalCents: number): ItemPreferencia[] {
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
export function parseExpiraHoras(v: unknown): number {
  if (v === undefined || v === null || v === '') return 48
  const n = Number(v)
  if (!Number.isFinite(n) || n < 0.1 || n > 168) throw new Error('expira_horas deve ficar entre 0,1 e 168.')
  return n
}

export function buildPreference(opts: {
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
