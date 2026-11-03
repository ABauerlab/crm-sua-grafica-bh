import { supabase } from './supabase'

/** Chama uma Edge Function e traduz o erro devolvido em mensagem legível em português. */
export async function invokeFunction<T = unknown>(name: string, body: unknown = {}): Promise<T> {
  const { data, error } = await supabase.functions.invoke(name, { body: body as Record<string, unknown> | FormData })
  if (error) {
    let message = 'Não foi possível concluir a operação.'
    const ctx = (error as { context?: Response }).context
    if (ctx && typeof ctx.json === 'function') {
      try {
        const payload = await ctx.json()
        if (payload?.error) message = String(payload.error)
      } catch {
        /* mantém a mensagem padrão */
      }
    }
    throw new Error(message)
  }
  return data as T
}

/** Baixa a mídia de uma mensagem (via Edge Function, o token do WhatsApp nunca chega ao navegador). */
export async function fetchMedia(messageId: string): Promise<Blob> {
  const { data } = await supabase.auth.getSession()
  const token = data.session?.access_token
  const res = await fetch(`${import.meta.env.VITE_SUPABASE_URL}/functions/v1/whatsapp-media?message_id=${encodeURIComponent(messageId)}`, {
    headers: { Authorization: `Bearer ${token}`, apikey: import.meta.env.VITE_SUPABASE_ANON_KEY as string },
  })
  if (!res.ok) {
    let msg = 'Não foi possível carregar o arquivo.'
    try {
      msg = (await res.json()).error ?? msg
    } catch {
      /* mantém */
    }
    throw new Error(msg)
  }
  return res.blob()
}
