import { NextResponse } from 'next/server'
import { limitar, rpc } from '@/lib/api-servidor'

// POST /api/v1/eventos: cópia do evento do Pixel para a Conversions API (mesmo event_id). IP e navegador vêm do próprio pedido.
export async function POST(req: Request) {
  if (!limitar(req, 'eventos', 120)) return new NextResponse(null, { status: 204 })
  const body = await req.json().catch(() => null) as { user_data?: Record<string, unknown> } | null
  if (!body) return new NextResponse(null, { status: 204 })
  const ip = (req.headers.get('x-forwarded-for') ?? '').split(',')[0].trim() || req.headers.get('x-real-ip') || undefined
  const evento = { ...body, user_data: { ...(body.user_data ?? {}), client_ip_address: ip, client_user_agent: req.headers.get('user-agent') ?? undefined } }
  await rpc('meta_evento_registrar', { p_evento: evento })
  return new NextResponse(null, { status: 204 })
}
