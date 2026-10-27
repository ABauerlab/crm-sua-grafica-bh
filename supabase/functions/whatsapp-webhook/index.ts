import { serviceClient } from '../_shared/http.ts'
import { confirmOptOut } from '../_shared/optout.ts'
import { extractEvents, isOptOutMessage, shouldApplyStatus } from '../_shared/parse.ts'
import { verifySignature } from '../_shared/signature.ts'

// verify_jwt = false: quem chama é a Meta. A autenticidade vem do X-Hub-Signature-256.
Deno.serve(async (req) => {
  const url = new URL(req.url)

  if (req.method === 'GET') {
    const verifyToken = Deno.env.get('WHATSAPP_VERIFY_TOKEN')
    if (
      verifyToken &&
      url.searchParams.get('hub.mode') === 'subscribe' &&
      url.searchParams.get('hub.verify_token') === verifyToken
    ) {
      return new Response(url.searchParams.get('hub.challenge') ?? '', { status: 200 })
    }
    return new Response('Forbidden', { status: 403 })
  }

  if (req.method !== 'POST') return new Response('Method Not Allowed', { status: 405 })

  const appSecret = Deno.env.get('META_APP_SECRET')
  if (!appSecret) {
    console.error('Segredo ausente: META_APP_SECRET')
    return new Response('Server misconfigured', { status: 500 })
  }

  // Corpo bruto: a assinatura é calculada sobre os bytes exatos recebidos.
  const raw = await req.text()
  if (!(await verifySignature(raw, req.headers.get('X-Hub-Signature-256'), appSecret))) {
    return new Response('Invalid signature', { status: 401 })
  }

  let payload
  try {
    payload = JSON.parse(raw)
  } catch {
    return new Response('Bad request', { status: 400 })
  }

  const db = serviceClient()
  const { messages, statuses } = extractEvents(payload)

  try {
    for (const m of messages) {
      const { error } = await db.rpc('ingest_inbound_message', {
        p_wa_id: m.waId,
        p_name: m.name,
        p_wa_message_id: m.waMessageId,
        p_type: m.type,
        p_body: m.body,
        p_media_id: m.mediaId,
        p_ts: m.timestamp.toISOString(),
      })
      if (error) throw error

      // "PARAR": registra o descadastro das promoções (mensagens de pedido seguem normalmente)
      if (m.type === 'text' && isOptOutMessage(m.body)) {
        // só na mudança de estado: reenvio do webhook ou PARAR repetido não gera nova confirmação
        const { data: changed, error: optErr } = await db
          .from('contacts')
          .update({ marketing_consent: 'opted_out', marketing_consent_at: new Date().toISOString(), marketing_consent_source: 'whatsapp' })
          .eq('wa_id', m.waId)
          .neq('marketing_consent', 'opted_out')
          .select('id')
        if (optErr) throw optErr
        if (changed?.length) await confirmOptOut(db, changed[0].id, m.waId)
      }
    }

    for (const s of statuses) {
      const { data: current } = await db.from('messages').select('status').eq('wa_message_id', s.waMessageId).maybeSingle()
      if (!current || !shouldApplyStatus(current.status, s.status)) continue
      const { error } = await db
        .from('messages')
        .update({ status: s.status, error: s.status === 'failed' ? s.error : null })
        .eq('wa_message_id', s.waMessageId)
      if (error) throw error
    }
  } catch (err) {
    // Sem conteúdo de mensagens nos logs. A Meta reenvia em caso de 500 (gravação é idempotente).
    console.error('Falha ao processar webhook:', err instanceof Error ? err.message : 'erro desconhecido')
    return new Response('Error', { status: 500 })
  }

  return new Response('OK', { status: 200 })
})
