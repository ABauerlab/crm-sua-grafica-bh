import type { Contact } from '@/lib/types'
import { ORDER_STAGES, type OrderCard, type OrderStage } from '@/lib/orders'

/** Gerador determinístico de dados de exemplo para apresentar o painel (nada é gravado no banco). */
function rng(seed: number) {
  let s = seed
  return () => {
    s = (s * 1664525 + 1013904223) % 4294967296
    return s / 4294967296
  }
}

const PRODUCTS: { name: string; cost: number; price: number }[] = [
  { name: '500 cartões de visita', cost: 48, price: 119 },
  { name: '1.000 panfletos A5', cost: 95, price: 219 },
  { name: 'Kit Barbearia', cost: 210, price: 459 },
  { name: 'Kit Delivery', cost: 160, price: 349 },
  { name: 'Banner 80x120', cost: 55, price: 139 },
  { name: '200 adesivos redondos', cost: 38, price: 99 },
  { name: 'Kit Lançamento', cost: 340, price: 749 },
]
const ORIGINS = ['Cartões de visita BH', 'Kit Barbearia', 'Panfletos e flyers', null, null, null]
const NAMES = ['Ana', 'Bruno', 'Carla', 'Diego', 'Elisa', 'Fábio', 'Gabi', 'Hugo', 'Iara', 'João', 'Karina', 'Leo', 'Marta', 'Nando', 'Olívia', 'Paulo']

export function buildDemo(now = Date.now()): { orders: OrderCard[]; contacts: Contact[] } {
  const r = rng(42)
  const day = 86_400_000
  const orders: OrderCard[] = []
  const contacts: Contact[] = []

  for (let i = 0; i < 220; i++) {
    const age = Math.floor(Math.pow(r(), 1.25) * 89)
    contacts.push({
      id: `dc${i}`,
      wa_id: `55319${String(80000000 + i)}`,
      name: `${NAMES[i % NAMES.length]} ${String.fromCharCode(65 + (i % 26))}.`,
      notes: null,
      tags: [],
      marketing_consent: r() < 0.5 ? 'opted_in' : r() < 0.08 ? 'opted_out' : 'none',
      marketing_consent_at: null,
      marketing_consent_source: null,
      created_at: new Date(now - age * day - r() * day).toISOString(),
    })
  }

  for (let i = 0; i < 260; i++) {
    const created = now - Math.floor(Math.pow(r(), 1.15) * 89) * day - Math.floor(r() * day)
    const ageDays = (now - created) / day
    const p = PRODUCTS[Math.floor(r() * PRODUCTS.length)]
    const qty = r() < 0.2 ? 2 : 1
    const origin = ORIGINS[Math.floor(r() * ORIGINS.length)]
    // Quanto mais velho, mais provável já estar entregue
    let stage: OrderStage
    const roll = r()
    if (ageDays > 12) stage = roll < 0.12 ? 'novo' : roll < 0.2 ? 'cotando' : roll < 0.28 ? 'aguardando_pagamento' : roll < 0.8 ? 'entregue' : 'recompra'
    else if (ageDays > 4) stage = roll < 0.3 ? ORDER_STAGES[Math.floor(r() * 3)].value : ORDER_STAGES[3 + Math.floor(r() * 6)].value
    else stage = ORDER_STAGES[Math.floor(r() * 7)].value
    const paid = ['pago', 'arte', 'prova', 'producao', 'entregue', 'recompra'].includes(stage)
    const gross = p.price * qty
    const discount = r() < 0.2 ? 5 : 0
    const total = gross * (1 - discount / 100)
    const cost = p.cost * qty
    const tax = total * 0.06
    const fee = total * 0.015
    const net = total - cost - tax - fee
    const contact = contacts[Math.floor(r() * contacts.length)]
    const paidAt = paid ? new Date(created + (0.2 + r() * 1.5) * day).toISOString() : null
    orders.push({
      id: `d${i}`,
      number: 1000 + i,
      contact_id: contact.id,
      conversation_id: `c${i}`,
      title: p.name,
      stage,
      stage_entered_at: new Date(now - Math.min(ageDays, r() * 1.4) * day).toISOString(),
      notes: null,
      origin_ad_id: origin ? 'ad' : null,
      origin_label: origin,
      origin_url: null,
      discount_pct: discount,
      tax_pct: 6,
      payment_fee_pct: 1.5,
      price_override_reason: null,
      payment_status: paid ? 'aprovado' : 'pendente',
      payment_method: paid ? (r() < 0.7 ? 'pix' : 'cartao') : null,
      payment_link: null,
      payment_external_id: null,
      payment_confirmed_at: paidAt,
      payment_manual: false,
      paid_at: paidAt,
      art_mode: null,
      art_status: 'aguardando',
      art_approved_at: null,
      art_checklist: {},
      supplier_order_no: null,
      due_date: null,
      lead_days: null,
      due_date_manual: false,
      teste: false,
      delivery_method: null,
      delivery_address: null,
      delivery_fee: null,
      delivery_tracking: null,
      delivered_at: null,
      created_at: new Date(created).toISOString(),
      updated_at: new Date(created).toISOString(),
      contact: { id: contact.id, name: contact.name, wa_id: contact.wa_id },
      conversation: { id: `c${i}`, ai_handled: r() < 0.4, unread_count: 0, last_inbound_at: null },
      items: [{ description: p.name, qty }],
      fin: {
        order_id: `d${i}`,
        gross,
        total: Math.round(total * 100) / 100,
        cost,
        tax: Math.round(tax * 100) / 100,
        fee: Math.round(fee * 100) / 100,
        net_profit: Math.round(net * 100) / 100,
        margin_pct: Math.round((net / total) * 1000) / 10,
      },
    })
  }
  return { orders, contacts }
}
