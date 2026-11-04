import { corsHeaders, json, requireEnv, requireServiceRole, serviceClient } from '../_shared/http.ts'

// Envio de texto do agente (n8n, service role). O token da Meta fica só aqui.
// Antes de enviar, o banco confere (agente_pode_enviar): IA ligada, conversa em modo IA, sem pedido pago e sem optout.
// Só texto livre dentro da janela de 24 h (72 h para conversa vinda de anúncio). Template não é papel do agente.
// Texto acima de 1.500 caracteres é quebrado automaticamente em mensagens sequenciais (orçamentos compostos),
// até o teto de 6.000 caracteres por envio. Acima disso, responde 400 com mensagem clara.
const WINDOW_MS = 24 * 60 * 60 * 1000
const GRAPH = 'https://graph.facebook.com/v21.0'
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const LIMITE_PARTE = 1500
const LIMITE_TOTAL = 6000

/** Quebra o texto em partes de até LIMITE_PARTE, preferindo parágrafo, depois linha, depois espaço. */
function partir(texto: string): string[] {
  if (texto.length <= LIMITE_PARTE) return [texto]
  const partes: string[] = []
  let resto = texto
  while (resto.length > LIMITE_PARTE) {
    let corte = resto.lastIndexOf('\n\n', LIMITE_PARTE)
    if (corte < LIMITE_PARTE / 2) corte = resto.lastIndexOf('\n', LIMITE_PARTE)
    if (corte < LIMITE_PARTE / 2) corte = resto.lastIndexOf(' ', LIMITE_PARTE)
    if (corte < 1) corte = LIMITE_PARTE
    partes.push(resto.slice(0, corte).trim())
    resto = resto.slice(corte).trim()
  }
  if (resto) partes.push(resto)
  return partes.filter(Boolean)
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)
  if (!(await requireServiceRole(req))) return json({ error: 'Não autorizado.' }, 401)

  const env = requireEnv('WHATSAPP_TOKEN', 'WHATSAPP_PHONE_NUMBER_ID')
  if (!env) return json({ error: 'Integração com o WhatsApp não configurada no servidor.' }, 500)

  const input = (await req.json().catch(() => ({}))) as { conversation_id?: string; text?: string }
  const text = String(input.text ?? '').trim()
  if (!UUID.test(String(input.conversation_id ?? ''))) return json({ error: 'conversation_id inválido.' }, 400)
  if (!text) return json({ error: 'Texto vazio.' }, 400)
  if (text.length > LIMITE_TOTAL) return json({ error: `Texto longo demais para o agente (limite de ${LIMITE_TOTAL} caracteres).` }, 400)

  const db = serviceClient()
  const { data: pode, error: podeErr } = await db.rpc('agente_pode_enviar', { p_conversation: input.conversation_id })
  if (podeErr) return json({ error: 'Não foi possível conferir se o agente pode responder.' }, 500)
  if (!pode?.pode) return json({ error: 'O agente não pode responder esta conversa agora.', motivo: pode?.motivo ?? null, code: 'agente_bloqueado' }, 409)

  const { data: conv } = await db
    .from('conversations')
    .select('id, last_inbound_at, ad_window_until, contact:contacts(wa_id)')
    .eq('id', input.conversation_id)
    .maybeSingle()
  // deno-lint-ignore no-explicit-any
  const waId = (conv as any)?.contact?.wa_id as string | undefined
  if (!conv || !waId) return json({ error: 'Conversa não encontrada.' }, 404)

  const until = Math.max(
    conv.last_inbound_at ? new Date(conv.last_inbound_at).getTime() + WINDOW_MS : 0,
    conv.ad_window_until ? new Date(conv.ad_window_until).getTime() : 0,
  )
  if (until <= Date.now()) return json({ error: 'A janela de atendimento está fechada.', code: 'window_closed' }, 409)

  const partes = partir(text)
  let ultimoWaId: string | null = null
  for (let i = 0; i < partes.length; i++) {
    const parte = partes[i]
    let res: Response
    try {
      res = await fetch(`${GRAPH}/${env.WHATSAPP_PHONE_NUMBER_ID}/messages`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${env.WHATSAPP_TOKEN}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ messaging_product: 'whatsapp', to: waId, type: 'text', text: { body: parte, preview_url: false } }),
      })
    } catch {
      return json({ error: 'Não foi possível falar com a API do WhatsApp.', partes_enviadas: i, partes_total: partes.length }, 502)
    }
    const result = await res.json().catch(() => ({}))
    if (!res.ok) {
      console.error('Erro da Meta ao enviar (agente):', Number(result?.error?.code) || null)
      return json({ error: 'A Meta recusou o envio.', meta_code: Number(result?.error?.code) || null, partes_enviadas: i, partes_total: partes.length }, 502)
    }

    const waMessageId = result?.messages?.[0]?.id as string | undefined
    ultimoWaId = waMessageId ?? ultimoWaId
    const now = new Date().toISOString()
    const { error: insErr } = await db.from('messages').insert({
      conversation_id: conv.id, wa_message_id: waMessageId ?? null, direction: 'out', type: 'text', body: parte, status: 'sent', created_at: now,
    })
    if (insErr) {
      console.error('Mensagem enviada pelo agente, mas falhou ao gravar:', insErr.message)
      return json({ error: 'Mensagem enviada ao WhatsApp, mas não foi possível registrá-la no CRM.', partes_enviadas: i + 1, partes_total: partes.length }, 500)
    }
    await db.from('conversations').update({ last_message_at: now, last_message_preview: parte.slice(0, 120) }).eq('id', conv.id)
  }
  return json({ ok: true, wa_message_id: ultimoWaId, partes: partes.length })
})
