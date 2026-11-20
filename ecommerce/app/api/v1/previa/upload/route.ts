import { NextResponse } from 'next/server'
import { erro, limitar } from '@/lib/api-servidor'

const URL_SUPABASE = process.env.NEXT_PUBLIC_SUPABASE_URL
const CHAVE = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY
const TOKEN = /^[0-9a-f]{32}$/

// POST /api/v1/previa/upload (body = bytes da imagem, header x-token) -> Edge Function previa-arte-upload
export async function POST(req: Request) {
  if (!limitar(req, 'previa-upload', 20)) return erro(429, 'Muitos envios seguidos. Aguarde um minuto.')
  const token = req.headers.get('x-token') ?? ''
  if (!TOKEN.test(token)) return erro(404, 'Link inválido.')
  if (!URL_SUPABASE || !CHAVE) return erro(503, 'Loja em manutenção.')
  const buf = await req.arrayBuffer()
  try {
    const res = await fetch(`${URL_SUPABASE}/functions/v1/previa-arte-upload`, {
      method: 'POST',
      headers: { apikey: CHAVE, Authorization: `Bearer ${CHAVE}`, 'Content-Type': req.headers.get('content-type') ?? 'application/octet-stream', 'x-token': token },
      body: buf,
    })
    const data = await res.json().catch(() => ({ error: 'Resposta inválida do servidor.' }))
    return NextResponse.json(data, { status: res.status, headers: { 'Cache-Control': 'no-store' } })
  } catch {
    return erro(502, 'Servidor indisponível. Tente de novo.')
  }
}
