// E-commerce Fase 4: checkout do site. Valida o carrinho, monta orçamento e pedido pelo banco (mesma trava de lucro do CRM)
// e devolve o link do Mercado Pago (mp-criar-link chamado por dentro com a service role). Público, com limites no banco.
// Logs sem dados pessoais.
import { corsHeaders, json, serviceClient } from '../_shared/http.ts'
import { mensagemErro, validarPedido } from '../_shared/loja-validar.ts'

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)
  let body: unknown
  try {
    body = await req.json()
  } catch {
    return json({ error: 'Corpo da requisição inválido.' }, 400)
  }
  const v = validarPedido(body)
  if (!v.ok) return json({ error: v.erros[0], erros: v.erros }, 400)
  const p = v.pedido

  const db = serviceClient()
  const { data: prep, error } = await db.rpc('loja_checkout_preparar', { p_cliente: p.cliente, p_itens: p.itens, p_opcoes: p.opcoes })
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

  const res = await fetch(`${Deno.env.get('SUPABASE_URL')}/functions/v1/mp-criar-link`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')}` },
    body: JSON.stringify({ pedido_id: r.pedido_id }),
  })
  const link = await res.json().catch(() => ({})) as { url?: string; init_point?: string; link?: string; error?: string }
  const url = link.url ?? link.init_point ?? link.link
  if (!res.ok || !url) {
    console.error('loja-checkout: link do Mercado Pago falhou', res.status)
    return json({ error: 'Pedido criado, mas o link de pagamento não saiu. Vamos te chamar no WhatsApp para finalizar.', numero: r.numero }, 502)
  }
  console.log('loja-checkout: pedido criado')
  return json({ ok: true, numero: r.numero, total: r.total, prazo: r.prazo, data_prevista: r.data_prevista, link_pagamento: url })
})
