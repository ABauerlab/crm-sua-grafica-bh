import { corsHeaders, json, requireOwnerOrServer, serviceClient } from '../_shared/http.ts'

// Saldo da conta do Mercado Pago para a tela Financeiro. Só dono ou service role. O token fica no servidor e nada dele sai daqui.
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)
  const db = serviceClient()
  if (!(await requireOwnerOrServer(req, db))) return json({ error: 'Não autorizado.' }, 401)

  const modo = Deno.env.get('MP_MODO') === 'producao' ? 'PRODUCAO' : 'TESTE'
  const token = Deno.env.get(`MP_ACCESS_TOKEN_${modo}`)
  if (!token) return json({ ok: false, error: 'Mercado Pago não configurado no servidor.' }, 500)
  try {
    const res = await fetch('https://api.mercadopago.com/users/me/mercadopago_account/balance', { headers: { Authorization: `Bearer ${token}` } })
    const d = await res.json().catch(() => ({})) as Record<string, any>
    if (!res.ok) {
      const semPermissao = res.status === 401 || res.status === 403
      return json({ ok: false, modo: modo.toLowerCase(), error: semPermissao ? 'O token do Mercado Pago não tem permissão para ver o saldo.' : 'Mercado Pago indisponível agora.' })
    }
    return json({ ok: true, modo: modo.toLowerCase(), disponivel: Number(d.available_balance ?? 0), a_liberar: Number(d.unavailable_balance ?? 0), total: Number(d.total_amount ?? 0), moeda: d.currency_id ?? 'BRL' })
  } catch {
    return json({ ok: false, error: 'Mercado Pago indisponível agora.' })
  }
})
