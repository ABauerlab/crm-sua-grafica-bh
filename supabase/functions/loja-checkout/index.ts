// E-commerce Fases 4 e 9: checkout do site. Valida o carrinho, cota o envio (SuperFrete), monta orçamento e pedido pelo banco
// (mesma trava de lucro do CRM) e gera o pagamento: Pix copia e cola (padrão) ou link do Mercado Pago (cartão).
// Também troca a forma de pagamento de um pedido já criado (acao "pagar"). Público, com limites no banco. Logs sem dados pessoais.
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2'
import { corsHeaders, json, serviceClient } from '../_shared/http.ts'
import { mensagemErro, validarPedido, type PedidoSite } from '../_shared/loja-validar.ts'
import { API, formatReference, toCents } from '../_shared/mp.ts'
import { mpConfig, webhookUrl } from '../_shared/mpconfig.ts'
import { mpGet, registrarObjeto } from '../_shared/mppay.ts'
import { corpoPix, lerPix, type PixPronto } from '../_shared/mp-pix.ts'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
type Falha = { falha: { status: number; mensagem: string } }

/** Valor, status e recusas do pedido antes de qualquer cobrança. */
async function pedidoParaCobrar(db: SupabaseClient, orderId: string): Promise<Falha | { order: Record<string, any>; cents: number }> {
  const { data: order } = await db.from('orders')
    .select('id, number, teste, payment_status, origin_label, contacts(name, email, document)').eq('id', orderId).maybeSingle()
  if (!order || order.origin_label !== 'site') return { falha: { status: 404, mensagem: 'Pedido não encontrado.' } }
  const { data: recusa, error } = await db.rpc('validar_antes_de_cobrar', { p_order: orderId })
  if (error) return { falha: { status: 500, mensagem: 'Não foi possível validar o pedido.' } }
  if (recusa) return { falha: { status: 422, mensagem: String(recusa) } }
  const { data: fin } = await db.from('order_financials').select('total').eq('order_id', orderId).maybeSingle()
  const cents = toCents(Number(fin?.total ?? 0))
  if (cents <= 0) return { falha: { status: 422, mensagem: 'O pedido precisa ter valor maior que zero.' } }
  return { order, cents }
}

/** Pix copia e cola. Reaproveita o Pix pendente do mesmo valor; senão cria um novo. */
async function pixDoPedido(db: SupabaseClient, orderId: string, emailInformado: string | null): Promise<Falha | { pix: PixPronto; cents: number }> {
  const cfg = mpConfig()
  if (!cfg.modo || !cfg.token) { console.error('loja-checkout: Mercado Pago sem configuração', cfg.faltando.join(',')); return { falha: { status: 503, mensagem: 'O pagamento está em manutenção. Fale com a gente no WhatsApp.' } } }
  const base = await pedidoParaCobrar(db, orderId)
  if ('falha' in base) return base
  const { order, cents } = base
  if (cfg.modo === 'producao' && order.teste) return { falha: { status: 422, mensagem: 'Pedido de teste.' } }

  const { data: antigos } = await db.from('pagamentos').select('mp_payment_id, valor').eq('order_id', orderId).eq('modo', cfg.modo)
    .eq('metodo', 'pix').eq('status', 'pendente').not('mp_payment_id', 'is', null)
    .gt('criado_em', new Date(Date.now() - 23 * 3600_000).toISOString()).order('criado_em', { ascending: false }).limit(1)
  const antigo = antigos?.[0]
  if (antigo && toCents(Number(antigo.valor)) === cents) {
    const { status, data: p } = await mpGet(`/v1/payments/${antigo.mp_payment_id}`, cfg.token)
    const pix = status === 200 && p.status === 'pending' ? lerPix(p) : null
    if (pix) return { pix, cents }
  }

  const email = emailInformado ?? order.contacts?.email ?? null
  if (!email) return { falha: { status: 400, mensagem: 'Informe um e-mail para gerar o Pix.' } }
  const corpo = corpoPix({
    valor: cents / 100, referencia: formatReference(order.number), descricao: `Pedido ${formatReference(order.number)} - Sua Gráfica BH`,
    notificationUrl: `${webhookUrl()}?source_news=webhooks`, expiraEm: new Date(Date.now() + 24 * 3600_000),
    pagador: { email, nome: order.contacts?.name ?? 'Cliente', documento: order.contacts?.document ?? null },
  })
  const res = await fetch(`${API}/v1/payments`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${cfg.token}`, 'Content-Type': 'application/json', 'X-Idempotency-Key': `pix-${orderId}-${cents}-${Math.floor(Date.now() / 60_000)}` },
    body: JSON.stringify(corpo),
  })
  const p = await res.json().catch(() => ({})) as Record<string, any>
  const pix = res.ok ? lerPix(p) : null
  if (!pix) {
    console.error('loja-checkout: Mercado Pago recusou o Pix', res.status, typeof p?.message === 'string' ? p.message : '')
    return { falha: { status: 502, mensagem: 'Não conseguimos gerar o Pix agora. Tente de novo ou pague no cartão.' } }
  }
  const reg = await registrarObjeto(db, p, cfg.modo)
  if (reg.status !== 200) console.error('loja-checkout: Pix criado mas não gravado', reg.status)
  return { pix, cents }
}

/** Link do Checkout Pro (cartão). Cancela antes um Pix pendente, para ninguém pagar duas vezes. */
async function linkDoPedido(db: SupabaseClient, orderId: string): Promise<Falha | { link: string }> {
  const cfg = mpConfig()
  if (cfg.modo && cfg.token) {
    const { data: pend } = await db.from('pagamentos').select('mp_payment_id').eq('order_id', orderId).eq('modo', cfg.modo)
      .eq('metodo', 'pix').eq('status', 'pendente').not('mp_payment_id', 'is', null)
    for (const x of pend ?? []) {
      await fetch(`${API}/v1/payments/${x.mp_payment_id}`, {
        method: 'PUT', headers: { Authorization: `Bearer ${cfg.token}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ status: 'cancelled' }),
      }).catch(() => null)
    }
  }
  const res = await fetch(`${Deno.env.get('SUPABASE_URL')}/functions/v1/mp-criar-link`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')}` },
    body: JSON.stringify({ pedido_id: orderId }),
  })
  const l = await res.json().catch(() => ({})) as { url?: string; init_point?: string; link?: string }
  const url = l.url ?? l.init_point ?? l.link
  if (!res.ok || !url) { console.error('loja-checkout: link do Mercado Pago falhou', res.status); return { falha: { status: 502, mensagem: 'Não conseguimos abrir o pagamento no cartão agora. Tente o Pix ou fale com a gente no WhatsApp.' } } }
  return { link: url }
}

/** Cota o envio no SuperFrete pela função loja-frete e devolve a opção escolhida (preço sempre recalculado aqui). */
async function cotarEnvio(p: PedidoSite): Promise<Falha | { valor: number; nome: string; prazo: number | null }> {
  const res = await fetch(`${Deno.env.get('SUPABASE_URL')}/functions/v1/loja-frete`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')}` },
    body: JSON.stringify({ cep: p.opcoes.cep, itens: p.itens, arte: p.opcoes.arte }),
  })
  const f = await res.json().catch(() => ({})) as { grande_bh?: boolean; envio?: { opcoes?: { servico: string; nome: string; valor: number; prazo_dias: number | null }[] }; error?: string }
  if (!res.ok) return { falha: { status: res.status === 404 ? 400 : 502, mensagem: f.error ?? 'Não foi possível calcular o frete.' } }
  if (f.grande_bh) return { falha: { status: 400, mensagem: 'Para a Grande BH use a entrega local. O envio pelos Correios é para outras cidades.' } }
  const o = f.envio?.opcoes?.find((x) => x.servico === p.opcoes.frete_servico)
  if (!o) return { falha: { status: 409, mensagem: mensagemErro('frete_indisponivel').mensagem } }
  return { valor: o.valor, nome: o.nome, prazo: o.prazo_dias }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)
  let body: Record<string, any>
  try {
    body = await req.json()
  } catch {
    return json({ error: 'Corpo da requisição inválido.' }, 400)
  }
  const db = serviceClient()

  // Trocar a forma de pagamento de um pedido que o cliente acabou de criar (o id do pedido é o comprovante)
  if (body.acao === 'pagar') {
    const id = String(body.pedido_id ?? '')
    if (!UUID.test(id)) return json({ error: 'Pedido inválido.' }, 400)
    if (body.metodo === 'cartao') {
      const base = await pedidoParaCobrar(db, id)
      if ('falha' in base) return json({ error: base.falha.mensagem }, base.falha.status)
      const l = await linkDoPedido(db, id)
      return 'falha' in l ? json({ error: l.falha.mensagem }, l.falha.status) : json({ ok: true, metodo: 'cartao', link_pagamento: l.link })
    }
    const email = typeof body.email === 'string' && /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(body.email.trim()) ? body.email.trim().toLowerCase() : null
    const r = await pixDoPedido(db, id, email)
    return 'falha' in r ? json({ error: r.falha.mensagem }, r.falha.status) : json({ ok: true, metodo: 'pix', total: r.cents / 100, pix: r.pix })
  }

  const v = validarPedido(body)
  if (!v.ok) return json({ error: v.erros[0], erros: v.erros }, 400)
  const p = v.pedido

  let envio: { valor: number; nome: string; prazo: number | null } | null = null
  if (p.opcoes.entrega === 'envio') {
    const e = await cotarEnvio(p)
    if ('falha' in e) return json({ error: e.falha.mensagem }, e.falha.status)
    envio = e
  }

  const { data: prep, error } = await db.rpc('loja_checkout_preparar', {
    p_cliente: p.cliente, p_itens: p.itens, p_opcoes: { arte: p.opcoes.arte, entrega: p.opcoes.entrega === 'retirada' ? 'retirada' : 'entrega', cep: p.opcoes.cep },
  })
  if (error) {
    console.error('loja-checkout: preparar falhou', error.code)
    return json({ error: 'Não foi possível criar o pedido agora. Tente de novo em instantes.' }, 500)
  }
  const r = prep as { ok: boolean; erro?: string; pedido_id?: string; numero?: number; total?: number; prazo?: string; data_prevista?: string }
  if (!r.ok) {
    const m = mensagemErro(r.erro)
    console.log(`loja-checkout: recusado (${r.erro})`)
    return json({ error: m.mensagem }, m.status)
  }
  const pedidoId = r.pedido_id!
  let total = Number(r.total ?? 0)

  // Envio nacional: o frete entra no pedido como item sem lucro (preço = custo). Se o lucro líquido do pedido deixar de existir, desfaz.
  if (envio) {
    const { data: item, error: e1 } = await db.from('order_items').insert({
      order_id: pedidoId, description: `Frete ${envio.nome}`, qty: 1, unit_price: envio.valor, unit_cost: envio.valor, fora_catalogo: true,
    }).select('id').single()
    const { data: fin } = await db.from('order_financials').select('total, net_profit').eq('order_id', pedidoId).maybeSingle()
    if (e1 || !item || Number(fin?.net_profit ?? 0) <= 0) {
      if (item) await db.from('order_items').delete().eq('id', item.id)
      console.error('loja-checkout: frete recusado pela trava de lucro')
      return json({ error: mensagemErro('orcamento_bloqueado').mensagem }, 422)
    }
    total = Number(fin!.total)
    await db.from('orders').update({
      delivery_method: 'correios', delivery_fee: envio.valor,
      notes: `Envio ${envio.nome} para o CEP ${p.opcoes.cep}${envio.prazo ? ` (prazo de até ${envio.prazo} dias úteis nos Correios)` : ''}.`,
    }).eq('id', pedidoId)
  } else if (p.opcoes.entrega === 'entrega') {
    await db.from('orders').update({ delivery_method: 'uber' }).eq('id', pedidoId)
  }

  // Carrinho abandonado vira recuperado (não pode atrapalhar o pedido)
  const { error: eCarrinho } = await db.rpc('loja_carrinho_fechar', { p_sessao: p.opcoes.sessao ?? '', p_whatsapp: p.cliente.whatsapp, p_pedido: pedidoId })
  if (eCarrinho) console.error('loja-checkout: carrinho não fechado', eCarrinho.code)

  const resumo = { ok: true, pedido_id: pedidoId, numero: r.numero, total, prazo: r.prazo, data_prevista: r.data_prevista }
  if (p.opcoes.pagamento === 'cartao') {
    const l = await linkDoPedido(db, pedidoId)
    if ('falha' in l) return json({ error: `${l.falha.mensagem} Seu pedido ${r.numero} ficou salvo.`, pedido_id: pedidoId, numero: r.numero }, l.falha.status)
    console.log('loja-checkout: pedido criado (cartão)')
    return json({ ...resumo, metodo: 'cartao', link_pagamento: l.link })
  }
  const x = await pixDoPedido(db, pedidoId, p.cliente.email)
  if ('falha' in x) return json({ error: `${x.falha.mensagem} Seu pedido ${r.numero} ficou salvo.`, pedido_id: pedidoId, numero: r.numero }, x.falha.status)
  console.log('loja-checkout: pedido criado (pix)')
  return json({ ...resumo, total: x.cents / 100, metodo: 'pix', pix: x.pix })
})
