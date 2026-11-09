// Receptor de avisos do Bling (pedidos vindos de marketplaces). Fase 6: só confere a assinatura e GRAVA o evento em bling_eventos.
// O processamento (criar pedido no CRM com o canal de origem) só liga com app_settings.bling.webhook_processar = true, em fase futura.
import { json, serviceClient } from '../_shared/http.ts'
import { assinaturaBlingValida, resumoEventoBling } from '../_shared/bling.ts'

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)
  const corpo = await req.text()
  if (corpo.length > 512_000) return json({ error: 'Aviso grande demais.' }, 413)
  const ok = await assinaturaBlingValida(corpo, req.headers.get('x-bling-signature-256'), Deno.env.get('BLING_CLIENT_SECRET'))
  if (!ok) return json({ error: 'Assinatura inválida.' }, 401)
  let payload: Record<string, unknown>
  try {
    payload = JSON.parse(corpo)
  } catch {
    return json({ error: 'Corpo inválido.' }, 400)
  }
  const r = resumoEventoBling(payload)
  const db = serviceClient()
  // aviso repetido (mesmo evento, recurso e corpo) cai no índice único e é ignorado
  const { error } = await db.from('bling_eventos').insert({ evento: r.evento, recurso_id: r.recurso_id, assinatura_ok: true, payload })
  if (error && error.code !== '23505') {
    console.error('bling-webhook: falha ao gravar', error.code)
    return json({ error: 'Falha ao gravar.' }, 500)
  }
  console.log(`bling-webhook: evento ${r.evento} recebido`)
  return json({ ok: true })
})
