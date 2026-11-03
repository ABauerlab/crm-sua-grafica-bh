// Extração dos eventos do payload do webhook do WhatsApp Cloud API (sem dependências de Deno).

export type InboundType = 'text' | 'image' | 'document' | 'audio' | 'video' | 'sticker' | 'location' | 'contacts' | 'reaction' | 'other'

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
  /** Mensagem a que esta responde (context.id da Meta) */
  replyToWaId: string | null
  forwarded: boolean
  /** Tipo original da Meta (ex.: "unsupported", "reaction") */
  rawType: string
  /** Detalhes: nome do arquivo, formato, local, contatos, reação... */
  meta: Record<string, unknown> | null
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
  video: ['video', '[vídeo recebido]'],
  sticker: ['sticker', '[figurinha recebida]'],
}

/** Texto padrão quando a Meta não entrega o conteúdo (tipo que a API não repassa). */
export const TEXTO_NAO_SUPORTADO = '[mensagem não suportada]'

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
        const base0 = {
          waId,
          name: names.get(String(m.from)) ?? null,
          waMessageId: String(m.id),
          timestamp: Number.isNaN(ts.getTime()) ? new Date() : ts,
          referral: extractReferral(m.referral),
        }

        const ctx = m.context && typeof m.context === 'object' ? m.context : null
        const base = {
          ...base0,
          replyToWaId: typeof ctx?.id === 'string' && ctx.id ? ctx.id : null,
          forwarded: !!(ctx?.forwarded || ctx?.frequently_forwarded),
          rawType: String(m.type ?? 'desconhecido'),
        }
        const add = (x: Omit<InboundMessage, keyof typeof base | 'referral' | 'meta'> & { meta?: Record<string, unknown> | null }) =>
          messages.push({ ...base, meta: null, ...x })

        const media = MEDIA_LABELS[m.type]
        if (m.type === 'text') {
          add({ type: 'text', body: String(m.text?.body ?? ''), mediaId: null })
        } else if (media) {
          const item = m[m.type] ?? {}
          const caption = item.caption
          add({
            type: media[0],
            body: caption ? `${media[1]} ${caption}` : media[1],
            mediaId: item.id ?? null,
            meta: {
              ...(item.mime_type ? { mime_type: item.mime_type } : {}),
              ...(item.filename ? { filename: item.filename } : {}),
              ...(item.voice ? { voice: true } : {}),
              ...(item.animated ? { animated: true } : {}),
            },
          })
        } else if (m.type === 'location' && m.location) {
          const { latitude, longitude, name, address } = m.location
          const label = [name, address].filter(Boolean).join(', ')
          add({
            type: 'location',
            body: `[localização] ${label ? `${label} ` : ''}https://www.google.com/maps?q=${latitude},${longitude}`,
            mediaId: null,
            meta: { latitude, longitude, name: name ?? null, address: address ?? null },
          })
        } else if (m.type === 'contacts' && Array.isArray(m.contacts)) {
          const lista = m.contacts.slice(0, 10).map((c: Json) => ({
            nome: String(c?.name?.formatted_name ?? c?.name?.first_name ?? 'Contato'),
            telefones: (c?.phones ?? []).map((p: Json) => String(p?.wa_id ?? p?.phone ?? '')).filter(Boolean),
          }))
          add({
            type: 'contacts',
            body: `[contato] ${lista.map((c: { nome: string; telefones: string[] }) => [c.nome, c.telefones[0]].filter(Boolean).join(' ')).join(', ')}`,
            mediaId: null,
            meta: { contatos: lista },
          })
        } else if (m.type === 'reaction' && m.reaction) {
          // reação a uma mensagem: emoji vazio = o cliente retirou a reação
          add({ type: 'reaction', body: String(m.reaction.emoji ?? ''), mediaId: null, meta: { alvo: String(m.reaction.message_id ?? '') } })
        } else if (m.type === 'button' && m.button?.text) {
          add({ type: 'text', body: String(m.button.text), mediaId: null, meta: m.button.payload ? { payload: String(m.button.payload) } : null })
        } else if (m.type === 'interactive') {
          const r = m.interactive?.button_reply ?? m.interactive?.list_reply
          if (r?.title) add({ type: 'text', body: String(r.title), mediaId: null, meta: { resposta_id: r.id ?? null } })
          else add({ type: 'other', body: m.interactive?.nfm_reply ? '[resposta de formulário]' : TEXTO_NAO_SUPORTADO, mediaId: null, meta: { raw: m.interactive ?? null } })
        } else if (m.type === 'order') {
          add({ type: 'other', body: '[pedido do catálogo do WhatsApp]', mediaId: null, meta: { raw: m.order ?? null } })
        } else if (m.type === 'system') {
          add({ type: 'other', body: `[aviso do sistema] ${String(m.system?.body ?? '')}`.trim(), mediaId: null, meta: { raw: m.system ?? null } })
        } else {
          // "unsupported" (enquete, mídia de visualização única...) ou tipo novo da Meta: guarda o que veio para diagnóstico
          add({ type: 'other', body: TEXTO_NAO_SUPORTADO, mediaId: null, meta: { erros: m.errors ?? null, raw: { type: m.type ?? null } } })
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
