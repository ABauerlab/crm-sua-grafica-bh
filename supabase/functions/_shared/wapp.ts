// Envio pela API oficial do WhatsApp (Graph) usado pelos alertas e pela confirmação ao cliente. O token fica só no servidor.
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2'

const GRAPH = 'https://graph.facebook.com/v21.0'

export interface WaEnv {
  WHATSAPP_TOKEN: string
  WHATSAPP_PHONE_NUMBER_ID: string
  WHATSAPP_WABA_ID?: string
}

export interface WaResultado {
  ok: boolean
  wa_message_id?: string
  codigo?: number | null
  erro?: string
}

async function post(env: WaEnv, body: unknown): Promise<WaResultado> {
  try {
    const res = await fetch(`${GRAPH}/${env.WHATSAPP_PHONE_NUMBER_ID}/messages`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${env.WHATSAPP_TOKEN}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    })
    const r = await res.json().catch(() => ({}))
    if (!res.ok) {
      const codigo = Number(r?.error?.code) || null
      console.error('Erro da Meta ao enviar aviso:', codigo)
      return { ok: false, codigo, erro: `meta_${codigo ?? res.status}` }
    }
    return { ok: true, wa_message_id: r?.messages?.[0]?.id as string | undefined }
  } catch {
    return { ok: false, erro: 'rede' }
  }
}

export const enviarTexto = (env: WaEnv, to: string, text: string) =>
  post(env, { messaging_product: 'whatsapp', to, type: 'text', text: { body: text, preview_url: false } })

export const enviarTemplate = (env: WaEnv, to: string, name: string, params: string[], language = 'pt_BR') =>
  post(env, {
    messaging_product: 'whatsapp',
    to,
    type: 'template',
    template: {
      name,
      language: { code: language },
      components: [{ type: 'body', parameters: params.map((text) => ({ type: 'text', text })) }],
    },
  })

/** Status atual do template na Meta (atualiza o cache). null = não foi possível consultar (tenta enviar mesmo assim). */
export async function statusTemplate(env: WaEnv, db: SupabaseClient, name: string, language = 'pt_BR'): Promise<string | null> {
  if (!env.WHATSAPP_WABA_ID) return null
  try {
    const res = await fetch(`${GRAPH}/${env.WHATSAPP_WABA_ID}/message_templates?name=${encodeURIComponent(name)}&fields=name,status,language,category,components&limit=10`, {
      headers: { Authorization: `Bearer ${env.WHATSAPP_TOKEN}` },
    })
    if (!res.ok) return null
    const r = await res.json()
    // deno-lint-ignore no-explicit-any
    const t = (r?.data ?? []).find((x: any) => x.name === name && x.language === language)
    if (!t) return 'NAO_ENCONTRADO'
    // deno-lint-ignore no-explicit-any
    const body = (t.components ?? []).find((c: any) => c.type === 'BODY')?.text as string | undefined
    await db.from('templates_cache').upsert({ name, language, category: t.category ?? null, status: t.status, body: body ?? null, synced_at: new Date().toISOString() })
    return String(t.status)
  } catch {
    return null
  }
}
