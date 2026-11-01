import { corsHeaders, json, requireEnv, requireServiceRole, serviceClient } from '../_shared/http.ts'
import { janelaAberta, montarConfirmacaoCliente, templateConfirmacaoCliente } from '../_shared/alertas.ts'
import { enviarTemplate, enviarTexto, statusTemplate, type WaEnv } from '../_shared/wapp.ts'

// WF5: UMA mensagem ao cliente depois do pagamento confirmado. Texto livre se a janela de 24 h estiver aberta, senão o template
// pedido_pago_confirmacao. Só a service role chama. O banco reserva o envio (sem duplicar) e conta as tentativas (máximo 3).
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)
  if (!(await requireServiceRole(req))) return json({ error: 'Não autorizado.' }, 401)
  const env = requireEnv('WHATSAPP_TOKEN', 'WHATSAPP_PHONE_NUMBER_ID') as WaEnv | null
  if (!env) return json({ error: 'Integração com o WhatsApp não configurada no servidor.' }, 500)
  env.WHATSAPP_WABA_ID = Deno.env.get('WHATSAPP_WABA_ID') ?? undefined

  const input = (await req.json().catch(() => ({}))) as { order_id?: string }
  if (!UUID.test(String(input.order_id ?? ''))) return json({ error: 'order_id inválido.' }, 400)

  const db = serviceClient()
  const { data: r, error } = await db.rpc('pagamento_pos_reservar_msg', { p_order: input.order_id })
  if (error) return json({ error: 'Não foi possível reservar o envio.' }, 500)
  if (!r?.enviar) return json({ ok: true, enviado: false, msg_status: r?.msg_status ?? null })

  const dados = { nome: r.nome as string, pedido: r.pedido as string, previsao: r.previsao as string, arte_status: r.arte_status, entrega: r.entrega, persona: (r.persona as string | undefined) ?? null, artigo: (r.artigo as string | undefined) ?? null }
  let corpo = ''
  let tipo: 'text' | 'template' = 'text'
  let envio = { ok: false, wa_message_id: undefined as string | undefined, erro: undefined as string | undefined }

  if (janelaAberta(r.janela_ate)) {
    corpo = montarConfirmacaoCliente(dados)
    const x = await enviarTexto(env, r.wa_id, corpo)
    envio = { ok: x.ok, wa_message_id: x.wa_message_id, erro: x.erro }
  }
  if (!envio.ok) {
    const st = await statusTemplate(env, db, 'pedido_pago_confirmacao')
    if (st && st !== 'APPROVED') {
      await db.rpc('pagamento_pos_msg_resultado', { p_order: input.order_id, p_status: 'falhou_temp', p_erro: `template pedido_pago_confirmacao: ${st}` })
      return json({ ok: false, error: 'O template pedido_pago_confirmacao ainda não foi aprovado pela Meta.' }, 409)
    }
    const params = templateConfirmacaoCliente(dados)
    const x = await enviarTemplate(env, r.wa_id, 'pedido_pago_confirmacao', params)
    envio = { ok: x.ok, wa_message_id: x.wa_message_id, erro: x.erro }
    tipo = 'template'
    const { data: tpl } = await db.from('templates_cache').select('body').eq('name', 'pedido_pago_confirmacao').eq('language', 'pt_BR').maybeSingle()
    corpo = (tpl?.body ?? 'Pagamento confirmado, {{1}}! Seu pedido {{2}} já entrou na fila. Previsão de ficar pronto: {{3}}.').replace(/\{\{(\d+)\}\}/g, (_m: string, n: string) => params[Number(n) - 1] ?? '')
  }

  if (!envio.ok) {
    await db.rpc('pagamento_pos_msg_resultado', { p_order: input.order_id, p_status: 'falhou_temp', p_erro: envio.erro ?? 'erro' })
    return json({ ok: false, error: 'Não foi possível enviar a confirmação ao cliente agora.' }, 502)
  }

  const now = new Date().toISOString()
  await db.from('messages').insert({
    conversation_id: r.conversation_id, wa_message_id: envio.wa_message_id ?? null, direction: 'out', type: tipo, body: corpo,
    template_name: tipo === 'template' ? 'pedido_pago_confirmacao' : null, status: 'sent', created_at: now,
  })
  await db.from('conversations').update({ last_message_at: now, last_message_preview: corpo.slice(0, 120) }).eq('id', r.conversation_id)
  await db.rpc('pagamento_pos_msg_resultado', { p_order: input.order_id, p_status: 'enviado' })
  return json({ ok: true, enviado: true, via: tipo })
})
