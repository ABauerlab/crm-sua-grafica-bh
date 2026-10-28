import { json, serviceClient } from '../_shared/http.ts'
import { verifyMpSignature } from '../_shared/mp.ts'
import { mpConfig } from '../_shared/mpconfig.ts'
import { mpGet, processarPagamento, type Resultado } from '../_shared/mppay.ts'

const ID = /^\d{1,20}$/

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)

  const cfg = mpConfig()
  if (!cfg.modo || !cfg.token || !cfg.signatureSecret) {
    console.error('Mercado Pago não configurado. Faltam:', cfg.faltando.join(', '))
    return json({ error: 'Integração não configurada.' }, 500)
  }

  const url = new URL(req.url)
  const raw = await req.text()
  let body: Record<string, any> = {}
  try {
    body = raw ? JSON.parse(raw) : {}
  } catch {
    /* corpo inválido: a assinatura decide */
  }
  const dataId = url.searchParams.get('data.id') ?? (body?.data?.id != null ? String(body.data.id) : null)

  const sig = await verifyMpSignature({
    secret: cfg.signatureSecret,
    signatureHeader: req.headers.get('x-signature'),
    requestId: req.headers.get('x-request-id'),
    dataId,
  })
  if (!sig.ok) {
    console.error('Aviso rejeitado:', sig.reason)
    return json({ error: 'Assinatura inválida.' }, 401)
  }
  if (!dataId) return json({ ok: true, ignorado: 'sem_id' })

  const db = serviceClient()
  const tipo = String(body.type ?? url.searchParams.get('type') ?? url.searchParams.get('topic') ?? '')

  let r: Resultado
  if (tipo === 'payment') {
    r = await processarPagamento(db, dataId, cfg.token, cfg.modo)
  } else if (tipo === 'topic_chargebacks_wh' || tipo === 'chargebacks') {
    // Contestação: descobre os pagamentos envolvidos e processa cada um (o status vira charged_back)
    const cb = ID.test(dataId) ? await mpGet(`/v1/chargebacks/${dataId}`, cfg.token) : { status: 404, data: {} as Record<string, any> }
    const ids: string[] = (Array.isArray(cb.data.payments) ? cb.data.payments : []).map(String).filter((x: string) => ID.test(x))
    r = { status: 200, body: { ok: true, ignorado: ids.length ? undefined : 'contestacao_sem_pagamento' } }
    for (const pid of ids) {
      await db.rpc('mp_registrar_alerta', { p_tipo: 'contestacao', p_mp_payment_id: pid, p_chave: `chargeback:${dataId}`, p_mensagem: 'Contestação aberta em um pagamento. Responda no painel do Mercado Pago. O pedido não foi alterado.', p_detalhes: { chargeback_id: dataId } })
      r = await processarPagamento(db, pid, cfg.token, cfg.modo)
      if (r.status !== 200) break
    }
  } else if (tipo === 'topic_claims_integration_wh' || tipo === 'claims') {
    const cl = ID.test(dataId) ? await mpGet(`/post-purchase/v1/claims/${dataId}`, cfg.token) : { status: 404, data: {} as Record<string, any> }
    const pid = cl.data.resource === 'payment' && ID.test(String(cl.data.resource_id ?? '')) ? String(cl.data.resource_id) : null
    if (pid) {
      await db.rpc('mp_registrar_alerta', { p_tipo: 'reclamacao', p_mp_payment_id: pid, p_chave: `claim:${dataId}:${cl.data.status ?? ''}`, p_mensagem: 'Reclamação do comprador em um pagamento. Responda no painel do Mercado Pago. O pedido não foi alterado.', p_detalhes: { claim_id: dataId, etapa: cl.data.stage ?? null } })
      r = { status: 200, body: { ok: true, alerta: 'reclamacao' } }
    } else {
      r = { status: 200, body: { ok: true, ignorado: 'reclamacao_sem_pagamento' } }
    }
  } else {
    r = { status: 200, body: { ok: true, ignorado: 'tipo_nao_tratado' } }
  }
  return json(r.body, r.status)
})
