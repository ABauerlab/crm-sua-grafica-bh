import { supabase } from './supabase'

/** Chama uma Edge Function e traduz o erro devolvido em mensagem legível em português. */
export async function invokeFunction<T = unknown>(name: string, body: unknown = {}): Promise<T> {
  const { data, error } = await supabase.functions.invoke(name, { body: body as Record<string, unknown> })
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
