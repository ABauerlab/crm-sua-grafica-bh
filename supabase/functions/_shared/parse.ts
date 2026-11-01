// Extração dos eventos do payload do webhook do WhatsApp Cloud API (sem dependências de Deno).

export type InboundType = 'text' | 'image' | 'document' | 'audio' | 'other'

export interface InboundMessage {
  waId: string
  name: string | null
  waMessageId: string
  type: InboundType
  body: string
  mediaId: string | null
  timestamp: Date
  /** Origem do anúncio (click to WhatsApp), presente só na primeira mensagem vinda de anúncio. */
  referral: Referral | null
}

export interface Referral {
  sourceUrl: string | null
  sourceId: string | null
  sourceType: string | null
  headline: string | null
  body: string | null
  mediaType: string | null
  ctwaClid: string | null
}

export interface StatusUpdate {
  waMessageId: string
  status: 'sent' | 'delivered' | 'read' | 'failed'
  error: string | null
}

// deno-lint-ignore no-explicit-any
type Json = any

const MEDIA_LABELS: Record<string, [InboundType, string]> = {
  image: ['image', '[imagem recebida]'],
  document: ['document', '[documento recebido]'],
  audio: ['audio', '[áudio recebido]'],
  video: ['other', '[vídeo recebido]'],
  sticker: ['other', '[figurinha recebida]'],
}

function extractReferral(r: Json): Referral | null {
  if (!r || typeof r !== 'object') return null
  const str = (v: Json) => (typeof v === 'string' && v ? v : null)
  const out = {
    sourceUrl: str(r.source_url),
    sourceId: str(r.source_id),
    sourceType: str(r.source_type),
    headline: str(r.headline),
    body: str(r.body),
    mediaType: str(r.media_type),
    ctwaClid: str(r.ctwa_clid),
  }
  return Object.values(out).some(Boolean) ? out : null
}

export function extractEvents(payload: Json): { messages: InboundMessage[]; statuses: StatusUpdate[] } {
  const messages: InboundMessage[] = []
  const statuses: StatusUpdate[] = []

  for (const entry of payload?.entry ?? []) {
    for (const change of entry?.changes ?? []) {
      const value = change?.value
      if (!value) continue

      const names = new Map<string, string>()
      for (const c of value.contacts ?? []) {
        if (c?.wa_id && c?.profile?.name) names.set(String(c.wa_id), String(c.profile.name))
      }

      for (const m of value.messages ?? []) {
        if (!m?.id || !m?.from) continue
        const waId = String(m.from).replace(/\D/g, '')
        if (!waId) continue
        const ts = new Date(Number(m.timestamp) * 1000)
        const base = {
          waId,
          name: names.get(String(m.from)) ?? null,
          waMessageId: String(m.id),
          timestamp: Number.isNaN(ts.getTime()) ? new Date() : ts,
          referral: extractReferral(m.referral),
        }

        const media = MEDIA_LABELS[m.type]
        if (m.type === 'text') {
          messages.push({ ...base, type: 'text', body: String(m.text?.body ?? ''), mediaId: null })
        } else if (media) {
          const caption = m[m.type]?.caption
          messages.push({
            ...base,
            type: media[0],
            body: caption ? `${media[1]} ${caption}` : media[1],
            mediaId: m[m.type]?.id ?? null,
          })
        } else if (m.type === 'location' && m.location) {
          const { latitude, longitude, name, address } = m.location
          const label = [name, address].filter(Boolean).join(', ')
          messages.push({
            ...base,
            type: 'other',
            body: `[localização] ${label ? `${label} ` : ''}https://www.google.com/maps?q=${latitude},${longitude}`,
            mediaId: null,
          })
        } else if (m.type === 'button' && m.button?.text) {
          messages.push({ ...base, type: 'text', body: String(m.button.text), mediaId: null })
        } else if (m.type === 'interactive') {
          const title = m.interactive?.button_reply?.title ?? m.interactive?.list_reply?.title
          messages.push({ ...base, type: 'text', body: title ? String(title) : '[mensagem não suportada]', mediaId: null })
        } else {
          messages.push({ ...base, type: 'other', body: '[mensagem não suportada]', mediaId: null })
        }
      }

      for (const s of value.statuses ?? []) {
        if (!s?.id || !['sent', 'delivered', 'read', 'failed'].includes(s.status)) continue
        const err = s.errors?.[0]
        statuses.push({
          waMessageId: String(s.id),
          status: s.status,
          error: err ? [err.code, err.title ?? err.message].filter(Boolean).join(' - ') : null,
        })
      }
    }
  }

  return { messages, statuses }
}

const RANK: Record<string, number> = { sent: 1, delivered: 2, read: 3 }

/** Eventos da Meta podem chegar fora de ordem: 'read' nunca volta para 'delivered'. */
export function shouldApplyStatus(current: string | null, next: StatusUpdate['status']): boolean {
  if (next === 'failed') return current !== 'read'
  if (!current || current === 'failed') return true
  return (RANK[next] ?? 0) > (RANK[current] ?? 0)
}

const OPT_OUT_KEYWORDS = new Set([
  'PARAR',
  'SAIR',
  'STOP',
  'DESCADASTRAR',
  'PARAR DE RECEBER',
  'SAIR DA LISTA',
  'CANCELAR INSCRICAO',
  'PARAR PROMOCOES',
  'PARAR DE RECEBER PROMOCOES',
  'NAO QUERO RECEBER',
  'NAO QUERO MAIS',
  'NAO QUERO MAIS RECEBER',
  'NAO QUERO MAIS MENSAGENS',
  'PARE',
])

/** Pedido de descadastro das promoções: a mensagem inteira precisa ser a palavra-chave (evita "quero parar o pedido"). */
export function isOptOutMessage(body: string): boolean {
  const normalized = body
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toUpperCase()
    .replace(/[^A-Z0-9 ]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
  return OPT_OUT_KEYWORDS.has(normalized)
}
