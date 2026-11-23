// E-commerce Fase 7: envia a fila meta_eventos para a Conversions API da Meta (deduplicada com o Pixel pelo event_id).
// Chamada pelo agendamento (x-cron-secret) ou pelo dono/service role. Sem META_PIXEL_ID e META_CAPI_TOKEN não consome a fila
// e avisa o dono uma vez por dia (Fase 1 do Plano de Ação: antes o retorno era silencioso e a fila nunca era conferida).
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

  const body = await req.json().catch(() => ({})) as { acao?: string; criar?: boolean }
  // O WhatsApp tem dataset próprio (GET /{WABA}/dataset). A rotina só LÊ; criar exige body.criar = true, pedido de propósito.
  if (body.acao === 'dataset_whatsapp') {
    const wabaId = Deno.env.get('WHATSAPP_WABA_ID')
    if (!wabaId) return json({ error: 'Falta o segredo WHATSAPP_WABA_ID.' }, 400)
    const detalhe: string[] = []
    for (const nome of ['META_CAPI_TOKEN', 'WHATSAPP_TOKEN']) {
      const t = Deno.env.get(nome)
      if (!t) continue
      try {
        const res = await fetch(`https://graph.facebook.com/${VERSAO}/${wabaId}/dataset?access_token=${encodeURIComponent(t)}`, body.criar ? { method: 'POST' } : undefined)
        const r = await res.json().catch(() => ({})) as { id?: string; data?: { id?: string }[]; error?: { message?: string; code?: number; error_subcode?: number } }
        const id = r.id ?? r.data?.[0]?.id
        if (res.ok && id) {
          const { data: atual } = await db.from('app_settings').select('value').eq('key', 'meta_capi').maybeSingle()
          await db.from('app_settings').update({ value: { ...((atual?.value ?? {}) as Record<string, unknown>), dataset_whatsapp: id, token_whatsapp: nome } }).eq('key', 'meta_capi')
          return json({ ok: true, dataset_id: id, token: nome })
        }
        detalhe.push(`${nome}: ${res.status} ${r.error?.code ?? ''} ${r.error?.error_subcode ?? ''} ${r.error?.message ?? 'a conta não tem dataset'}`.slice(0, 220))
      } catch { detalhe.push(`${nome}: falha de rede`) }
    }
    return json({ ok: false, detalhe })
  }

  const pixel = Deno.env.get('META_PIXEL_ID')
  const token = Deno.env.get('META_CAPI_TOKEN')
  if (!pixel || !token) {
    const { count } = await db.from('meta_eventos').select('id', { count: 'exact', head: true }).eq('status', 'pendente')
    const hoje = new Date().toISOString().slice(0, 10)
    const faltando = [!pixel && 'META_PIXEL_ID', !token && 'META_CAPI_TOKEN'].filter(Boolean).join(' e ')
    await db.rpc('alerta_criar', {
      p_tipo: 'meta_capi_sem_segredo', p_gravidade: 'alta', p_contact: null, p_conversation: null, p_order: null,
      p_motivo: `A Conversions API da Meta está sem ${faltando}: ${count ?? 0} eventos de venda parados na fila, sem chegar à Meta. Cadastre o(s) segredo(s) nas Secrets das Edge Functions do Supabase.`,
      p_dados: { pendentes: count ?? 0, faltando: faltando }, p_chave: `meta_capi_sem_segredo:${hoje}`, p_canais: ['whatsapp'],
    }).then(({ error }) => { if (error) console.error('meta-conversions-api: alerta falhou', error.message) })
    return json({ ok: true, configurado: false })
  }
  const { data: cfg } = await db.from('app_settings').select('value').eq('key', 'meta_capi').maybeSingle()
  const c = (cfg?.value ?? {}) as { ligado?: boolean; test_event_code?: string | null; dataset_whatsapp?: string; token_whatsapp?: string }
  if (c.ligado === false) return json({ ok: true, desligado: true })

  const { data: lote, error } = await db.rpc('meta_eventos_lote', { p_n: 500 })
  if (error) return json({ error: 'Não foi possível ler a fila.' }, 500)
  const todos = (lote ?? []) as EventoFila[]
  if (!todos.length) return json({ ok: true, enviados: 0 })
  // Business Messaging exige o WABA; sem ele o evento volta para a fila com o motivo, sem ir quebrado para a Meta.
  const waba = Deno.env.get('WHATSAPP_WABA_ID') || null
  const semWaba = waba ? [] : todos.filter((e) => e.action_source === 'business_messaging')
  if (semWaba.length) await db.rpc('meta_eventos_resultado', { p_ids: semWaba.map((e) => e.id), p_ok: false, p_erro: 'sem WHATSAPP_WABA_ID' })
  const eventos = todos.filter((e) => !semWaba.includes(e))
  if (!eventos.length) return json({ ok: true, enviados: 0, sem_waba: semWaba.length })
  // Chat (Business Messaging) e site vão em pedidos separados: um evento recusado de um lado não derruba o outro.
  const grupos = [eventos.filter((e) => e.action_source !== 'business_messaging'), eventos.filter((e) => e.action_source === 'business_messaging')].filter((g) => g.length)
  let enviados = 0
  let falhas = 0
  for (const g of grupos) {
    const ids = g.map((e) => e.id)
    try {
      const res = await fetch(`https://graph.facebook.com/${VERSAO}/${pixel}/events?access_token=${encodeURIComponent(token)}`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(corpoMeta(g, c.test_event_code, waba)),
      })
      const r = await res.json().catch(() => ({})) as { events_received?: number; error?: { message?: string; code?: number } }
      if (!res.ok) {
        falhas++
        await db.rpc('meta_eventos_resultado', { p_ids: ids, p_ok: false, p_erro: `${res.status} ${r.error?.code ?? ''} ${r.error?.message ?? ''}`.trim() })
        console.error('meta-conversions-api: recusado', res.status, r.error?.code)
        continue
      }
      await db.rpc('meta_eventos_resultado', { p_ids: ids, p_ok: true })
      enviados += r.events_received ?? ids.length
    } catch {
      falhas++
      await db.rpc('meta_eventos_resultado', { p_ids: ids, p_ok: false, p_erro: 'falha de rede' })
    }
  }
  console.log(`meta-conversions-api: ${enviados} eventos recebidos, ${falhas} lotes com falha`)
  if (falhas && !enviados) return json({ error: 'A Meta recusou o lote.' }, 502)
  return json({ ok: true, enviados, lotes_com_falha: falhas })
})
