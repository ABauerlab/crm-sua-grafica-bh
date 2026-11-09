// E-commerce Fase 7: envia a fila meta_eventos para a Conversions API da Meta (deduplicada com o Pixel pelo event_id).
// Chamada pelo agendamento (x-cron-secret) ou pelo dono/service role. Sem META_PIXEL_ID e META_CAPI_TOKEN não consome a fila.
// Logs sem dados pessoais.
import { corsHeaders, json, requireOwnerOrServer, serviceClient } from '../_shared/http.ts'
import { corpoMeta, type EventoFila } from '../_shared/meta.ts'

const VERSAO = 'v21.0'

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)
  const db = serviceClient()
  const cron = Deno.env.get('CRON_SECRET')
  const enviado = req.headers.get('x-cron-secret')
  const doCron = !!cron && !!enviado && enviado.length === cron.length && enviado === cron
  if (!doCron && !(await requireOwnerOrServer(req, db))) return json({ error: 'Não autorizado.' }, 401)

  const pixel = Deno.env.get('META_PIXEL_ID')
  const token = Deno.env.get('META_CAPI_TOKEN')
  if (!pixel || !token) return json({ ok: true, configurado: false })
  const { data: cfg } = await db.from('app_settings').select('value').eq('key', 'meta_capi').maybeSingle()
  const c = (cfg?.value ?? {}) as { ligado?: boolean; test_event_code?: string | null }
  if (c.ligado === false) return json({ ok: true, desligado: true })

  const { data: lote, error } = await db.rpc('meta_eventos_lote', { p_n: 500 })
  if (error) return json({ error: 'Não foi possível ler a fila.' }, 500)
  const eventos = (lote ?? []) as EventoFila[]
  if (!eventos.length) return json({ ok: true, enviados: 0 })
  const ids = eventos.map((e) => e.id)
  try {
    const res = await fetch(`https://graph.facebook.com/${VERSAO}/${pixel}/events?access_token=${encodeURIComponent(token)}`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(corpoMeta(eventos, c.test_event_code)),
    })
    const r = await res.json().catch(() => ({})) as { events_received?: number; error?: { message?: string; code?: number } }
    if (!res.ok) {
      await db.rpc('meta_eventos_resultado', { p_ids: ids, p_ok: false, p_erro: `${res.status} ${r.error?.code ?? ''} ${r.error?.message ?? ''}`.trim() })
      console.error('meta-conversions-api: recusado', res.status, r.error?.code)
      return json({ error: 'A Meta recusou o lote.', status: res.status }, 502)
    }
    await db.rpc('meta_eventos_resultado', { p_ids: ids, p_ok: true })
    console.log(`meta-conversions-api: ${r.events_received ?? ids.length} eventos recebidos`)
    return json({ ok: true, enviados: r.events_received ?? ids.length })
  } catch {
    await db.rpc('meta_eventos_resultado', { p_ids: ids, p_ok: false, p_erro: 'falha de rede' })
    return json({ error: 'Falha de rede com a Meta.' }, 502)
  }
})
