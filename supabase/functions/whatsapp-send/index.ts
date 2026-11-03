import { corsHeaders, json, requireEnv, requireStaff, serviceClient } from '../_shared/http.ts'

const WINDOW_MS = 24 * 60 * 60 * 1000
const GRAPH = 'https://graph.facebook.com/v21.0'
const MAX_ANEXO = 16 * 1024 * 1024

type Tipo = 'image' | 'video' | 'audio' | 'document' | 'sticker'
/** Formatos que a API oficial aceita (tipo normalizado -> como enviar e limite de tamanho). */
const ANEXOS: Record<string, { tipo: Tipo; max: number }> = {
  'image/jpeg': { tipo: 'image', max: 5 * 1024 * 1024 },
  'image/png': { tipo: 'image', max: 5 * 1024 * 1024 },
  'image/webp': { tipo: 'sticker', max: 500 * 1024 },
  'video/mp4': { tipo: 'video', max: MAX_ANEXO },
  'video/3gpp': { tipo: 'video', max: MAX_ANEXO },
  'audio/aac': { tipo: 'audio', max: MAX_ANEXO },
  'audio/mp4': { tipo: 'audio', max: MAX_ANEXO },
  'audio/mpeg': { tipo: 'audio', max: MAX_ANEXO },
  'audio/amr': { tipo: 'audio', max: MAX_ANEXO },
  'audio/ogg': { tipo: 'audio', max: MAX_ANEXO },
  'application/pdf': { tipo: 'document', max: MAX_ANEXO },
  'application/msword': { tipo: 'document', max: MAX_ANEXO },
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document': { tipo: 'document', max: MAX_ANEXO },
  'application/vnd.ms-excel': { tipo: 'document', max: MAX_ANEXO },
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': { tipo: 'document', max: MAX_ANEXO },
  'application/vnd.ms-powerpoint': { tipo: 'document', max: MAX_ANEXO },
  'application/vnd.openxmlformats-officedocument.presentationml.presentation': { tipo: 'document', max: MAX_ANEXO },
  'text/plain': { tipo: 'document', max: MAX_ANEXO },
}

interface SendBody {
  conversation_id?: string
  text?: string
  template_name?: string
  language?: string
  variables?: string[]
  /** wa_message_id da mensagem respondida (aparece como resposta no celular do cliente) */
  reply_to?: string
  /** delete | restore | react (ações sobre uma mensagem) */
  action?: 'delete' | 'restore' | 'react'
  message_id?: string
  emoji?: string
}

const META_ERRORS: Record<number, string> = {
  131047: 'A janela de 24h está fechada. Envie um template aprovado.',
  131026: 'Mensagem não entregue: o número pode não ter WhatsApp.',
  131030: 'Número fora da lista de destinatários permitidos (modo de teste da Meta).',
  132000: 'Quantidade de variáveis do template não confere com o modelo aprovado.',
  132001: 'Template não encontrado ou não aprovado nesse idioma.',
  131053: 'A Meta não aceitou o arquivo (formato ou tamanho).',
  190: 'Token do WhatsApp inválido ou expirado. Avise o administrador.',
}
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)

  const db = serviceClient()
  const staff = await requireStaff(req, db)
  if (!staff) return json({ error: 'Não autorizado.' }, 401)

  const env = requireEnv('WHATSAPP_TOKEN', 'WHATSAPP_PHONE_NUMBER_ID')
  if (!env) return json({ error: 'Integração com o WhatsApp não configurada no servidor.' }, 500)

  let input: SendBody
  let file: File | null = null
  try {
    if ((req.headers.get('content-type') ?? '').includes('multipart/form-data')) {
      const form = await req.formData()
      const f = form.get('file')
      file = f instanceof File ? f : null
      input = {
        conversation_id: String(form.get('conversation_id') ?? ''),
        text: String(form.get('caption') ?? ''),
        reply_to: String(form.get('reply_to') ?? '') || undefined,
      }
      if (!file) return json({ error: 'Anexe um arquivo.' }, 400)
    } else {
      input = await req.json()
    }
  } catch {
    return json({ error: 'Corpo da requisição inválido.' }, 400)
  }

  // ---- ações sobre uma mensagem já existente (apagar no CRM, restaurar, reagir)
  if (input.action === 'delete' || input.action === 'restore') {
    if (!UUID.test(input.message_id ?? '')) return json({ error: 'Mensagem inválida.' }, 400)
    const patch = input.action === 'delete' ? { deleted_at: new Date().toISOString(), deleted_by: staff.userId } : { deleted_at: null, deleted_by: null }
    const { data, error } = await db.from('messages').update(patch).eq('id', input.message_id!).select('id').maybeSingle()
    if (error || !data) return json({ error: 'Mensagem não encontrada.' }, 404)
    // a API oficial do WhatsApp não apaga mensagens já entregues: aqui só escondemos no CRM
    return json({ ok: true, escopo: 'crm' })
  }

  const text = input.text?.trim()
  const templateName = input.template_name?.trim()
  if (!input.conversation_id) return json({ error: 'conversation_id é obrigatório.' }, 400)
  if (input.action === 'react') {
    if (!input.message_id) return json({ error: 'Informe a mensagem.' }, 400)
  } else if (!text && !templateName && !file) return json({ error: 'Informe o texto ou o template.' }, 400)
  if (text && templateName) return json({ error: 'Envie texto ou template, não os dois.' }, 400)
  if (text && text.length > 4096) return json({ error: 'Texto acima de 4096 caracteres.' }, 400)

  let mime = ''
  if (file) {
    mime = (file.type || '').split(';')[0].trim().toLowerCase()
    const regra = ANEXOS[mime]
    if (!regra) return json({ error: 'Tipo de arquivo não aceito pelo WhatsApp. Envie imagem (JPG, PNG), vídeo (MP4), áudio (MP3, OGG, M4A, AAC, AMR) ou documento (PDF, Word, Excel, PowerPoint, TXT).' }, 400)
    if (file.size > regra.max) return json({ error: `O arquivo passa de ${Math.round(regra.max / 1024 / 1024 * 10) / 10} MB, o limite para este tipo.` }, 400)
    if (regra.tipo === 'audio' && text) return json({ error: 'Áudio não aceita legenda. Envie o texto em outra mensagem.' }, 400)
    if (regra.tipo === 'sticker' && text) return json({ error: 'Figurinha não aceita legenda.' }, 400)
  }

  const { data: conv } = await db
    .from('conversations')
    .select('id, last_inbound_at, ad_window_until, contact:contacts(wa_id, marketing_consent)')
    .eq('id', input.conversation_id)
    .maybeSingle()
  // deno-lint-ignore no-explicit-any
  const waId = (conv as any)?.contact?.wa_id as string | undefined
  // deno-lint-ignore no-explicit-any
  const consent = (conv as any)?.contact?.marketing_consent as string | undefined
  if (!conv || !waId) return json({ error: 'Conversa não encontrada.' }, 404)

  const until = Math.max(
    conv.last_inbound_at ? new Date(conv.last_inbound_at).getTime() + WINDOW_MS : 0,
    conv.ad_window_until ? new Date(conv.ad_window_until).getTime() : 0,
  )
  const janelaAberta = until > Date.now()

  // resposta a uma mensagem: precisa ser desta conversa
  let replyTo: string | null = null
  if (input.reply_to) {
    const { data: alvo } = await db.from('messages').select('wa_message_id').eq('wa_message_id', input.reply_to).eq('conversation_id', conv.id).maybeSingle()
    replyTo = alvo?.wa_message_id ?? null
  }
  const contexto = replyTo ? { context: { message_id: replyTo } } : {}

  let metaBody: Record<string, unknown>
  let storedBody: string
  let language = input.language
  let mediaId: string | null = null
  let tipoMsg: 'text' | 'template' | 'document' | 'image' | 'video' | 'audio' | 'sticker' | 'reaction' = text ? 'text' : 'template'
  let metaMsg: Record<string, unknown> | null = null

  if (input.action === 'react') {
    if (!janelaAberta) return json({ error: 'A janela de atendimento está fechada. Não dá para reagir agora.', code: 'window_closed' }, 409)
    const { data: alvo } = await db.from('messages').select('wa_message_id').eq('id', input.message_id!).eq('conversation_id', conv.id).maybeSingle()
    if (!alvo?.wa_message_id) return json({ error: 'Mensagem não encontrada.' }, 404)
    const emoji = (input.emoji ?? '').slice(0, 8)
    metaBody = { messaging_product: 'whatsapp', to: waId, type: 'reaction', reaction: { message_id: alvo.wa_message_id, emoji } }
    tipoMsg = 'reaction'
    storedBody = emoji
    metaMsg = { alvo: alvo.wa_message_id }
  } else if (file) {
    // anexo: só dentro da janela (mídia é mensagem livre). Sobe para a Meta e envia pelo id, sem guardar o arquivo no CRM.
    if (!janelaAberta) return json({ error: 'A janela de atendimento está fechada. Envie um template aprovado.', code: 'window_closed' }, 409)
    const up = new FormData()
    up.append('messaging_product', 'whatsapp')
    up.append('type', mime)
    up.append('file', new File([file], file.name, { type: mime }), file.name)
    let upRes: Response
    try {
      upRes = await fetch(`${GRAPH}/${env.WHATSAPP_PHONE_NUMBER_ID}/media`, { method: 'POST', headers: { Authorization: `Bearer ${env.WHATSAPP_TOKEN}` }, body: up })
    } catch {
      return json({ error: 'Não foi possível falar com a API do WhatsApp. Tente novamente.' }, 502)
    }
    const upJson = await upRes.json().catch(() => ({}))
    if (!upRes.ok || !upJson?.id) {
      console.error('Erro da Meta ao subir o anexo:', upJson?.error?.code)
      return json({ error: 'A Meta recusou o arquivo. Confira o tipo e o tamanho.' }, 502)
    }
    mediaId = String(upJson.id)
    tipoMsg = ANEXOS[mime].tipo
    const nome = file.name.replace(/[^\w.\- ()]/g, '_').slice(0, 100) || 'arquivo'
    const legenda = text ? { caption: text.slice(0, 1000) } : {}
    const corpo: Record<string, unknown> =
      tipoMsg === 'document' ? { id: mediaId, filename: nome, ...legenda } : tipoMsg === 'image' || tipoMsg === 'video' ? { id: mediaId, ...legenda } : { id: mediaId }
    metaBody = { messaging_product: 'whatsapp', to: waId, type: tipoMsg, [tipoMsg]: corpo, ...contexto }
    storedBody = tipoMsg === 'document' ? (text ? `${nome}\n${text}` : nome) : text || ''
    metaMsg = { filename: nome, mime_type: mime, tamanho: file.size }
  } else if (text) {
    if (!janelaAberta) return json({ error: 'A janela de atendimento está fechada. Envie um template aprovado.', code: 'window_closed' }, 409)
    metaBody = { messaging_product: 'whatsapp', to: waId, type: 'text', text: { body: text, preview_url: false }, ...contexto }
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
      ...contexto,
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
    type: tipoMsg,
    media_id: mediaId,
    body: storedBody,
    template_name: tipoMsg === 'template' ? templateName : null,
    reply_to_wa_id: replyTo,
    meta: metaMsg,
    sent_by: staff.userId,
    status: 'sent',
    created_at: now,
  })
  if (insErr) {
    console.error('Mensagem enviada, mas falhou ao gravar:', insErr.message)
    return json({ error: 'Mensagem enviada ao WhatsApp, mas não foi possível registrá-la no CRM.' }, 500)
  }

  if (tipoMsg !== 'reaction') {
    const previa = storedBody || { image: '[imagem]', video: '[vídeo]', audio: '[áudio]', sticker: '[figurinha]', document: '[documento]' }[tipoMsg as string] || ''
    await db.from('conversations').update({ last_message_at: now, last_message_preview: String(previa).slice(0, 120) }).eq('id', conv.id)
  }

  return json({ ok: true, wa_message_id: waMessageId ?? null })
})
