import { WINDOW_MS } from '@/lib/format'

export interface WindowInfo {
  open: boolean
  /** Quando a janela fecha (ms) */
  until: number | null
  kind: '24h' | '72h' | null
  remaining: string
}

const fmt = (ms: number) => {
  const h = Math.floor(ms / 3_600_000)
  const m = Math.floor((ms % 3_600_000) / 60_000)
  return h > 0 ? `${h}h${String(m).padStart(2, '0')}` : `${Math.max(1, m)}min`
}

/** Janela de atendimento: 24 h desde a última mensagem do cliente, ou 72 h quando a conversa veio de um anúncio (clique para o WhatsApp). */
export function windowInfo(c: { last_inbound_at: string | null; ad_window_until?: string | null }, now = Date.now()): WindowInfo {
  const by24 = c.last_inbound_at ? new Date(c.last_inbound_at).getTime() + WINDOW_MS : 0
  const by72 = c.ad_window_until ? new Date(c.ad_window_until).getTime() : 0
  const until = Math.max(by24, by72)
  if (!until || until <= now) return { open: false, until: until || null, kind: null, remaining: '' }
  return { open: true, until, kind: by72 > by24 ? '72h' : '24h', remaining: fmt(until - now) }
}
