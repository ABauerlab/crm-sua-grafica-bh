// Web Push (padrão, com VAPID). Chaves: segredos VAPID_PUBLIC_KEY e VAPID_PRIVATE_KEY; sem eles, a função gera um par na primeira vez
// e guarda em public.app_segredos (tabela fechada: só a service role lê). Nada disso fica no repositório nem no front.
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2'
import webpush from 'npm:web-push@3.6.7'

const b64u = (b: Uint8Array): string => btoa(String.fromCharCode(...b)).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '')
const deb64u = (s: string): Uint8Array => Uint8Array.from(atob(s.replaceAll('-', '+').replaceAll('_', '/')), (c) => c.charCodeAt(0))

export interface Vapid {
  publica: string
  privada: string
  assunto: string
}

let cache: Vapid | null = null

export async function vapid(db: SupabaseClient): Promise<Vapid> {
  if (cache) return cache
  const assunto = Deno.env.get('VAPID_SUBJECT') || 'https://crm.suagraficabh.com.br'
  const pub = Deno.env.get('VAPID_PUBLIC_KEY')
  const priv = Deno.env.get('VAPID_PRIVATE_KEY')
  if (pub && priv) return (cache = { publica: pub, privada: priv, assunto })

  const { data } = await db.from('app_segredos').select('chave, valor').in('chave', ['vapid_publica', 'vapid_privada'])
  const m = Object.fromEntries((data ?? []).map((r: { chave: string; valor: string }) => [r.chave, r.valor]))
  if (m.vapid_publica && m.vapid_privada) return (cache = { publica: m.vapid_publica, privada: m.vapid_privada, assunto })

  const par = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify'])
  const jwk = await crypto.subtle.exportKey('jwk', par.privateKey)
  const publica = b64u(new Uint8Array([4, ...deb64u(jwk.x!), ...deb64u(jwk.y!)]))
  const privada = jwk.d!
  // on conflict do nothing: se duas chamadas gerarem ao mesmo tempo, vale a primeira gravada
  await db.from('app_segredos').upsert([{ chave: 'vapid_publica', valor: publica }, { chave: 'vapid_privada', valor: privada }], { onConflict: 'chave', ignoreDuplicates: true })
  const { data: again } = await db.from('app_segredos').select('chave, valor').in('chave', ['vapid_publica', 'vapid_privada'])
  const f = Object.fromEntries((again ?? []).map((r: { chave: string; valor: string }) => [r.chave, r.valor]))
  return (cache = { publica: f.vapid_publica, privada: f.vapid_privada, assunto })
}

export interface Assinatura {
  id: string
  endpoint: string
  p256dh: string
  auth: string
  falhas: number
}

export interface ResultadoPush {
  aparelhos: number
  enviados: number
  falhas: number
  removidos: number
}

/** Envia para as assinaturas. 404/410 = assinatura morta: desativada na hora. Outras falhas contam; 5 seguidas desativam. */
export async function enviarPush(
  db: SupabaseClient,
  assinaturas: Assinatura[],
  payload: Record<string, unknown>,
  opts: { urgente?: boolean } = {},
): Promise<ResultadoPush> {
  const v = await vapid(db)
  webpush.setVapidDetails(v.assunto, v.publica, v.privada)
  const r: ResultadoPush = { aparelhos: assinaturas.length, enviados: 0, falhas: 0, removidos: 0 }
  for (const s of assinaturas) {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, JSON.stringify(payload), {
        TTL: 60 * 60 * 24,
        urgency: opts.urgente ? 'high' : 'normal',
      })
      r.enviados++
      await db.from('push_subscriptions').update({ falhas: 0, ultimo_envio_em: new Date().toISOString() }).eq('id', s.id)
    } catch (e) {
      const status = Number((e as { statusCode?: number }).statusCode)
      if (status === 404 || status === 410) {
        r.removidos++
        await db.from('push_subscriptions').update({ ativo: false, desativado_em: new Date().toISOString() }).eq('id', s.id)
      } else {
        r.falhas++
        console.error('Falha ao enviar push:', status || 'rede')
        const falhas = s.falhas + 1
        await db.from('push_subscriptions').update({ falhas, ...(falhas >= 5 ? { ativo: false, desativado_em: new Date().toISOString() } : {}) }).eq('id', s.id)
      }
    }
  }
  return r
}

export async function assinaturasAtivas(db: SupabaseClient, userId?: string): Promise<Assinatura[]> {
  let q = db.from('push_subscriptions').select('id, endpoint, p256dh, auth, falhas').eq('ativo', true)
  if (userId) q = q.eq('user_id', userId)
  const { data } = await q
  return (data ?? []) as Assinatura[]
}
