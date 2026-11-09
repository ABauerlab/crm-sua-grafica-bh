'use client'
// Rastreamento Meta (Pixel no navegador + cópia para a Conversions API pelo servidor), com o MESMO event_id para deduplicar.
// Só roda com consentimento (LGPD). Dados pessoais vão em SHA-256.
import { carrinho } from './carrinho'

declare global { interface Window { fbq?: (...a: unknown[]) => void } }

export type EventoMeta = 'PageView' | 'ViewContent' | 'AddToCart' | 'InitiateCheckout' | 'Lead'
const CHAVE_CONSENTIMENTO = 'sgbh:consentimento:v1'

export function consentimento(): 'sim' | 'nao' | null {
  try { return (localStorage.getItem(CHAVE_CONSENTIMENTO) as 'sim' | 'nao' | null) } catch { return null }
}
export function definirConsentimento(v: 'sim' | 'nao') {
  try { localStorage.setItem(CHAVE_CONSENTIMENTO, v) } catch { /* sem armazenamento */ }
  window.dispatchEvent(new Event('sgbh:consentimento'))
}

function cookie(nome: string) {
  return document.cookie.split('; ').find((c) => c.startsWith(`${nome}=`))?.split('=')[1] ?? null
}
function fbc(): string | null {
  const c = cookie('_fbc')
  if (c) return c
  const id = new URLSearchParams(location.search).get('fbclid')
  return id ? `fb.1.${Date.now()}.${id}` : null
}
async function hash(v: string) {
  const d = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(v.trim().toLowerCase()))
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, '0')).join('')
}

/** Dispara o evento no Pixel e manda a cópia para o servidor. Devolve o event_id usado. */
export async function rastrear(nome: EventoMeta, dados: Record<string, unknown> = {}): Promise<string | null> {
  if (consentimento() !== 'sim') return null
  const eventId = `${nome.toLowerCase()}-${crypto.randomUUID()}`
  window.fbq?.('track', nome, dados, { eventID: eventId })
  const cli = carrinho.cliente()
  const user_data: Record<string, string> = {}
  if (cli?.whatsapp) {
    const d = cli.whatsapp.replace(/\D/g, '')
    user_data.ph = await hash(d.startsWith('55') ? d : `55${d}`)
    user_data.external_id = await hash(d.startsWith('55') ? d : `55${d}`)
  }
  const fbp = cookie('_fbp'); const c = fbc()
  if (fbp) user_data.fbp = fbp
  if (c) user_data.fbc = c
  const corpo = JSON.stringify({ event_name: nome, event_id: eventId, event_source_url: location.href, user_data, custom_data: dados })
  try {
    if (!navigator.sendBeacon?.('/api/v1/eventos', new Blob([corpo], { type: 'application/json' }))) {
      void fetch('/api/v1/eventos', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: corpo, keepalive: true })
    }
  } catch { /* rastreamento nunca atrapalha a compra */ }
  return eventId
}
