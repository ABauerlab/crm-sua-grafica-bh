import { corsHeaders, json, requireEnv, requireStaff, serviceClient } from '../_shared/http.ts'

const WINDOW_MS = 24 * 60 * 60 * 1000
const GRAPH = 'https://graph.facebook.com/v21.0'

interface SendBody {
  conversation_id?: string
  text?: string
  template_name?: string
  language?: string
  variables?: string[]
}

const META_ERRORS: Record<number, string> = {
  131047: 'A janela de 24h está fechada. Envie um template aprovado.',
  131026: 'Mensagem não entregue: o número pode não ter WhatsApp.',
  131030: 'Número fora da lista de destinatários permitidos (modo de teste da Meta).',
  132000: 'Quantidade de variáveis do template não confere com o modelo aprovado.',
  132001: 'Template não encontrado ou não aprovado nesse idioma.',
  190: 'Token do WhatsApp inválido ou expirado. Avise o administrador.',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)

  const db = serviceClient()
  const staff = await requireStaff(req, db)
  if (!staff) return json({ error: 'Não autorizado.' }, 401)

  const env = requireEnv('WHATSAPP_TOKEN', 'WHATSAPP_PHONE_NUMBER_ID')
  if (!env) return json({ error: 'Integração com o WhatsApp não configurada no servidor.' }, 500)

  let input: SendBody
  try {
    input = await req.json()
  } catch {
    return json({ error: 'Corpo da requisição inválido.' }, 400)
  }

  const text = input.text?.trim()
  const templateName = input.template_name?.trim()
  if (!input.conversation_id) return json({ error: 'conversation_id é obrigatório.' }, 400)
  if (!text && !templateName) return json({ error: 'Informe o texto ou o template.' }, 400)
  if (text && templateName) return json({ error: 'Envie texto ou template, não os dois.' }, 400)
  if (text && text.length > 4096) return json({ error: 'Texto acima de 4096 caracteres.' }, 400)

  const { data: conv } = await db
    .from('conversations')
    .select('id, last_inbound_at, contact:contacts(wa_id, marketing_consent)')
    .eq('id', input.conversation_id)
    .maybeSingle()
  // deno-lint-ignore no-explicit-any
  const waId = (conv as any)?.contact?.wa_id as string | undefined
  // deno-lint-ignore no-explicit-any
  const consent = (conv as any)?.contact?.marketing_consent as string | undefined
  if (!conv || !waId) return json({ error: 'Conversa não encontrada.' }, 404)

  let metaBody: Record<string, unknown>
  let storedBody: string
  let language = input.language

  if (text) {
    const open = conv.last_inbound_at && Date.now() - new Date(conv.last_inbound_at).getTime() < WINDOW_MS
    if (!open) {
      return json({ error: 'A janela de 24h está fechada. Envie um template aprovado.', code: 'window_closed' }, 409)
    }
    metaBody = { messaging_product: 'whatsapp', to: waId, type: 'text', text: { body: text, preview_url: false } }
    storedBody = text
  } else {
    const vars = (input.variables ?? []).map((v) => String(v))
    if (vars.some((v) => !v.trim())) return json({ error: 'Preencha todas as variáveis do template.' }, 400)

    let q = db.from('templates_cache').select('name, language, status, category, body').eq('name', templateName!)
    if (language) q = q.eq('language', language)
    const { data: tpl } = await q.limit(1).maybeSingle()
    if (!tpl) return json({ error: 'Template não encontrado. Sincronize os templates e tente de novo.' }, 404)
    if (tpl.status !== 'APPROVED') return json({ error: 'Esse template ainda não foi aprovado pela Meta.' }, 409)
    // Promoções só para quem autorizou; mensagens de pedido (utility) não dependem disso
    if (tpl.category === 'MARKETING' && consent !== 'opted_in') {
      return json(
        {
          error:
            consent === 'opted_out'
              ? 'Este contato pediu para não receber promoções. Use um template de utilidade (ex.: atualização de pedido).'
              : 'Este contato ainda não autorizou receber promoções. Registre o consentimento no painel do contato.',
          code: 'no_marketing_consent',
        },
        403,
      )
    }
    language = tpl.language

    metaBody = {
      messaging_product: 'whatsapp',
      to: waId,
      type: 'template',
      template: {
        name: tpl.name,
        language: { code: tpl.language },
        ...(vars.length
          ? { components: [{ type: 'body', parameters: vars.map((v) => ({ type: 'text', text: v })) }] }
          : {}),
      },
    }
    // Corpo legível para exibir no chat
    storedBody = (tpl.body ?? `[template ${tpl.name}]`).replace(/\{\{(\d+)\}\}/g, (_m: string, n: string) => vars[Number(n) - 1] ?? '')
  }

  let res: Response
  try {
    res = await fetch(`${GRAPH}/${env.WHATSAPP_PHONE_NUMBER_ID}/messages`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${env.WHATSAPP_TOKEN}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(metaBody),
    })
  } catch {
    return json({ error: 'Não foi possível falar com a API do WhatsApp. Tente novamente.' }, 502)
  }

  const result = await res.json().catch(() => ({}))
  if (!res.ok) {
    const code = Number(result?.error?.code)
    const detail = result?.error?.error_data?.details ?? result?.error?.message ?? 'erro desconhecido'
    console.error('Erro da Meta ao enviar:', code, detail)
    return json({ error: META_ERRORS[code] ?? `A Meta recusou o envio: ${detail}`, meta_code: code || null }, 502)
  }

  const waMessageId = result?.messages?.[0]?.id as string | undefined
  const now = new Date().toISOString()
  const { error: insErr } = await db.from('messages').insert({
    conversation_id: conv.id,
    wa_message_id: waMessageId ?? null,
    direction: 'out',
    type: text ? 'text' : 'template',
    body: storedBody,
    template_name: text ? null : templateName,
    status: 'sent',
    created_at: now,
  })
  if (insErr) {
    console.error('Mensagem enviada, mas falhou ao gravar:', insErr.message)
    return json({ error: 'Mensagem enviada ao WhatsApp, mas não foi possível registrá-la no CRM.' }, 500)
  }

  await db
    .from('conversations')
    .update({ last_message_at: now, last_message_preview: storedBody.slice(0, 120) })
    .eq('id', conv.id)

  return json({ ok: true, wa_message_id: waMessageId ?? null })
})
