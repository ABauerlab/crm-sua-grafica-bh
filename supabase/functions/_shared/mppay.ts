import type { SupabaseClient } from 'npm:@supabase/supabase-js@2'
import { API, type MpModo } from './mp.ts'

export type Resultado = { status: number; body: Record<string, unknown> }

export async function mpGet(path: string, token: string): Promise<{ status: number; data: Record<string, any> }> {
  const res = await fetch(`${API}${path}`, { headers: { Authorization: `Bearer ${token}` } })
  return { status: res.status, data: await res.json().catch(() => ({})) }
}

export function metodoDe(p: Record<string, any>): string | null {
  if (p.payment_method_id === 'pix') return 'pix'
  if (p.payment_type_id === 'credit_card' || p.payment_type_id === 'debit_card') return 'cartao'
  return p.payment_method_id ?? null
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
