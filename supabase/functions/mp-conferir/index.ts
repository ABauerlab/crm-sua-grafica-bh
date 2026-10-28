import { corsHeaders, json, requireOwnerOrServer, serviceClient } from '../_shared/http.ts'
import { formatReference } from '../_shared/mp.ts'
import { mpConfig } from '../_shared/mpconfig.ts'
import { mpGet, registrarObjeto } from '../_shared/mppay.ts'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

// "Conferir agora": pergunta ao Mercado Pago pelos pagamentos de um pedido (ou de todos os pedidos com cobrança em aberto)
// e grava pelo mesmo caminho do webhook. Cobre aviso perdido. Também roda sozinho por agendamento (x-cron-secret).
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)

  const db = serviceClient()
  const cronSecret = Deno.env.get('CRON_SECRET')
  const sent = req.headers.get('x-cron-secret')
  const fromCron = !!cronSecret && !!sent && sent.length === cronSecret.length && sent === cronSecret
  if (!fromCron && !(await requireOwnerOrServer(req, db))) return json({ error: 'Não autorizado.' }, 401)

  const cfg = mpConfig()
  if (!cfg.modo || !cfg.token) return json({ error: `Mercado Pago não configurado no servidor. Faltam: ${cfg.faltando.join(', ')}.` }, 500)

  const input = await req.json().catch(() => ({})) as { pedido_id?: string }
  let numeros: number[] = []
  if (input.pedido_id) {
    if (!UUID.test(input.pedido_id)) return json({ error: 'pedido_id inválido.' }, 400)
    const { data: o } = await db.from('orders').select('number').eq('id', input.pedido_id).maybeSingle()
    if (!o) return json({ error: 'Pedido não encontrado.' }, 404)
    numeros = [o.number]
  } else {
    // Pedidos com link ainda em aberto nos últimos 3 dias (no modo atual)
    const desde = new Date(Date.now() - 3 * 86_400_000).toISOString()
    const { data: abertos } = await db.from('pagamentos').select('order_id, orders!inner(number, payment_status)')
      .eq('modo', cfg.modo).in('status', ['pendente', 'em_analise']).gte('criado_em', desde).neq('orders.payment_status', 'aprovado').limit(200)
    numeros = [...new Set((abertos ?? []).map((a: any) => a.orders.number as number))].slice(0, 20)
  }

  const resumo = { pedidos: numeros.length, pagamentos: 0, confirmados: 0, alertas: 0, atualizados: 0 }
  for (const n of numeros) {
    const { status, data } = await mpGet(`/v1/payments/search?external_reference=${encodeURIComponent(formatReference(n))}&sort=date_created&criteria=desc&limit=10`, cfg.token)
    if (status === 401 || status === 403) return json({ error: 'Credenciais do Mercado Pago inválidas.' }, 500)
    if (status !== 200) return json({ error: 'Mercado Pago indisponível, tente de novo.' }, 502)
    // Do mais antigo para o mais novo, para o estado final ficar certo
    for (const p of [...((data.results ?? []) as Record<string, any>[])].reverse()) {
      resumo.pagamentos++
      const r = await registrarObjeto(db, p, cfg.modo)
      if (r.status !== 200) return json(r.body, r.status)
      const acao = r.body.acao
      if (acao === 'confirmado') resumo.confirmados++
      else if (acao === 'alerta') resumo.alertas++
      else if (acao === 'registrado') resumo.atualizados++
    }
  }
  return json({ ok: true, ...resumo })
})
