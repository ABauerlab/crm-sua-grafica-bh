import { acionarAgente } from '../_shared/agente.ts'
import { serviceClient } from '../_shared/http.ts'
import { confirmOptOut } from '../_shared/optout.ts'
import { extractEvents, isOptOutMessage, shouldApplyStatus } from '../_shared/parse.ts'
import { verifySignature } from '../_shared/signature.ts'
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2'

// verify_jwt = false: quem chama é a Meta. A autenticidade vem do X-Hub-Signature-256.
//
// Fila de entrada: o evento bruto é gravado em webhook_eventos e a resposta 200 sai logo depois, sem esperar o n8n.
// O processamento roda em segundo plano (EdgeRuntime.waitUntil). Se falhar, o evento fica pendente e é reprocessado
// pelas próximas chamadas do webhook. Sem a fila (erro ao gravar), processa na hora, como antes.
// Eventos já processados são apagados após 3 dias. Logs nunca incluem o conteúdo das mensagens.

const ESPERA_REPROCESSO_MS = 30_000
const LOTE_REPROCESSO = 20
const RETENCAO_DIAS = 3

async function sha256(texto: string): Promise<string> {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(texto))
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, '0')).join('')
}

/** Aplica um evento da Meta no banco e avisa o agente. Idempotente: reprocessar não duplica mensagens. */
// deno-lint-ignore no-explicit-any
async function processarEvento(db: SupabaseClient, payload: any): Promise<boolean> {
  const { messages, statuses } = extractEvents(payload)
  try {
    for (const m of messages) {
      const { data: gravada, error } = await db.rpc('ingest_inbound_message', {
        p_wa_id: m.waId,
        p_name: m.name,
        p_wa_message_id: m.waMessageId,
        p_type: m.type,
        p_body: m.body,
        p_media_id: m.mediaId,
        p_ts: m.timestamp.toISOString(),
        p_referral: m.referral
          ? {
              source_url: m.referral.sourceUrl,
              source_id: m.referral.sourceId,
              source_type: m.referral.sourceType,
              headline: m.referral.headline,
              body: m.referral.body,
              media_type: m.referral.mediaType,
              ctwa_clid: m.referral.ctwaClid,
            }
          : null,
      })
      if (error) throw error

      // detalhes da mensagem (resposta a outra, encaminhada, tipo original, arquivo, local...). Falha aqui não derruba o webhook.
      if (gravada) {
        const { error: extraErr } = await db
          .from('messages')
          .update({ reply_to_wa_id: m.replyToWaId, forwarded: m.forwarded, raw_type: m.rawType, meta: m.meta })
          .eq('id', gravada)
        if (extraErr) console.error('Falha ao gravar os detalhes da mensagem:', extraErr.message)
      }

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

      // Mensagem nova (a duplicada devolve null) e que não é o PARAR: avisa o WF1 do n8n, depois do descadastro (o agente confere o optout).
      // O agente decide se responde; falha aqui nunca derruba o processamento.
      if (gravada && m.type !== 'reaction' && !(m.type === 'text' && isOptOutMessage(m.body))) {
        await acionarAgente(String(gravada), { url: Deno.env.get('N8N_WF1_URL'), token: Deno.env.get('N8N_WF1_TOKEN') })
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
    return true
  } catch (err) {
    // Sem conteúdo de mensagens nos logs.
    console.error('Falha ao processar evento do webhook:', err instanceof Error ? err.message : 'erro desconhecido')
    return false
  }
}

/** Processa o evento atual e os pendentes antigos (em ordem de chegada), e limpa o que já foi processado há muito tempo. */
async function processarFila(db: SupabaseClient, hashAtual: string): Promise<void> {
  const limite = new Date(Date.now() - ESPERA_REPROCESSO_MS).toISOString()
  const { data: pendentes, error } = await db
    .from('webhook_eventos')
    .select('id, hash, payload')
    .is('processado_em', null)
    .or(`hash.eq.${hashAtual},recebido_em.lt.${limite}`)
    .order('recebido_em', { ascending: true })
    .limit(LOTE_REPROCESSO)
  if (error) {
    console.error('Falha ao ler a fila do webhook')
  }
  for (const ev of pendentes ?? []) {
    const ok = await processarEvento(db, ev.payload)
    if (ok) {
      await db.from('webhook_eventos').update({ processado_em: new Date().toISOString() }).eq('id', ev.id)
    } else {
      const { data: atual } = await db.from('webhook_eventos').select('tentativas').eq('id', ev.id).maybeSingle()
      await db.from('webhook_eventos').update({ tentativas: (atual?.tentativas ?? 0) + 1, ultimo_erro: 'falha_processamento' }).eq('id', ev.id)
    }
  }
  const corte = new Date(Date.now() - RETENCAO_DIAS * 24 * 60 * 60 * 1000).toISOString()
  await db.from('webhook_eventos').delete().not('processado_em', 'is', null).lt('processado_em', corte)
}

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
  const hash = await sha256(raw)

  // Grava o evento antes de responder. Se a fila não estiver disponível, processa na hora (a Meta reenvia em caso de erro).
  const { error: filaErr } = await db
    .from('webhook_eventos')
    .upsert({ hash, payload, recebido_em: new Date().toISOString() }, { onConflict: 'hash', ignoreDuplicates: true })
  if (filaErr) {
    console.error('Fila do webhook indisponível; processando na hora')
    const ok = await processarEvento(db, payload)
    return ok ? new Response('OK', { status: 200 }) : new Response('Error', { status: 500 })
  }

  // Resposta imediata; o trabalho segue em segundo plano.
  // deno-lint-ignore no-explicit-any
  const emSegundoPlano = (globalThis as any).EdgeRuntime?.waitUntil as ((p: Promise<unknown>) => void) | undefined
  const trabalho = processarFila(db, hash)
  if (emSegundoPlano) emSegundoPlano(trabalho)
  else await trabalho
  return new Response('OK', { status: 200 })
})
