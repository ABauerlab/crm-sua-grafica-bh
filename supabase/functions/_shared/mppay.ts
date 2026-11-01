import type { SupabaseClient } from 'npm:@supabase/supabase-js@2'
import { API, type MpModo } from './mp.ts'

export type Resultado = { status: number; body: Record<string, unknown> }

export async function mpGet(path: string, token: string): Promise<{ status: number; data: Record<string, any> }> {
  const res = await fetch(`${API}${path}`, { headers: { Authorization: `Bearer ${token}` } })
  return { status: res.status, data: await res.json().catch(() => ({})) }
}

export function metodoDe(p: Record<string, any>): string | null {
  if (p.payment_method_id === 'pix') return 'pix'
  if (p.payment_type_id === 'credit_card') return 'cartao_credito'
  if (p.payment_type_id === 'debit_card') return 'cartao_debito'
  return p.payment_method_id ?? null
}

/** Taxa REAL cobrada pelo Mercado Pago (soma de fee_details) e valor líquido recebido. Null se a API não informou. */
export function taxaRealDe(p: Record<string, any>): { taxa: number; liquido: number | null; parcelas: number | null } | null {
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
export async function registrarObjeto(db: SupabaseClient, p: Record<string, any>, modo: MpModo): Promise<Resultado> {
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
export async function processarPagamento(db: SupabaseClient, id: string, token: string, modo: MpModo): Promise<Resultado> {
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
