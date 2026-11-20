// Fase 2: upload do logo ou imagem de referência do cliente (até 2 por prévia, checado aqui pelo que já existe
// no bucket). Pública (o token é o comprovante, como /pagar/<token>). Só JPEG ou PNG, até 8 MB. Guarda no bucket
// privado previas-uploads; devolve só o caminho interno, usado depois em previa-arte (ação enviar_briefing).
import { createClient } from 'npm:@supabase/supabase-js@2'

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-token',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const TOKEN = /^[0-9a-f]{32}$/
const MAX = 8 * 1024 * 1024
const resposta = (corpo: unknown, status = 200) => new Response(JSON.stringify(corpo), { status, headers: { ...CORS, 'Content-Type': 'application/json' } })

function tipoImagem(buf: Uint8Array): 'jpeg' | 'png' | null {
  if (buf.length > 3 && buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return 'jpeg'
  if (buf.length > 8 && buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47) return 'png'
  return null
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS })
  if (req.method !== 'POST') return resposta({ error: 'Método não permitido.' }, 405)

  const token = req.headers.get('x-token') ?? ''
  if (!TOKEN.test(token)) return resposta({ ok: false, erro: 'link_invalido' }, 404)
  if (Number(req.headers.get('content-length') ?? 0) > MAX) return resposta({ ok: false, erro: 'arquivo_grande', mensagem: 'A imagem passa de 8 MB.' }, 413)

  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } })
  const { data: previa } = await db.from('previas_arte').select('id, expira_em, uploads').eq('token', token).maybeSingle()
  if (!previa) return resposta({ ok: false, erro: 'link_invalido' }, 404)
  if (new Date(previa.expira_em).getTime() <= Date.now()) return resposta({ ok: false, erro: 'expirado' }, 410)
  if (Array.isArray(previa.uploads) && previa.uploads.length >= 2) return resposta({ ok: false, erro: 'limite_uploads', mensagem: 'No máximo 2 imagens por prévia.' }, 409)

  const buf = new Uint8Array(await req.arrayBuffer())
  if (buf.length > MAX) return resposta({ ok: false, erro: 'arquivo_grande', mensagem: 'A imagem passa de 8 MB.' }, 413)
  const tipo = tipoImagem(buf)
  if (!tipo) return resposta({ ok: false, erro: 'formato_invalido', mensagem: 'Envie uma imagem JPEG ou PNG.' }, 400)

  const path = `${previa.id}/${Date.now()}.${tipo === 'jpeg' ? 'jpg' : 'png'}`
  const up = await db.storage.from('previas-uploads').upload(path, buf, { contentType: `image/${tipo}`, upsert: false })
  if (up.error) { console.error('previa-arte-upload: falha ao guardar'); return resposta({ ok: false, erro: 'indisponivel' }, 500) }
  return resposta({ ok: true, path: `previas-uploads/${path}` })
})
