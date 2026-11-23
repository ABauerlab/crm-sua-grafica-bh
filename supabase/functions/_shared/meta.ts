// Conversions API da Meta: monta o corpo de POST /{pixel}/events a partir da fila meta_eventos. Funções puras (testadas em Node).

export interface EventoFila {
  id: number; event_id: string; event_name: string; event_time: string; action_source: string
  event_source_url: string | null; messaging_channel?: string | null; user_data: Record<string, string>; custom_data: Record<string, unknown>
}

const HASHEADOS = ['em', 'ph', 'external_id', 'ct', 'st', 'zp', 'country']

/** Formato da Meta: campos com hash vão em lista; ip, user agent, fbp e fbc em texto; event_time em segundos. */
export function eventoMeta(e: EventoFila, waba?: string | null) {
  const u: Record<string, string | string[]> = {}
  for (const [k, v] of Object.entries(e.user_data ?? {})) {
    if (!v) continue
    if (HASHEADOS.includes(k)) { if (/^[0-9a-f]{64}$/.test(v)) u[k] = [v] } else u[k] = v
  }
  // Business Messaging (WhatsApp): a Meta atribui pelo ctwa_clid e pelo WABA, em texto puro, e não aceita URL de origem.
  const chat = e.action_source === 'business_messaging'
  if (chat && waba) u.whatsapp_business_account_id = waba
  return {
    event_name: e.event_name,
    event_time: Math.floor(new Date(e.event_time).getTime() / 1000),
    event_id: e.event_id,
    action_source: e.action_source,
    ...(chat ? { messaging_channel: e.messaging_channel || 'whatsapp' } : {}),
    ...(e.event_source_url && !chat ? { event_source_url: e.event_source_url } : {}),
    user_data: u,
    ...(Object.keys(e.custom_data ?? {}).length ? { custom_data: e.custom_data } : {}),
  }
}

export function corpoMeta(eventos: EventoFila[], testCode?: string | null, waba?: string | null) {
  return { data: eventos.map((e) => eventoMeta(e, waba)), ...(testCode ? { test_event_code: testCode } : {}) }
}

/** SHA-256 em hex de texto normalizado (minúsculas, sem espaços nas pontas), como a Meta pede. */
export async function sha256(texto: string): Promise<string> {
  const d = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(texto.trim().toLowerCase()))
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, '0')).join('')
}
