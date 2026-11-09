// Utilitários das rotas /api/v1 (rodam só no servidor da loja). Só a chave publicável: as regras ficam no banco.
import { NextResponse } from 'next/server'

const URL_SUPABASE = process.env.NEXT_PUBLIC_SUPABASE_URL
const CHAVE = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY

export const ERROS: Record<string, [number, string]> = {
  produto_nao_encontrado: [404, 'Produto não encontrado.'],
  produto_indisponivel: [409, 'Produto indisponível no momento.'],
  arte_invalida: [400, 'Arte inválida. Use pronta, conferencia ou criacao.'],
  cep_invalido: [400, 'CEP inválido.'],
  itens_invalidos: [400, 'Informe de 1 a 10 itens com ref e quantidade.'],
}

export function erro(status: number, mensagem: string, extra: Record<string, unknown> = {}) {
  return NextResponse.json({ error: mensagem, ...extra }, { status })
}

/** Chama uma função do banco com a chave publicável. */
export async function rpc<T>(fn: string, args: Record<string, unknown>): Promise<{ ok: true; data: T } | { ok: false; status: number }> {
  if (!URL_SUPABASE || !CHAVE) return { ok: false, status: 503 }
  try {
    const res = await fetch(`${URL_SUPABASE}/rest/v1/rpc/${fn}`, {
      method: 'POST',
      headers: { apikey: CHAVE, Authorization: `Bearer ${CHAVE}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(args),
      cache: 'no-store',
    })
    if (!res.ok) return { ok: false, status: res.status >= 500 ? 502 : res.status }
    return { ok: true, data: (await res.json()) as T }
  } catch {
    return { ok: false, status: 502 }
  }
}

/** Repassa o checkout para a Edge Function loja-checkout (a service role fica só no Supabase). */
export const checkout = (body: unknown) => urlFuncao('loja-checkout', body)

/** Chama uma Edge Function pública da loja com a chave publicável. */
export async function urlFuncao(nome: 'loja-checkout' | 'loja-frete', body: unknown): Promise<{ status: number; data: unknown }> {
  if (!URL_SUPABASE || !CHAVE) return { status: 503, data: { error: 'Loja em manutenção.' } }
  try {
    const res = await fetch(`${URL_SUPABASE}/functions/v1/${nome}`, {
      method: 'POST',
      headers: { apikey: CHAVE, Authorization: `Bearer ${CHAVE}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
      cache: 'no-store',
    })
    return { status: res.status, data: await res.json().catch(() => ({ error: 'Resposta inválida do servidor.' })) }
  } catch {
    return { status: 502, data: { error: 'Servidor de pedidos indisponível. Tente de novo.' } }
  }
}

// Limite simples por IP (memória do processo): protege o banco de rajadas. O limite definitivo do checkout está no banco.
const janelas = new Map<string, { inicio: number; n: number }>()
export function limitar(req: Request, chave: string, maximo: number, janelaMs = 60_000): boolean {
  const ip = (req.headers.get('x-forwarded-for') ?? '').split(',')[0].trim() || req.headers.get('x-real-ip') || 'local'
  const k = `${chave}:${ip}`
  const agora = Date.now()
  const j = janelas.get(k)
  if (!j || agora - j.inicio > janelaMs) { janelas.set(k, { inicio: agora, n: 1 }); if (janelas.size > 5000) janelas.clear(); return true }
  j.n++
  return j.n <= maximo
}

/** Resposta do banco { ok:false, erro } -> HTTP. */
export function respostaBanco(d: { ok?: boolean; erro?: string; [k: string]: unknown }, cache: string) {
  if (d && d.ok === false) {
    const [status, msg] = ERROS[d.erro ?? ''] ?? [400, 'Requisição inválida.']
    return erro(status, msg, d.ref ? { ref: d.ref } : {})
  }
  return NextResponse.json(d, { headers: { 'Cache-Control': cache } })
}
