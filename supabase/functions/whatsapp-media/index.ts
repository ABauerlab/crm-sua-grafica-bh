import { json, requireEnv, requireServiceRole, requireStaff, serviceClient } from '../_shared/http.ts'

const GRAPH = 'https://graph.facebook.com/v21.0'
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
}
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

// Entrega a mídia de uma mensagem recebida. O token da Meta fica só aqui no servidor.
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'GET') return json({ error: 'Método não permitido.' }, 405)

  const db = serviceClient()
  // atendente logado (tela do CRM) ou o n8n com a service role (transcrição de áudio do agente)
  if (!(await requireStaff(req, db)) && !(await requireServiceRole(req))) return json({ error: 'Não autorizado.' }, 401)
  const env = requireEnv('WHATSAPP_TOKEN')
  if (!env) return json({ error: 'Integração com o WhatsApp não configurada no servidor.' }, 500)

  const messageId = new URL(req.url).searchParams.get('message_id') ?? ''
  if (!UUID.test(messageId)) return json({ error: 'Mensagem inválida.' }, 400)

  const { data: msg } = await db.from('messages').select('media_id').eq('id', messageId).maybeSingle()
  if (!msg?.media_id) return json({ error: 'Esta mensagem não tem arquivo.' }, 404)

  const meta = await fetch(`${GRAPH}/${encodeURIComponent(msg.media_id)}`, { headers: { Authorization: `Bearer ${env.WHATSAPP_TOKEN}` } }).catch(() => null)
  const info = meta && meta.ok ? await meta.json().catch(() => null) : null
  if (!info?.url) return json({ error: 'A Meta não encontrou o arquivo (pode ter expirado, eles ficam disponíveis por 30 dias).' }, 502)

  const file = await fetch(info.url, { headers: { Authorization: `Bearer ${env.WHATSAPP_TOKEN}` } }).catch(() => null)
  if (!file?.ok || !file.body) return json({ error: 'Não foi possível baixar o arquivo da Meta.' }, 502)

  return new Response(file.body, {
    headers: {
      ...cors,
      'Content-Type': String(info.mime_type ?? file.headers.get('content-type') ?? 'application/octet-stream'),
      'Cache-Control': 'private, max-age=3600',
    },
  })
})
