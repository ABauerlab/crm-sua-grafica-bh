import { corsHeaders, json, requireOwnerOrServer, serviceClient } from '../_shared/http.ts'
import { API, buildItems, buildPreference, formatReference, parseExpiraHoras, toCents } from '../_shared/mp.ts'
import { mpConfig, webhookUrl } from '../_shared/mpconfig.ts'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

interface Body {
  acao?: 'status'
  pedido_id?: string
  orcamento_id?: string // no CRM o orçamento é o próprio pedido; aceito como apelido
  expira_horas?: number
  forcar_novo?: boolean
}

// Cria (ou devolve) o link de pagamento do Checkout Pro de um pedido. O valor vem sempre do banco, nunca do chamador.
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)

  const db = serviceClient()
  if (!(await requireOwnerOrServer(req, db))) return json({ error: 'Não autorizado.' }, 401)

  let input: Body
  try {
    input = await req.json()
  } catch {
    return json({ error: 'Corpo da requisição inválido.' }, 400)
  }

  const cfg = mpConfig()
  if (input.acao === 'status') {
    return json({ modo: cfg.modo, pronto: !!cfg.modo && cfg.faltando.length === 0, faltando: cfg.faltando, webhook_url: webhookUrl() })
  }
  if (!cfg.modo || !cfg.token) return json({ error: `Mercado Pago não configurado no servidor. Faltam: ${cfg.faltando.join(', ')}.` }, 500)

  const orderId = input.pedido_id ?? input.orcamento_id
  if (!orderId || !UUID.test(orderId)) return json({ error: 'Informe pedido_id.' }, 400)
  let horas: number
  try {
    horas = parseExpiraHoras(input.expira_horas)
  } catch (e) {
    return json({ error: (e as Error).message }, 400)
  }

  const { data: order } = await db.from('orders').select('id, number, teste').eq('id', orderId).maybeSingle()
  if (!order) return json({ error: 'Pedido não encontrado.' }, 404)
  if (cfg.modo === 'producao' && order.teste) return json({ error: 'Este é um pedido de teste e o servidor está em modo produção.' }, 422)

  // Ponto de extensão de regras (piso, margem...) antes de qualquer cobrança
  const { data: recusa, error: valErr } = await db.rpc('validar_antes_de_cobrar', { p_order: orderId })
  if (valErr) return json({ error: 'Não foi possível validar o pedido.' }, 500)
  if (recusa) return json({ error: String(recusa) }, 422)

  const [{ data: fin }, { data: itens }] = await Promise.all([
    db.from('order_financials').select('total').eq('order_id', orderId).maybeSingle(),
    db.from('order_items').select('description, qty, unit_price').eq('order_id', orderId).order('created_at'),
  ])
  const totalCents = toCents(Number(fin?.total ?? 0))
  const items = buildItems((itens ?? []).map((i) => ({ description: i.description, qty: i.qty, unit_price: Number(i.unit_price) })), totalCents)
  if (totalCents <= 0 || items.length === 0) return json({ error: 'O pedido precisa ter itens e valor maior que zero.' }, 422)

  let aviso: string | undefined
  const resposta = (l: { id: string; link: string | null; valor: number; expira_em: string | null }, reutilizado: boolean) =>
    json({ link: l.link, pagamento_id: l.id, valor: Number(l.valor), expira_em: l.expira_em, modo: cfg.modo, referencia: formatReference(order.number), reutilizado, ...(aviso ? { aviso } : {}) })

  // Mesmo pedido, mesmo valor, link ainda válido: devolve o mesmo link
  const { data: ativo } = await db.from('pagamentos').select('*').eq('order_id', orderId).eq('modo', cfg.modo).eq('eh_link', true).eq('link_ativo', true).maybeSingle()
  if (ativo) {
    const valido = ativo.expira_em && new Date(ativo.expira_em).getTime() > Date.now()
    if (valido && toCents(Number(ativo.valor)) === totalCents && !input.forcar_novo) return resposta(ativo, true)
    // Valor mudou, expirou ou foi pedido um novo: invalida o anterior (também no Mercado Pago, sem expor nada)
    await db.from('pagamentos').update({ link_ativo: false, status: ativo.mp_payment_id ? ativo.status : 'invalidado', atualizado_em: new Date().toISOString() }).eq('id', ativo.id)
    if (ativo.mp_preference_id && valido) {
      // Expira o link antigo no Mercado Pago para ninguém pagar o valor errado. Confere a resposta e avisa se não deu certo.
      const fim = new Date(Date.now() - 1000).toISOString()
      const put = await fetch(`${API}/checkout/preferences/${encodeURIComponent(ativo.mp_preference_id)}`, {
        method: 'PUT',
        headers: { Authorization: `Bearer ${cfg.token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ expires: true, expiration_date_from: new Date(ativo.criado_em).toISOString(), expiration_date_to: fim }),
      }).catch(() => null)
      if (!put || !put.ok) {
        console.error('Mercado Pago não expirou a preferência anterior', put?.status ?? 'sem resposta')
        aviso = 'O link antigo não foi desativado no Mercado Pago. Se o cliente ainda tiver o link antigo, o pagamento chega como divergência em Alertas e o pedido não muda sozinho.'
      }
    }
  }

  const now = new Date()
  // Política curta (descrição do link) e máximo de parcelas vêm de Configurações; se falhar, vale o padrão
  const [{ data: politica }, { data: parc }] = await Promise.all([
    db.rpc('politica_texto', { p_chave: 'descricao_link' }),
    db.from('app_settings').select('value').eq('key', 'parcelamento').maybeSingle(),
  ])
  const maxParcelas = Number((parc?.value as { maximo_link?: number } | null)?.maximo_link)
  const preference = buildPreference({
    maxParcelas: Number.isFinite(maxParcelas) && maxParcelas >= 1 ? maxParcelas : undefined,
    politica: typeof politica === 'string' ? politica : null,
    items,
    reference: formatReference(order.number),
    notificationUrl: `${webhookUrl()}?source_news=webhooks`,
    backBase: Deno.env.get('CRM_BASE_URL') ?? 'https://crm.suagraficabh.com.br',
    now,
    horas,
  })
  const res = await fetch(`${API}/checkout/preferences`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${cfg.token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(preference),
  })
  const pref = await res.json().catch(() => ({}))
  if (!res.ok || !pref.id) {
    console.error('Mercado Pago recusou a preferência', res.status, typeof pref?.message === 'string' ? pref.message : '')
    return json({ error: 'O Mercado Pago não aceitou a cobrança. Confira as credenciais e tente de novo.' }, 502)
  }
  const link: string | null = (cfg.modo === 'teste' ? pref.sandbox_init_point : null) ?? pref.init_point ?? null
  if (!link) return json({ error: 'O Mercado Pago não devolveu o link.' }, 502)

  const { data: novo, error: insErr } = await db.from('pagamentos').insert({
    order_id: orderId, eh_link: true, link_ativo: true, mp_preference_id: pref.id, link,
    valor: totalCents / 100, status: 'pendente', modo: cfg.modo, expira_em: preference.expiration_date_to,
  }).select('*').single()
  if (insErr) {
    // Outra chamada criou o link ao mesmo tempo: devolve o dela
    if (insErr.code === '23505') {
      const { data: outro } = await db.from('pagamentos').select('*').eq('order_id', orderId).eq('modo', cfg.modo).eq('eh_link', true).eq('link_ativo', true).maybeSingle()
      if (outro) return resposta(outro, true)
    }
    console.error('Falha ao gravar a cobrança', insErr.code)
    return json({ error: 'Não foi possível gravar a cobrança.' }, 500)
  }

  await db.from('eventos_pagamento').insert({
    chave: `link_criado:${novo.id}`, tipo: 'link_criado', order_id: orderId, pagamento_id: novo.id,
    payload: { pedido_id: orderId, pedido_numero: order.number, referencia: formatReference(order.number), valor: totalCents / 100, modo: cfg.modo, expira_em: preference.expiration_date_to, teste: order.teste },
  })
  await db.from('orders').update({ payment_link: link }).eq('id', orderId)

  return resposta(novo, false)
})
