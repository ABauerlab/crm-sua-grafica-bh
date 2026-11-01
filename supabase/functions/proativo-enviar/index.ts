import { corsHeaders, json, requireEnv, requireServiceRole, serviceClient } from '../_shared/http.ts'
import { enviarTemplate, enviarTexto, statusTemplate, type WaEnv } from '../_shared/wapp.ts'
import { decidirEnvio, erroPermanente, janelaAberta, limparParametro } from '../_shared/proativo.ts'

// Envio proativo (follow-ups, pós-venda e avisos de status): só a service role (WF6, WF7, WF8 do n8n). O token da Meta fica só aqui.
// Texto livre apenas com a janela de 24 h aberta; senão template aprovado. Marketing exige opt-in; contato de teste nunca vai à Meta.
// A reserva (sem duplicar) e o registro do resultado são do banco (followup_* e pedido_aviso_*); esta função só envia e grava a mensagem.
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)
  if (!(await requireServiceRole(req))) return json({ error: 'Não autorizado.' }, 401)
  const env = requireEnv('WHATSAPP_TOKEN', 'WHATSAPP_PHONE_NUMBER_ID') as WaEnv | null
  if (!env) return json({ error: 'Integração com o WhatsApp não configurada no servidor.' }, 500)
  env.WHATSAPP_WABA_ID = Deno.env.get('WHATSAPP_WABA_ID') ?? undefined

  const input = (await req.json().catch(() => ({}))) as { conversation_id?: string; via?: string; texto?: string; template?: string | null; params?: unknown[] | null }
  if (!UUID.test(String(input.conversation_id ?? ''))) return json({ error: 'conversation_id inválido.' }, 400)
  const via = input.via === 'template' ? 'template' : 'livre'
  const texto = String(input.texto ?? '').trim()
  const template = input.template ? String(input.template) : null
  if (!texto) return json({ error: 'Texto vazio.' }, 400)
  if (texto.length > 1500) return json({ error: 'Texto longo demais (limite de 1500 caracteres).' }, 400)

  const db = serviceClient()
  const { data: conv } = await db
    .from('conversations')
    .select('id, last_inbound_at, contact:contacts(wa_id, optout, marketing_consent, tags)')
    .eq('id', input.conversation_id)
    .maybeSingle()
  // deno-lint-ignore no-explicit-any
  const ct = (conv as any)?.contact as { wa_id: string; optout: boolean; marketing_consent: string; tags: string[] | null } | undefined
  if (!conv || !ct?.wa_id) return json({ error: 'Conversa não encontrada.' }, 404)
  if ((ct.tags ?? []).includes('teste')) return json({ ok: true, simulado: true, via: 'simulado' })

  const { data: cfgRow } = await db.from('app_settings').select('value').eq('key', 'followup').maybeSingle()
  const exigirOptin = (cfgRow?.value as { exigir_optin_marketing?: boolean } | null)?.exigir_optin_marketing !== false

  let categoria: string | null = null
  if (template) {
    const { data: tpl } = await db.from('templates_cache').select('category').eq('name', template).eq('language', 'pt_BR').maybeSingle()
    categoria = (tpl?.category as string | null) ?? null
  }
  const decisao = decidirEnvio({
    via, janelaAberta: janelaAberta(conv.last_inbound_at), temTemplate: !!template, categoria,
    optout: !!ct.optout, consentimento: ct.marketing_consent, exigirOptin,
  })
  if (decisao.acao === 'recusar') return json({ ok: false, recusado: true, motivo: decisao.motivo, permanente: decisao.permanente })

  let usado: 'livre' | 'template' = decisao.acao
  let corpo = texto
  let r = { ok: false, wa_message_id: undefined as string | undefined, codigo: null as number | null | undefined, erro: undefined as string | undefined }

  if (usado === 'livre') {
    r = await enviarTexto(env, ct.wa_id, texto)
    // a janela pode ter fechado no meio do caminho (131047): tenta o template se houver
    if (!r.ok && r.codigo === 131047 && template) usado = 'template'
  }
  if (usado === 'template' && template) {
    const st = await statusTemplate(env, db, template)
    if (st && st !== 'APPROVED') {
      return json({ ok: false, permanente: false, motivo: `template_${st.toLowerCase()}`, error: `O template ${template} ainda não está aprovado na Meta (${st}).` })
    }
    const params = (input.params ?? []).map(limparParametro)
    r = await enviarTemplate(env, ct.wa_id, template, params)
    const { data: tpl } = await db.from('templates_cache').select('body').eq('name', template).eq('language', 'pt_BR').maybeSingle()
    corpo = (tpl?.body ? String(tpl.body).replace(/\{\{(\d+)\}\}/g, (_m: string, n: string) => params[Number(n) - 1] ?? '') : texto)
  }
  if (!r.ok) return json({ ok: false, permanente: erroPermanente(r.codigo), motivo: r.erro ?? 'falha', meta_code: r.codigo ?? null })

  const now = new Date().toISOString()
  const { error: insErr } = await db.from('messages').insert({
    conversation_id: conv.id, wa_message_id: r.wa_message_id ?? null, direction: 'out', type: usado === 'template' ? 'template' : 'text', body: corpo,
    template_name: usado === 'template' ? template : null, status: 'sent', created_at: now,
  })
  if (insErr) console.error('Mensagem proativa enviada, mas falhou ao gravar:', insErr.message)
  await db.from('conversations').update({ last_message_at: now, last_message_preview: corpo.slice(0, 120) }).eq('id', conv.id)
  return json({ ok: true, via: usado, wa_message_id: r.wa_message_id ?? null })
})
