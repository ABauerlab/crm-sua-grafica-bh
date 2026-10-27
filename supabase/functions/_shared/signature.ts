// Validação do X-Hub-Signature-256 da Meta (HMAC SHA256 do corpo bruto com o App Secret).
// Sem dependências de Deno: roda também no Node para os testes.

const encoder = new TextEncoder()

function hexToBytes(hex: string): Uint8Array | null {
  if (hex.length % 2 !== 0 || !/^[0-9a-f]+$/i.test(hex)) return null
  const out = new Uint8Array(hex.length / 2)
  for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16)
  return out
}

export async function hmacSha256Hex(secret: string, body: string): Promise<string> {
  const key = await crypto.subtle.importKey('raw', encoder.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
  const sig = new Uint8Array(await crypto.subtle.sign('HMAC', key, encoder.encode(body)))
  return Array.from(sig, (b) => b.toString(16).padStart(2, '0')).join('')
}

/** Compara em tempo constante usando crypto.subtle.verify. */
export async function verifySignature(rawBody: string, header: string | null, appSecret: string): Promise<boolean> {
  if (!header || !appSecret || !header.startsWith('sha256=')) return false
  const provided = hexToBytes(header.slice('sha256='.length))
  if (!provided) return false
  const key = await crypto.subtle.importKey('raw', encoder.encode(appSecret), { name: 'HMAC', hash: 'SHA-256' }, false, ['verify'])
  return crypto.subtle.verify('HMAC', key, provided, encoder.encode(rawBody))
}
