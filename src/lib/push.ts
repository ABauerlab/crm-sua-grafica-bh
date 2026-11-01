import { invokeFunction } from './api'
import { supabase } from './supabase'

/** Notificações push (Web Push). No iPhone só funcionam com o app instalado na Tela de Início (iOS 16.4 ou superior). */

export type EstadoPush =
  | 'sem_suporte' // navegador sem service worker ou push
  | 'ios_fora_da_tela_inicio' // iPhone/iPad no Safari: precisa instalar primeiro
  | 'negado' // permissão bloqueada no aparelho
  | 'pedir' // pode pedir a permissão (toque no botão)
  | 'ativo' // permitido e assinatura salva

export const ehIOS = (): boolean =>
  /iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1)

export const instalado = (): boolean =>
  window.matchMedia('(display-mode: standalone)').matches || (navigator as Navigator & { standalone?: boolean }).standalone === true

export function nomeDoAparelho(): string {
  const ua = navigator.userAgent
  const so = /iPhone/.test(ua) ? 'iPhone' : /iPad/.test(ua) ? 'iPad' : /Android/.test(ua) ? 'Android' : /Mac/.test(ua) ? 'Mac' : /Windows/.test(ua) ? 'Windows' : 'Aparelho'
  return `${so}${instalado() ? ' (app instalado)' : ' (navegador)'}`
}

function paraBytes(base64url: string): Uint8Array<ArrayBuffer> {
  const pad = '='.repeat((4 - (base64url.length % 4)) % 4)
  const bin = atob((base64url + pad).replaceAll('-', '+').replaceAll('_', '/'))
  const out = new Uint8Array(new ArrayBuffer(bin.length))
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i)
  return out
}

export function registrarServiceWorker() {
  if (!('serviceWorker' in navigator) || import.meta.env.DEV) return
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('/sw.js').catch(() => {
      /* sem service worker o CRM continua funcionando, só sem push e sem cache */
    })
  })
}

export async function estadoPush(): Promise<EstadoPush> {
  if (!('serviceWorker' in navigator) || !('PushManager' in window) || !('Notification' in window)) {
    return ehIOS() && !instalado() ? 'ios_fora_da_tela_inicio' : 'sem_suporte'
  }
  if (ehIOS() && !instalado()) return 'ios_fora_da_tela_inicio'
  if (Notification.permission === 'denied') return 'negado'
  if (Notification.permission === 'granted') {
    const reg = await navigator.serviceWorker.getRegistration('/sw.js')
    const sub = await reg?.pushManager.getSubscription()
    if (sub) return 'ativo'
  }
  return 'pedir'
}

/** Chamar só a partir de um toque (exigência do iOS). Pede a permissão, assina e grava o aparelho. */
export async function ativarPush(userId: string): Promise<void> {
  if (Notification.permission === 'default') {
    const r = await Notification.requestPermission()
    if (r !== 'granted') throw new Error('A permissão não foi concedida. Ative em Ajustes > Notificações > Sua Gráfica.')
  } else if (Notification.permission !== 'granted') {
    throw new Error('As notificações estão bloqueadas neste aparelho. Ative em Ajustes > Notificações > Sua Gráfica.')
  }
  const reg = (await navigator.serviceWorker.getRegistration('/sw.js')) ?? (await navigator.serviceWorker.register('/sw.js'))
  await navigator.serviceWorker.ready
  const { chave } = await invokeFunction<{ chave: string }>('alertas-enviar', { acao: 'chave_publica' })
  let sub = await reg.pushManager.getSubscription()
  if (!sub) sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: paraBytes(chave) })
  const j = sub.toJSON()
  if (!j.endpoint || !j.keys?.p256dh || !j.keys?.auth) throw new Error('O aparelho não devolveu as chaves da notificação. Tente de novo.')
  const { error } = await supabase.from('push_subscriptions').upsert(
    { user_id: userId, endpoint: j.endpoint, p256dh: j.keys.p256dh, auth: j.keys.auth, dispositivo: nomeDoAparelho(), ativo: true, falhas: 0, desativado_em: null },
    { onConflict: 'endpoint' },
  )
  if (error) throw new Error('Não foi possível salvar este aparelho: ' + error.message)
}

export async function desativarPush(): Promise<void> {
  const reg = await navigator.serviceWorker.getRegistration('/sw.js')
  const sub = await reg?.pushManager.getSubscription()
  if (sub) {
    await supabase.from('push_subscriptions').update({ ativo: false, desativado_em: new Date().toISOString() }).eq('endpoint', sub.endpoint)
    await sub.unsubscribe()
  }
}

/** Selo com o número de pendências no ícone do app (quando o aparelho suporta). */
export function atualizarSelo(n: number) {
  const nav = navigator as Navigator & { setAppBadge?: (n?: number) => Promise<void>; clearAppBadge?: () => Promise<void> }
  try {
    if (n > 0) void nav.setAppBadge?.(n)
    else void nav.clearAppBadge?.()
  } catch {
    /* sem suporte */
  }
}
