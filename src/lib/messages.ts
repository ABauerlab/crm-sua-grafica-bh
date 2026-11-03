import type { Message } from './types'

export const REACOES = ['👍', '❤️', '😂', '😮', '🙏', '✅']

const ROTULO_MIDIA = /^\[(imagem|vídeo|áudio|documento|figurinha) recebid[oa]\]\s*/i

/** Texto para exibir: tira o marcador "[imagem recebida]" e deixa só a legenda. */
export function textoVisivel(m: Message): string {
  const b = m.body ?? ''
  if (['image', 'video', 'audio', 'sticker'].includes(m.type)) return b.replace(ROTULO_MIDIA, '')
  if (m.type === 'document') return b.replace(ROTULO_MIDIA, '')
  return b
}

export const NAO_SUPORTADA = '[mensagem não suportada]'
export const ehNaoSuportada = (m: Message) => m.type === 'other' && (m.body ?? '').startsWith(NAO_SUPORTADA)

export const TIPO_ROTULO: Record<Message['type'], string> = {
  text: 'Texto', image: 'Imagem', document: 'Documento', audio: 'Áudio', video: 'Vídeo', sticker: 'Figurinha',
  location: 'Localização', contacts: 'Contato', reaction: 'Reação', template: 'Template', other: 'Outro',
}

/** Resumo curto de uma mensagem (para a citação de resposta e a prévia). */
export function resumo(m: Message): string {
  const t = textoVisivel(m).trim()
  const nome = typeof m.meta?.filename === 'string' ? m.meta.filename : null
  switch (m.type) {
    case 'image': return t ? `📷 ${t}` : '📷 Imagem'
    case 'video': return t ? `🎥 ${t}` : '🎥 Vídeo'
    case 'audio': return m.meta?.voice ? '🎤 Mensagem de voz' : '🎧 Áudio'
    case 'document': return `📄 ${nome ?? t ?? 'Documento'}`
    case 'sticker': return 'Figurinha'
    case 'location': return '📍 Localização'
    case 'contacts': return '👤 Contato'
    default: return t || '…'
  }
}

/** Reações por mensagem: { wa_message_id: { in?: emoji, out?: emoji } }. A última de cada lado vale; emoji vazio retira. */
export function reacoesPorMensagem(msgs: Message[]): Record<string, { in?: string; out?: string }> {
  const out: Record<string, { in?: string; out?: string }> = {}
  for (const m of [...msgs].sort((a, b) => a.created_at.localeCompare(b.created_at))) {
    if (m.type !== 'reaction') continue
    const alvo = typeof m.meta?.alvo === 'string' ? m.meta.alvo : null
    if (!alvo) continue
    const lado = m.direction === 'in' ? 'in' : 'out'
    const emoji = (m.body ?? '').trim()
    out[alvo] = { ...out[alvo] }
    if (emoji) out[alvo][lado] = emoji
    else delete out[alvo][lado]
  }
  return out
}

export function tamanhoLegivel(bytes: unknown): string | null {
  const n = Number(bytes)
  if (!Number.isFinite(n) || n <= 0) return null
  if (n < 1024) return `${n} B`
  if (n < 1024 * 1024) return `${Math.round(n / 1024)} KB`
  return `${(n / 1024 / 1024).toFixed(1)} MB`
}
