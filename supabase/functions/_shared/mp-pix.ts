// E-commerce Fase 9: Pix direto (copia e cola) pela API de pagamentos do Mercado Pago. Funções puras (testadas em Node).

export interface PagadorPix { email: string; nome: string; documento: string | null }

export function corpoPix(o: { valor: number; referencia: string; descricao: string; notificationUrl: string; pagador: PagadorPix; expiraEm: Date }) {
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

export interface PixPronto { pagamento_id: string; copia_e_cola: string; qr_base64: string | null; expira_em: string | null }

/** Lê a resposta do Mercado Pago. Null se o Pix não veio (sem código copia e cola não há o que mostrar). */
export function lerPix(p: Record<string, any> | null): PixPronto | null {
  const t = p?.point_of_interaction?.transaction_data
  if (!p?.id || typeof t?.qr_code !== 'string' || !t.qr_code) return null
  return { pagamento_id: String(p.id), copia_e_cola: t.qr_code, qr_base64: typeof t.qr_code_base64 === 'string' ? t.qr_code_base64 : null, expira_em: p.date_of_expiration ?? null }
}
