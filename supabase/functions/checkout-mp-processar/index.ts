// Checkout próprio: cobra Pix ou cartão (até 2x sem juros) pela API de pagamentos do Mercado Pago, sem redirecionar o cliente.
// O VALOR e a REFERÊNCIA vêm sempre do banco (nunca do navegador). O resultado entra pelo mesmo caminho do webhook
// (mp_registrar_pagamento), então o pedido vira Pago e a mensagem de confirmação no WhatsApp sai como sempre.
// Problema técnico, recusa repetida ou juros fora do combinado viram alerta ao dono (popup no app + WhatsApp). Logs sem dados pessoais.
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2'
import { corsHeaders, json, serviceClient } from '../_shared/http.ts'
import { API, formatReference, toCents } from '../_shared/mp.ts'
import { mpConfig, webhookUrl } from '../_shared/mpconfig.ts'
import { mpGet, registrarObjeto } from '../_shared/mppay.ts'
import { lerPix } from '../_shared/mp-pix.ts'
import { corpoPagamento, desfechoCartao, documentoValido, emailValido, lerEntrada, pagouComJuros, TOKEN_CHECKOUT } from '../_shared/checkout.ts'

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
  // Até 2x sem juros (a conta absorve); de 3x a 12x o Mercado Pago cobra os juros do cliente e mostra o total no formulário
  const semJuros = Math.min(Math.max(Number(pc?.parcelas_sem_juros_max ?? 2), 1), 2)
  const maxParcelas = 12

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
    const juros = entrada.parcelas <= semJuros ? pagouComJuros(p) : null
    if (juros) await alertar(db, o, `Pedido ${referencia} pago em ${entrada.parcelas}x COM JUROS para o cliente (R$ ${juros.juros.toFixed(2).replace('.', ',')} a mais). Ative o parcelamento sem juros na conta do Mercado Pago.`, `chk_juros:${p.id}`, { juros: juros.juros })
  } else if (r.status === 'rejected') {
    const { count } = await db.from('checkout_eventos').select('id', { count: 'exact', head: true }).eq('order_id', o.id).eq('tipo', 'cartao_recusado').gt('criado_em', new Date(Date.now() - 30 * 60_000).toISOString())
    if ((count ?? 0) >= 2) await alertar(db, o, `Cliente do pedido ${referencia} teve ${count} recusas de cartão em 30 minutos. Chame no WhatsApp e ofereça o Pix.`, `chk_dificuldade:${o.id}:${Math.floor(Date.now() / 1_800_000)}`, { recusas: count })
  }
  return json({ ok: true, status: r.status, metodo: 'cartao', mensagem: r.mensagem, parcelas: entrada.parcelas, status_detalhe: r.status === 'rejected' ? p.status_detail ?? null : null })
})
