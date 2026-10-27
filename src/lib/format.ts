import type { ConsentSource, ConversationStatus, MarketingConsent, Stage } from './types'

export const STAGES: { value: Stage; label: string; color: string }[] = [
  { value: 'novo', label: 'Novo', color: 'bg-sky-100 text-sky-800' },
  { value: 'orcamento', label: 'Orçamento', color: 'bg-amber-100 text-amber-800' },
  { value: 'negociando', label: 'Negociando', color: 'bg-violet-100 text-violet-800' },
  { value: 'fechado', label: 'Fechado', color: 'bg-emerald-100 text-emerald-800' },
  { value: 'perdido', label: 'Perdido', color: 'bg-rose-100 text-rose-800' },
]

export const STATUSES: { value: ConversationStatus; label: string }[] = [
  { value: 'open', label: 'Aberta' },
  { value: 'pending', label: 'Pendente' },
  { value: 'closed', label: 'Encerrada' },
]

export const CONSENTS: { value: MarketingConsent; label: string }[] = [
  { value: 'none', label: 'Sem registro (não enviar promoções)' },
  { value: 'opted_in', label: 'Autorizou receber promoções' },
  { value: 'opted_out', label: 'Pediu para não receber' },
]

export const CONSENT_SOURCES: { value: ConsentSource; label: string }[] = [
  { value: 'whatsapp', label: 'Pelo WhatsApp' },
  { value: 'manual', label: 'Combinado com o atendente' },
  { value: 'formulario', label: 'Formulário / site' },
  { value: 'loja', label: 'Na loja' },
  { value: 'outro', label: 'Outro' },
]

export const stageInfo = (s: Stage) => STAGES.find((x) => x.value === s) ?? STAGES[0]

export const WINDOW_MS = 24 * 60 * 60 * 1000

/** Janela de atendimento da Meta: texto livre só até 24h após a última mensagem do cliente. */
export function windowOpen(lastInboundAt: string | null, now = Date.now()): boolean {
  return !!lastInboundAt && now - new Date(lastInboundAt).getTime() < WINDOW_MS
}

export function windowRemaining(lastInboundAt: string | null, now = Date.now()): string {
  if (!lastInboundAt) return ''
  const ms = WINDOW_MS - (now - new Date(lastInboundAt).getTime())
  if (ms <= 0) return ''
  const h = Math.floor(ms / 3_600_000)
  const m = Math.floor((ms % 3_600_000) / 60_000)
  return h > 0 ? `${h}h${String(m).padStart(2, '0')}` : `${m}min`
}

export function formatListTime(iso: string | null): string {
  if (!iso) return ''
  const d = new Date(iso)
  const now = new Date()
  if (d.toDateString() === now.toDateString()) {
    return d.toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' })
  }
  const yesterday = new Date(now)
  yesterday.setDate(now.getDate() - 1)
  if (d.toDateString() === yesterday.toDateString()) return 'Ontem'
  return d.toLocaleDateString('pt-BR', { day: '2-digit', month: '2-digit' })
}

export function formatTime(iso: string): string {
  return new Date(iso).toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' })
}

export function formatDay(iso: string): string {
  return new Date(iso).toLocaleDateString('pt-BR', { day: '2-digit', month: 'long', year: 'numeric' })
}

export function formatPhone(waId: string): string {
  const m = /^55(\d{2})(9?\d{4})(\d{4})$/.exec(waId)
  return m ? `+55 (${m[1]}) ${m[2]}-${m[3]}` : `+${waId}`
}

export const contactLabel = (c: { name: string | null; wa_id: string }) => c.name?.trim() || formatPhone(c.wa_id)

/** Variáveis {{1}}, {{2}}... de um template, em ordem. */
export function templateVariables(body: string | null): number[] {
  const found = new Set<number>()
  for (const m of (body ?? '').matchAll(/\{\{(\d+)\}\}/g)) found.add(Number(m[1]))
  return [...found].sort((a, b) => a - b)
}
