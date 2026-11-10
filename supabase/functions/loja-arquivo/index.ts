// E-commerce: recebe o PDF da arte do cliente no checkout do site. Pública (o pedido é identificado pelo UUID, que só o comprador conhece).
// Só aceita PDF de verdade (assinatura %PDF- e fim %%EOF), até 50 MB, guarda no bucket privado order-files e registra em order_files.
// Logs sem dados pessoais nem nome do arquivo.
import { createClient } from 'npm:@supabase/supabase-js@2'

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-pedido, x-nome',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const MAX = 50 * 1024 * 1024
const resposta = (corpo: unknown, status = 200) => new Response(JSON.stringify(corpo), { status, headers: { ...CORS, 'Content-Type': 'application/json' } })

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS })
  if (req.method !== 'POST') return resposta({ error: 'Método não permitido.' }, 405)

  const id = req.headers.get('x-pedido') ?? ''
  if (!UUID.test(id)) return resposta({ error: 'Pedido inválido.' }, 400)
  if (Number(req.headers.get('content-length') ?? 0) > MAX) return resposta({ error: 'O PDF passa de 50 MB. Reduza o tamanho sem perder qualidade ou envie pelo WhatsApp.' }, 413)

  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } })
  const { data: o } = await db.from('orders').select('id, origin_label, created_at, art_status').eq('id', id).maybeSingle()
  if (!o || o.origin_label !== 'site') return resposta({ error: 'Pedido não encontrado.' }, 404)
  if (Date.now() - new Date(o.created_at).getTime() > 48 * 3600_000) return resposta({ error: 'Esse pedido é antigo. Chame a gente no WhatsApp para enviar a arte.' }, 410)
  const { count } = await db.from('order_files').select('id', { count: 'exact', head: true }).eq('order_id', id).gt('created_at', new Date(Date.now() - 3600_000).toISOString())
  if ((count ?? 0) >= 5) return resposta({ error: 'Muitos envios seguidos. Aguarde alguns minutos.' }, 429)

  const buf = new Uint8Array(await req.arrayBuffer())
  if (buf.length < 1024) return resposta({ error: 'Arquivo vazio ou pequeno demais para ser uma arte.' }, 400)
  if (buf.length > MAX) return resposta({ error: 'O PDF passa de 50 MB.' }, 413)
  const dec = (b: Uint8Array) => new TextDecoder('latin1').decode(b)
  if (dec(buf.slice(0, 5)) !== '%PDF-') return resposta({ error: 'Só aceitamos arquivo PDF em alta qualidade.' }, 400)
  if (!dec(buf.slice(Math.max(0, buf.length - 2048))).includes('%%EOF')) return resposta({ error: 'O PDF parece incompleto ou corrompido. Exporte de novo e envie.' }, 400)

  let nome = 'arte.pdf'
  try { nome = decodeURIComponent(req.headers.get('x-nome') ?? 'arte.pdf') } catch { /* mantém o padrão */ }
  nome = nome.replace(/[^\w.\- ()]/g, '_').slice(0, 120)
  if (!/\.pdf$/i.test(nome)) nome += '.pdf'

  const path = `${id}/arte-site-${Date.now()}.pdf`
  const up = await db.storage.from('order-files').upload(path, buf, { contentType: 'application/pdf', upsert: false })
  if (up.error) { console.error('loja-arquivo: upload falhou'); return resposta({ error: 'Não foi possível guardar o arquivo agora. Tente de novo.' }, 500) }
  const { data: ult } = await db.from('order_files').select('version').eq('order_id', id).eq('kind', 'arte').order('version', { ascending: false }).limit(1)
  const { error: eReg } = await db.from('order_files').insert({ order_id: id, kind: 'arte', version: (ult?.[0]?.version ?? 0) + 1, path, filename: nome, status: 'enviada' })
  if (eReg) { console.error('loja-arquivo: registro falhou'); return resposta({ error: 'Não foi possível registrar o arquivo. Tente de novo.' }, 500) }
  if (o.art_status === 'aguardando') await db.from('orders').update({ art_status: 'enviada' }).eq('id', id)
  console.log('loja-arquivo: PDF recebido')
  return resposta({ ok: true })
})
