import { corsHeaders, json, requireOwnerOrServer, serviceClient } from '../_shared/http.ts'

// Extrato do Mercado Pago para o Financeiro: lê os pagamentos recentes da conta (bruto, taxa real, líquido, estornos)
// e o saldo, e grava em mp_movimentos e mp_saldo_historico. Roda sozinho a cada 5 minutos (x-cron-secret) e pelo
// botão "Atualizar agora" (dono). O token fica no servidor e nada dele sai daqui.
const API = 'https://api.mercadopago.com'
const num = (v: unknown): number => { const n = Number(v); return Number.isFinite(n) ? n : 0 }
const arred = (n: number): number => Math.round(n * 100) / 100

async function mp(path: string, token: string): Promise<{ status: number; data: Record<string, any> }> {
  const res = await fetch(`${API}${path}`, { headers: { Authorization: `Bearer ${token}` } })
  return { status: res.status, data: await res.json().catch(() => ({})) }
}

function tipoDe(p: Record<string, any>): 'recebimento' | 'estorno' | 'contestacao' | 'pendente' | 'recusado' {
  const s = String(p.status ?? '')
  if (s === 'charged_back') return 'contestacao'
  if (s === 'refunded' || (num(p.transaction_amount_refunded) > 0 && s !== 'approved')) return 'estorno'
  if (s === 'approved' || s === 'authorized') return 'recebimento'
  if (s === 'rejected' || s === 'cancelled') return 'recusado'
  return 'pendente'
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)
  const db = serviceClient()
  const cronSecret = Deno.env.get('CRON_SECRET')
  const sent = req.headers.get('x-cron-secret')
  const fromCron = !!cronSecret && !!sent && sent.length === cronSecret.length && sent === cronSecret
  if (!fromCron && !(await requireOwnerOrServer(req, db))) return json({ error: 'Não autorizado.' }, 401)

  const modo = Deno.env.get('MP_MODO') === 'producao' ? 'producao' : 'teste'
  const token = Deno.env.get(modo === 'producao' ? 'MP_ACCESS_TOKEN_PRODUCAO' : 'MP_ACCESS_TOKEN_TESTE')
  if (!token) return json({ ok: false, error: 'Mercado Pago não configurado no servidor.' }, 500)

  const input = await req.json().catch(() => ({})) as { dias?: number }
  const dias = Math.min(Math.max(Math.floor(Number(input.dias) || 3), 1), 90)

  let lidos = 0
  let gravados = 0
  const linhas: Record<string, unknown>[] = []
  for (let offset = 0; offset < 1000; offset += 100) {
    const { status, data } = await mp(`/v1/payments/search?sort=date_last_updated&criteria=desc&range=date_last_updated&begin_date=NOW-${dias}DAYS&end_date=NOW&limit=100&offset=${offset}`, token)
    if (status === 401 || status === 403) return json({ ok: false, error: 'O token do Mercado Pago não tem permissão para ler os pagamentos.' }, 500)
    if (status !== 200) return json({ ok: false, error: 'Mercado Pago indisponível agora.' }, 502)
    const lista = (data.results ?? []) as Record<string, any>[]
    for (const p of lista) {
      lidos++
      const taxa = (Array.isArray(p.fee_details) ? p.fee_details : []).reduce((a: number, d: any) => a + num(d?.amount), 0)
      const bruto = num(p.transaction_amount)
      const liq = p.transaction_details?.net_received_amount
      linhas.push({
        mp_payment_id: String(p.id), modo, tipo: tipoDe(p), status: String(p.status ?? 'desconhecido'),
        data: p.date_approved ?? p.date_created ?? new Date().toISOString(), liberacao: p.money_release_date ?? null,
        bruto: arred(bruto), taxa: arred(taxa), liquido: liq === undefined || liq === null ? null : arred(num(liq)),
        estornado: arred(num(p.transaction_amount_refunded)),
        metodo: p.payment_method_id ?? null, referencia: p.external_reference ?? null,
        descricao: typeof p.description === 'string' ? p.description.slice(0, 120) : null, atualizado_em: new Date().toISOString(),
      })
    }
    if (lista.length < 100) break
  }
  if (linhas.length) {
    const { error } = await db.from('mp_movimentos').upsert(linhas, { onConflict: 'mp_payment_id' })
    if (error) return json({ ok: false, error: 'Não consegui gravar o extrato.' }, 500)
    gravados = linhas.length
    await db.rpc('mp_movimentos_vincular')
  }

  let saldo: Record<string, number> | null = null
  const b = await mp('/users/me/mercadopago_account/balance', token)
  if (b.status === 200) {
    saldo = { disponivel: arred(num(b.data.available_balance)), a_liberar: arred(num(b.data.unavailable_balance)), total: arred(num(b.data.total_amount)) }
    // Só guarda um novo ponto quando o saldo mudou ou já faz mais de 1 hora do último (evita 288 linhas por dia iguais).
    const { data: ult } = await db.from('mp_saldo_historico').select('disponivel, a_liberar, capturado_em').eq('modo', modo).order('capturado_em', { ascending: false }).limit(1).maybeSingle()
    const mudou = !ult || num(ult.disponivel) !== saldo.disponivel || num(ult.a_liberar) !== saldo.a_liberar || Date.now() - new Date(ult.capturado_em).getTime() > 3_600_000
    if (mudou) await db.from('mp_saldo_historico').insert({ modo, ...saldo })
  }
  return json({ ok: true, modo, dias, lidos, gravados, saldo, saldo_indisponivel: saldo ? undefined : 'O token não tem permissão para ver o saldo.' })
})
