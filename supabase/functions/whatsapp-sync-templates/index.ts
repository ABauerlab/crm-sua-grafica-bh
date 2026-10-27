import { corsHeaders, json, requireEnv, requireStaff, serviceClient } from '../_shared/http.ts'

const GRAPH = 'https://graph.facebook.com/v21.0'

interface MetaTemplate {
  name: string
  language: string
  category?: string
  status?: string
  components?: { type: string; text?: string }[]
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)

  const db = serviceClient()
  if (!(await requireStaff(req, db))) return json({ error: 'Não autorizado.' }, 401)

  const env = requireEnv('WHATSAPP_TOKEN', 'WHATSAPP_WABA_ID')
  if (!env) return json({ error: 'Integração com o WhatsApp não configurada no servidor.' }, 500)

  const startedAt = new Date().toISOString()
  const all: MetaTemplate[] = []
  let next: string | null = `${GRAPH}/${env.WHATSAPP_WABA_ID}/message_templates?limit=100&fields=name,language,category,status,components`

  while (next) {
    let res: Response
    try {
      res = await fetch(next, { headers: { Authorization: `Bearer ${env.WHATSAPP_TOKEN}` } })
    } catch {
      return json({ error: 'Não foi possível falar com a API do WhatsApp.' }, 502)
    }
    const page = await res.json().catch(() => ({}))
    if (!res.ok) {
      console.error('Erro da Meta ao listar templates:', page?.error?.code)
      return json({ error: `A Meta recusou a consulta: ${page?.error?.message ?? 'erro desconhecido'}` }, 502)
    }
    all.push(...(page.data ?? []))
    next = page.paging?.next ?? null
  }

  if (all.length) {
    const rows = all.map((t) => ({
      name: t.name,
      language: t.language,
      category: t.category ?? null,
      status: t.status ?? null,
      body: t.components?.find((c) => c.type === 'BODY')?.text ?? null,
      synced_at: new Date().toISOString(),
    }))
    const { error } = await db.from('templates_cache').upsert(rows, { onConflict: 'name,language' })
    if (error) return json({ error: 'Falha ao gravar os templates.' }, 500)
  }
  // Remove do cache o que não existe mais na Meta
  await db.from('templates_cache').delete().lt('synced_at', startedAt)

  return json({ ok: true, count: all.length })
})
