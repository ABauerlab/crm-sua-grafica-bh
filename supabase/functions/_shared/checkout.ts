// Checkout próprio (/pagar/<token>): regras puras. Sem APIs de Deno, para rodar também nos testes em Node.
import { buildItems } from './mp.ts'

export const CHECKOUT_BASE_PADRAO = 'https://suagraficabh.com.br'
export const TOKEN_CHECKOUT = /^[0-9a-f]{32}$/

export const urlCheckout = (token: string, base: string = CHECKOUT_BASE_PADRAO): string => `${base.replace(/\/+$/, '')}/pagar/${token}`

/** CPF ou CNPJ com dígitos verificadores corretos (só números ou com pontuação). */
export function documentoValido(valor: string | null | undefined): boolean {
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

export const emailValido = (v: string | null | undefined): boolean => /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(String(v ?? '').trim()) && String(v).length <= 160

export interface FormBrick {
  token?: unknown
  issuer_id?: unknown
  payment_method_id?: unknown
  installments?: unknown
}

export type Entrada =
  | { ok: true; tipo: 'pix' }
  | { ok: true; tipo: 'cartao'; cardToken: string; metodo: string; issuer: string | null; parcelas: number }
  | { ok: false; mensagem: string }

/**
 * Lê só o que importa do payload do Payment Brick. O valor, a referência e o pagador NUNCA vêm daqui.
 * Parcelas acima do limite sem juros são recusadas (nunca arredondadas em silêncio).
 */
export function lerEntrada(form: FormBrick | null | undefined, maxParcelas: number): Entrada {
  const metodo = String(form?.payment_method_id ?? '')
  if (metodo === 'pix') return { ok: true, tipo: 'pix' }
  const cardToken = typeof form?.token === 'string' ? form.token : ''
  if (!cardToken || !/^[A-Za-z0-9_-]{8,128}$/.test(cardToken)) return { ok: false, mensagem: 'Não conseguimos ler os dados do cartão. Confira e tente de novo.' }
  if (!/^[a-z0-9_]{2,30}$/.test(metodo)) return { ok: false, mensagem: 'Forma de pagamento inválida.' }
  const parcelas = Number(form?.installments ?? 1)
  if (!Number.isInteger(parcelas) || parcelas < 1) return { ok: false, mensagem: 'Número de parcelas inválido.' }
  if (parcelas > maxParcelas) return { ok: false, mensagem: `Parcelamos em até ${maxParcelas}x no cartão.` }
  const issuer = form?.issuer_id != null && /^\d{1,10}$/.test(String(form.issuer_id)) ? String(form.issuer_id) : null
  return { ok: true, tipo: 'cartao', cardToken, metodo, issuer, parcelas }
}

export interface Pagador { email: string; nome: string; documento: string }

export function pagadorMp(p: Pagador) {
  const partes = p.nome.trim().split(/\s+/)
  const doc = p.documento.replace(/\D/g, '')
  return {
    email: p.email.trim().toLowerCase(),
    first_name: partes[0],
    last_name: partes.slice(1).join(' ') || partes[0],
    identification: { type: doc.length === 14 ? 'CNPJ' : 'CPF', number: doc },
  }
}

export interface DadosCobranca {
  valorCents: number
  referencia: string
  notificationUrl: string
  pagador: Pagador
  itens: { description: string; qty: number; unit_price: number }[]
  entrada: Extract<Entrada, { ok: true }>
  expiraPix?: Date
}

/** Corpo de POST /v1/payments. Valor e referência vêm do banco; itens ajudam o antifraude (taxa de aprovação). */
export function corpoPagamento(d: DadosCobranca): Record<string, unknown> {
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
export function mensagemRecusa(statusDetail: string | null | undefined): string {
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

export type DesfechoCartao = { status: 'approved' | 'in_process' | 'rejected'; mensagem: string }

export function desfechoCartao(p: Record<string, any>): DesfechoCartao {
  if (p.status === 'approved') return { status: 'approved', mensagem: 'Pagamento aprovado!' }
  if (p.status === 'in_process' || p.status === 'pending' || p.status === 'authorized') {
    return { status: 'in_process', mensagem: 'Estamos analisando o pagamento. Assim que confirmar, avisamos no seu WhatsApp.' }
  }
  return { status: 'rejected', mensagem: mensagemRecusa(p.status_detail) }
}

/** Cliente pagou parcelado com juros (a conta do Mercado Pago não está com 2x sem juros): total pago maior que o valor do pedido. */
export function pagouComJuros(p: Record<string, any>): { juros: number } | null {
  const total = Number(p.transaction_details?.total_paid_amount)
  const valor = Number(p.transaction_amount)
  if (!Number.isFinite(total) || !Number.isFinite(valor)) return null
  const juros = Math.round((total - valor) * 100) / 100
  return juros > 0.01 ? { juros } : null
}

