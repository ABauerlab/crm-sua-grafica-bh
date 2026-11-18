// Checkout próprio (/pagar/<token>): carrega o resumo público do pedido, salva os dados do cliente no CRM,
// muda a arte, adiciona ou remove sugestões e informa o status do pagamento. Público (o token é o comprovante),
// sem nenhum dado interno na resposta. Logs sem dados pessoais.
import { corsHeaders, json, serviceClient } from '../_shared/http.ts'
import { documentoValido, emailValido, TOKEN_CHECKOUT } from '../_shared/checkout.ts'
import { mpConfig } from '../_shared/mpconfig.ts'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)
  let b: Record<string, any>
  try {
    b = await req.json()
  } catch {
    return json({ error: 'Corpo da requisição inválido.' }, 400)
  }
  const token = String(b.token ?? '')
  if (!TOKEN_CHECKOUT.test(token)) return json({ ok: false, erro: 'link_invalido' }, 404)
  const db = serviceClient()

  const rpc = async (fn: string, args: Record<string, unknown>) => {
    const { data, error } = await db.rpc(fn, args)
    if (error) {
      console.error('checkout-dados: falha no banco', fn, error.code)
      return json({ ok: false, erro: 'indisponivel', mensagem: 'Não conseguimos carregar agora. Tente de novo em instantes.' }, 503)
    }
    const r = data as Record<string, any>
    return json(r, r?.ok === false ? (r.erro === 'link_invalido' ? 404 : 409) : 200)
  }

  switch (b.acao) {
    case 'carregar': {
      const { data, error } = await db.rpc('checkout_carregar', { p_token: token })
      if (error) {
        console.error('checkout-dados: carregar falhou', error.code)
        return json({ ok: false, erro: 'indisponivel', mensagem: 'Não conseguimos carregar o pedido agora. Tente de novo em instantes.' }, 503)
      }
      const r = data as Record<string, any>
      if (r?.ok === false) return json(r, 404)
      // A chave PÚBLICA do Mercado Pago é feita para ir ao navegador; a de acesso nunca sai daqui
      const cfg = mpConfig()
      const chave = cfg.modo ? Deno.env.get(`MP_PUBLIC_KEY_${cfg.modo === 'teste' ? 'TESTE' : 'PRODUCAO'}`) ?? null : null
      return json({ ...r, mp: { chave_publica: chave, modo: cfg.modo } })
    }
    case 'status':
      return rpc('checkout_status', { p_token: token })
    case 'salvar': {
      if (String(b.nome ?? '').trim().length < 3) return json({ ok: false, erro: 'nome_invalido', mensagem: 'Informe seu nome completo.' }, 400)
      if (!emailValido(b.email)) return json({ ok: false, erro: 'email_invalido', mensagem: 'Confira o e-mail.' }, 400)
      if (!documentoValido(b.documento)) return json({ ok: false, erro: 'documento_invalido', mensagem: 'CPF ou CNPJ inválido. Confira os números.' }, 400)
      return rpc('checkout_salvar_dados', { p_token: token, p_nome: String(b.nome), p_email: String(b.email), p_documento: String(b.documento) })
    }
    case 'arte':
      return rpc('checkout_definir_arte', { p_token: token, p_arte: String(b.arte ?? '') })
    case 'adicionar':
      return rpc('checkout_adicionar_produto', { p_token: token, p_ref: String(b.ref ?? '').slice(0, 40) })
    case 'remover':
      if (!UUID.test(String(b.item ?? ''))) return json({ ok: false, erro: 'item_invalido' }, 400)
      return rpc('checkout_remover_item', { p_token: token, p_item: String(b.item) })
    default:
      return json({ error: 'Ação inválida.' }, 400)
  }
})
