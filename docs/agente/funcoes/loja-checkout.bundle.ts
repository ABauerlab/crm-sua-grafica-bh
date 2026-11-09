// GERADO por "node scripts/bundle-funcao.ts loja-checkout". NÃO edite aqui: edite supabase/functions/ e gere de novo.
// Painel do Supabase > Edge Functions > Deploy a new function (ou Code > Deploy updates) > Via Editor. Nome: loja-checkout. "Verify JWT" desligado (a função confere o dono ou a service role).
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2'
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-cron-secret',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}

/** Cliente com service role: ignora RLS. Use apenas dentro das Edge Functions. */
function serviceClient(): SupabaseClient {
  return createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
    auth: { persistSession: false, autoRefreshToken: false },
  })
}

interface Staff {
  userId: string
  role: 'admin' | 'agent'
}

/** Valida o JWT do chamador e exige que ele exista em profiles. */
async function requireStaff(req: Request, db: SupabaseClient): Promise<Staff | null> {
  const token = req.headers.get('Authorization')?.replace(/^Bearer\s+/i, '')
  if (!token) return null
  const { data: userData, error } = await db.auth.getUser(token)
  if (error || !userData.user) return null
  const { data: profile } = await db.from('profiles').select('id, role').eq('id', userData.user.id).maybeSingle()
  if (!profile) return null
  return { userId: profile.id, role: profile.role }
}

function requireEnv(...names: string[]): Record<string, string> | null {
  const out: Record<string, string> = {}
  for (const n of names) {
    const v = Deno.env.get(n)
    if (!v) {
      console.error(`Segredo ausente: ${n}`)
      return null
    }
    out[n] = v
  }
  return out
}

/** Confere uma chave de serviço perguntando ao próprio Supabase: só a service role passa no endpoint de administração do Auth. */
async function ehServiceRole(token: string): Promise<boolean> {
  const url = Deno.env.get('SUPABASE_URL')
  if (!url || token.length < 20) return false
  try {
    const res = await fetch(`${url}/auth/v1/admin/users?page=1&per_page=1`, { headers: { apikey: token, Authorization: `Bearer ${token}` } })
    return res.ok
  } catch {
    return false
  }
}

/** Chamador autorizado a cobrar: o dono logado (JWT) ou outro servidor da própria Sua Gráfica usando a service role key. */
async function requireOwnerOrServer(req: Request, db: SupabaseClient): Promise<'dono' | 'servidor' | null> {
  const token = req.headers.get('Authorization')?.replace(/^Bearer\s+/i, '')
  if (!token) return null
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
  if (serviceKey && token.length === serviceKey.length && token === serviceKey) return 'servidor'
  const { data: userData, error } = await db.auth.getUser(token)
  // Não é um usuário: pode ser a service role de outro formato (a injetada na função nem sempre é igual à do painel)
  if (error || !userData.user) return (await ehServiceRole(token)) ? 'servidor' : null
  const { data: profile } = await db.from('profiles').select('id').eq('id', userData.user.id).maybeSingle()
  if (!profile) return null
  const { data: owner } = await db.from('app_settings').select('value').eq('key', 'owner').maybeSingle()
  const ownerEmail = String((owner?.value as { email?: string } | null)?.email ?? '').toLowerCase()
  if (ownerEmail && (userData.user.email ?? '').toLowerCase() !== ownerEmail) return null
  return 'dono'
}

/** Só a service role (outro servidor da própria Sua Gráfica, como o n8n). Nenhum usuário logado passa. */
async function requireServiceRole(req: Request): Promise<boolean> {
  const token = req.headers.get('Authorization')?.replace(/^Bearer\s+/i, '')
  if (!token) return false
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
  if (serviceKey && token.length === serviceKey.length && token === serviceKey) return true
  return ehServiceRole(token)
}

// Validação do pedido do site (checkout). Funções puras: usadas pela Edge Function loja-checkout e testadas em Node.

type Arte = 'pronta' | 'conferencia' | 'criacao'
interface PedidoSite {
  cliente: { whatsapp: string; nome: string; email: string | null; documento: string | null }
  itens: { ref: string; quantidade: number }[]
  opcoes: { arte: Arte; entrega: 'retirada' | 'entrega'; cep: string | null }
}

const digitos = (s: unknown) => String(s ?? '').replace(/\D/g, '')

/** (31) 97561-8243 -> 5531975618243. Aceita com ou sem 55; exige DDD válido e 8 ou 9 dígitos. */
function normalizarWhatsapp(v: unknown): string | null {
  let d = digitos(v)
  if (d.length === 10 || d.length === 11) d = `55${d}`
  return /^55[1-9][0-9]9?[0-9]{8}$/.test(d) ? d : null
}

function cpfValido(v: string): boolean {
  const d = digitos(v)
  if (d.length !== 11 || /^(\d)\1+$/.test(d)) return false
  const dv = (n: number) => { let s = 0; for (let i = 0; i < n; i++) s += Number(d[i]) * (n + 1 - i); const r = (s * 10) % 11; return r === 10 ? 0 : r }
  return dv(9) === Number(d[9]) && dv(10) === Number(d[10])
}

function cnpjValido(v: string): boolean {
  const d = digitos(v)
  if (d.length !== 14 || /^(\d)\1+$/.test(d)) return false
  const calc = (n: number) => {
    const pesos = n === 12 ? [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2] : [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]
    const s = pesos.reduce((acc, p, i) => acc + Number(d[i]) * p, 0)
    const r = s % 11
    return r < 2 ? 0 : 11 - r
  }
  return calc(12) === Number(d[12]) && calc(13) === Number(d[13])
}

const REF = /^[0-9a-f]{12}$/

/** Confere o corpo do checkout. Devolve o pedido limpo ou a lista de erros (mensagens prontas para a tela). */
function validarPedido(body: unknown): { ok: true; pedido: PedidoSite } | { ok: false; erros: string[] } {
  const b = (body ?? {}) as Record<string, any>
  const erros: string[] = []
  const c = (b.cliente ?? {}) as Record<string, unknown>
  const whatsapp = normalizarWhatsapp(c.whatsapp)
  if (!whatsapp) erros.push('Informe um WhatsApp válido com DDD.')
  const nome = String(c.nome ?? '').trim().replace(/\s+/g, ' ')
  if (nome.length < 3 || nome.length > 120) erros.push('Informe o nome completo.')
  const email = String(c.email ?? '').trim().toLowerCase() || null
  if (email && !/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email)) erros.push('E-mail inválido.')
  const doc = digitos(c.documento) || null
  if (doc && !(doc.length === 11 ? cpfValido(doc) : doc.length === 14 ? cnpjValido(doc) : false)) erros.push('CPF ou CNPJ inválido.')
  const itensIn = Array.isArray(b.itens) ? b.itens : []
  if (itensIn.length < 1 || itensIn.length > 10) erros.push('O carrinho precisa ter de 1 a 10 itens.')
  const itens = itensIn.map((i: Record<string, unknown>) => ({ ref: String(i?.ref ?? '').trim(), quantidade: Math.trunc(Number(i?.quantidade ?? 1)) }))
  if (itens.some((i) => !REF.test(i.ref))) erros.push('Produto inválido no carrinho.')
  if (itens.some((i) => !Number.isFinite(i.quantidade) || i.quantidade < 1 || i.quantidade > 100)) erros.push('Quantidade inválida no carrinho.')
  const o = (b.opcoes ?? {}) as Record<string, unknown>
  const arte = String(o.arte ?? 'pronta') as Arte
  if (!['pronta', 'conferencia', 'criacao'].includes(arte)) erros.push('Escolha uma opção de arte.')
  const entrega = String(o.entrega ?? 'retirada') as 'retirada' | 'entrega'
  if (!['retirada', 'entrega'].includes(entrega)) erros.push('Escolha retirada ou entrega.')
  const cep = digitos(o.cep) || null
  if (cep && cep.length !== 8) erros.push('CEP inválido.')
  if (entrega === 'entrega' && !cep) erros.push('Informe o CEP para a entrega.')
  if (erros.length) return { ok: false, erros }
  return { ok: true, pedido: { cliente: { whatsapp: whatsapp!, nome, email, documento: doc }, itens, opcoes: { arte, entrega, cep } } }
}

/** Códigos do banco -> mensagem para o cliente (sem detalhe interno). */
function mensagemErro(codigo: string | undefined): { status: number; mensagem: string } {
  switch (codigo) {
    case 'muitas_tentativas': return { status: 429, mensagem: 'Muitas tentativas seguidas. Aguarde alguns minutos ou fale com a gente no WhatsApp.' }
    case 'produto_nao_encontrado': case 'produto_indisponivel': return { status: 409, mensagem: 'Um dos produtos do carrinho não está mais disponível. Atualize o carrinho.' }
    case 'orcamento_bloqueado': return { status: 422, mensagem: 'Não conseguimos fechar este pedido pelo site. Fale com a gente no WhatsApp que resolvemos na hora.' }
    case 'whatsapp_invalido': return { status: 400, mensagem: 'Informe um WhatsApp válido com DDD.' }
    case 'cep_obrigatorio_para_entrega': return { status: 400, mensagem: 'Informe o CEP para a entrega.' }
    default: return { status: 400, mensagem: 'Não foi possível criar o pedido. Confira os dados e tente de novo.' }
  }
}

// E-commerce Fase 4: checkout do site. Valida o carrinho, monta orçamento e pedido pelo banco (mesma trava de lucro do CRM)
// e devolve o link do Mercado Pago (mp-criar-link chamado por dentro com a service role). Público, com limites no banco.
// Logs sem dados pessoais.
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)
  let body: unknown
  try {
    body = await req.json()
  } catch {
    return json({ error: 'Corpo da requisição inválido.' }, 400)
  }
  const v = validarPedido(body)
  if (!v.ok) return json({ error: v.erros[0], erros: v.erros }, 400)
  const p = v.pedido

  const db = serviceClient()
  const { data: prep, error } = await db.rpc('loja_checkout_preparar', { p_cliente: p.cliente, p_itens: p.itens, p_opcoes: p.opcoes })
  if (error) {
    console.error('loja-checkout: preparar falhou', error.code)
    return json({ error: 'Não foi possível criar o pedido agora. Tente de novo em instantes.' }, 500)
  }
  const r = prep as { ok: boolean; erro?: string; pedido_id?: string; numero?: number; total?: number; prazo?: string; data_prevista?: string }
  if (!r.ok) {
    const m = mensagemErro(r.erro)
    console.log(`loja-checkout: recusado (${r.erro})`)
    return json({ error: m.mensagem }, m.status)
  }

  const res = await fetch(`${Deno.env.get('SUPABASE_URL')}/functions/v1/mp-criar-link`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')}` },
    body: JSON.stringify({ pedido_id: r.pedido_id }),
  })
  const link = await res.json().catch(() => ({})) as { url?: string; init_point?: string; link?: string; error?: string }
  const url = link.url ?? link.init_point ?? link.link
  if (!res.ok || !url) {
    console.error('loja-checkout: link do Mercado Pago falhou', res.status)
    return json({ error: 'Pedido criado, mas o link de pagamento não saiu. Vamos te chamar no WhatsApp para finalizar.', numero: r.numero }, 502)
  }
  console.log('loja-checkout: pedido criado')
  return json({ ok: true, numero: r.numero, total: r.total, prazo: r.prazo, data_prevista: r.data_prevista, link_pagamento: url })
})
