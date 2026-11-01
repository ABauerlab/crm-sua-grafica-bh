// Aciona o WF1 (n8n) depois que o webhook da Meta gravou uma mensagem de entrada.
// Não existe outro webhook na Meta: este é o único receptor, e ele só avisa o n8n com o id da mensagem (nunca o conteúdo).
// Nunca lança e nunca atrasa a resposta à Meta por mais que o tempo limite: o n8n lê tudo do banco e é idempotente por mensagem.
export const AGENTE_TIMEOUT_MS = 3000

export async function acionarAgente(
  messageId: string,
  env: { url?: string | null; token?: string | null },
  doFetch: typeof fetch = fetch,
): Promise<'enviado' | 'desligado' | 'falhou'> {
  if (!env.url || !env.token) return 'desligado' // sem segredos configurados o agente fica fora do caminho
  const ctl = new AbortController()
  const t = setTimeout(() => ctl.abort(), AGENTE_TIMEOUT_MS)
  try {
    const res = await doFetch(env.url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-gbh-token': env.token },
      body: JSON.stringify({ message_id: messageId }),
      signal: ctl.signal,
    })
    if (!res.ok) {
      console.error('WF1 recusou o aviso:', res.status)
      return 'falhou'
    }
    return 'enviado'
  } catch {
    console.error('Não foi possível avisar o WF1 (a mensagem já está gravada).')
    return 'falhou'
  } finally {
    clearTimeout(t)
  }
}
