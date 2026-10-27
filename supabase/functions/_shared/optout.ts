import type { SupabaseClient } from 'npm:@supabase/supabase-js@2'

const GRAPH = 'https://graph.facebook.com/v21.0'

export const OPT_OUT_CONFIRMATION =
  'Pronto! Você não receberá mais mensagens promocionais da Sua Gráfica BH. Avisos sobre pedidos em andamento continuam normalmente. Para voltar a receber, é só nos avisar por aqui.'

/**
 * Confirma o descadastro dentro da janela de 24h (o cliente acabou de escrever) e registra a resposta no chat.
 * Nunca lança: falha aqui não pode fazer a Meta reenviar o webhook. Logs sem conteúdo de mensagens.
 */
export async function confirmOptOut(db: SupabaseClient, contactId: string, waId: string): Promise<void> {
  const token = Deno.env.get('WHATSAPP_TOKEN')
  const phoneNumberId = Deno.env.get('WHATSAPP_PHONE_NUMBER_ID')
  if (!token || !phoneNumberId) return

  try {
    const res = await fetch(`${GRAPH}/${phoneNumberId}/messages`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        messaging_product: 'whatsapp',
        to: waId,
        type: 'text',
        text: { body: OPT_OUT_CONFIRMATION, preview_url: false },
      }),
    })
    const result = await res.json().catch(() => ({}))
    if (!res.ok) {
      console.error('Confirmação de descadastro recusada pela Meta:', result?.error?.code)
      return
    }

    const { data: conv } = await db.from('conversations').select('id').eq('contact_id', contactId).maybeSingle()
    if (!conv) return
    const now = new Date().toISOString()
    await db.from('messages').insert({
      conversation_id: conv.id,
      wa_message_id: result?.messages?.[0]?.id ?? null,
      direction: 'out',
      type: 'text',
      body: OPT_OUT_CONFIRMATION,
      status: 'sent',
      created_at: now,
    })
    await db
      .from('conversations')
      .update({ last_message_at: now, last_message_preview: OPT_OUT_CONFIRMATION.slice(0, 120) })
      .eq('id', conv.id)
  } catch (err) {
    console.error('Falha ao confirmar descadastro:', err instanceof Error ? err.message : 'erro desconhecido')
  }
}
