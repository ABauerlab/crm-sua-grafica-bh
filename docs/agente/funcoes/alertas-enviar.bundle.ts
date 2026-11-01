// GERADO por "node scripts/bundle-funcao.ts alertas-enviar". NÃO edite aqui: edite supabase/functions/ e gere de novo.
// Painel do Supabase > Edge Functions > Deploy a new function (ou Code > Deploy updates) > Via Editor. Nome: alertas-enviar. "Verify JWT" desligado (a função confere o dono ou a service role).
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2'
import webpush from 'npm:web-push@3.6.7'
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

// Montagem dos avisos ao dono (push e WhatsApp). Funções puras: testadas em Node (scripts/test-alertas.ts), usadas pela Edge Function alertas-enviar.
// Nunca entram aqui custo, piso, margem de fornecedor nem endereço de retirada: o lucro líquido é do dono e só vai para o número dele.

interface AlertaFila {
  id: string
  tipo: string
  gravidade: 'alta' | 'baixa'
  motivo: string
  dados: Record<string, unknown>
  conversation_id?: string | null
  order_id?: string | null
  enviar_push: boolean
  enviar_whatsapp: boolean
  badge?: number
}

interface PushPayload {
  title: string
  body: string
  url: string
  tag: string
  tipo: string
  badge: number
  gravidade: string
}

const str = (v: unknown, fallback = ''): string => (typeof v === 'string' && v.trim() ? v.trim() : fallback)
const corta = (s: string, n: number): string => (s.length <= n ? s : s.slice(0, n - 1).trimEnd() + '…')

function montarPush(a: AlertaFila): PushPayload {
  const d = a.dados ?? {}
  const cliente = str(d.cliente, 'Cliente')
  const url = str(d.url, '/painel')
  let title: string
  let body: string
  switch (a.tipo) {
    case 'pedido_pago':
      title = `${d.teste ? '[TESTE] ' : ''}Pedido pago: ${str(d.pedido, 'novo pedido')}`
      body = `${cliente} pagou ${str(d.valor, '')}. Lucro líquido ${str(d.lucro_liquido, 'a confirmar')}. Previsão ${str(d.previsao, 'a confirmar')}.`
      break
    case 'nova_mensagem_humano':
      title = 'Nova mensagem'
      body = `${cliente} escreveu e está esperando você.`
      break
    case 'resumo':
      title = 'Resumo de avisos'
      body = a.motivo
      break
    case 'teste_notificacao':
      title = 'Notificação de teste'
      body = 'Deu certo: este aparelho recebe os avisos da Sua Gráfica BH.'
      break
    default:
      title = `Atenção: ${cliente}`
      body = a.motivo
  }
  return {
    title: corta(title, 60),
    body: corta(body, 170),
    url,
    // mesmo tipo e mesma conversa/pedido: a notificação nova substitui a anterior
    tag: `${a.tipo}:${a.conversation_id ?? a.order_id ?? 'geral'}`,
    tipo: a.tipo,
    badge: Math.max(0, Number(a.badge ?? 0)),
    gravidade: a.gravidade,
  }
}

/** Variáveis de template: sem quebra de linha, tabulação nem 4 espaços seguidos (regra da Meta); nunca vazias. */
function varTemplate(v: unknown, max = 200): string {
  const s = String(v ?? '').replace(/[\r\n\t]+/g, ' ').replace(/ {2,}/g, ' ').trim()
  return corta(s || '-', max)
}

type TemplateDono = { name: 'pedido_pago_dono' | 'alerta_atencao_dono'; params: string[] }

/** pedido_pago_dono: cliente, itens, valor, lucro líquido, previsão, link. alerta_atencao_dono: cliente, motivo, link. */
function montarTemplate(a: AlertaFila): TemplateDono {
  const d = a.dados ?? {}
  if (a.tipo === 'pedido_pago') {
    return {
      name: 'pedido_pago_dono',
      params: [d.cliente, d.itens, d.valor, d.lucro_liquido, d.previsao, d.url].map((v, i) => varTemplate(v, i === 1 ? 300 : 200)),
    }
  }
  return { name: 'alerta_atencao_dono', params: [varTemplate(d.cliente ?? 'Resumo', 80), varTemplate(a.motivo, 300), varTemplate(d.url)] }
}

/** Texto livre (janela de 24 h do dono aberta). */
function montarTexto(a: AlertaFila): string {
  const d = a.dados ?? {}
  const url = str(d.url)
  if (a.tipo === 'pedido_pago') {
    return [
      `${d.teste ? '[TESTE] ' : ''}Pedido pago por ${str(d.cliente, 'cliente')}.`,
      `Itens: ${str(d.itens, '-')}`,
      `Valor: ${str(d.valor, '-')} (${str(d.metodo, 'método não informado')})`,
      `Lucro líquido: ${str(d.lucro_liquido, 'a confirmar')}`,
      `Previsão: ${str(d.previsao, 'a confirmar')}`,
      `Abra o pedido no CRM: ${url}`,
    ].join('\n')
  }
  if (a.tipo === 'resumo') return `Resumo de avisos (${a.motivo})\nAbra o CRM: ${url}`
  return `Atenção no atendimento. Cliente: ${str(d.cliente, '-')}.\nMotivo: ${a.motivo}\nAbra no CRM: ${url}`
}

/** Mensagem ao cliente depois do pagamento. Sem SKU, custo, margem ou lucro. Endereço só aqui, depois de pago. */
function montarConfirmacaoCliente(i: {
  nome: string
  pedido: string
  previsao: string
  arte_status?: string | null
  entrega?: string | null
}): string {
  const arte =
    i.arte_status === 'aprovada'
      ? 'A sua arte já está aprovada.'
      : i.arte_status === 'enviada' || i.arte_status === 'em_criacao'
        ? 'A arte está em andamento e eu te aviso por aqui para você aprovar.'
        : 'Se você já tem a arte, é só enviar o arquivo aqui na conversa. Se ainda não tem, me avisa que a gente cria.'
  const entrega =
    i.entrega === 'uber'
      ? 'A entrega a gente combina por aqui assim que o pedido ficar pronto.'
      : 'Quando ficar pronto eu te aviso por aqui com o endereço e o horário de retirada.'
  return `Pagamento confirmado, ${i.nome}! Seu pedido ${i.pedido} já entrou na fila. Previsão de ficar pronto: ${i.previsao}. ${arte} ${entrega}`
}

/** Variáveis do template pedido_pago_confirmacao: nome, número do pedido, previsão. */
function templateConfirmacaoCliente(i: { nome: string; pedido: string; previsao: string }): string[] {
  return [varTemplate(i.nome, 60), varTemplate(i.pedido, 30), varTemplate(i.previsao, 30)]
}

/** O erro da Meta é definitivo para este canal (não adianta repetir)? Hoje: nenhum; o recuo do banco decide. */
function janelaAberta(janelaAte: string | null | undefined, agora = Date.now()): boolean {
  if (!janelaAte) return false
  const t = Date.parse(janelaAte)
  return Number.isFinite(t) && t > agora
}

// Web Push (padrão, com VAPID). Chaves: segredos VAPID_PUBLIC_KEY e VAPID_PRIVATE_KEY; sem eles, a função gera um par na primeira vez
// e guarda em public.app_segredos (tabela fechada: só a service role lê). Nada disso fica no repositório nem no front.
const b64u = (b: Uint8Array): string => btoa(String.fromCharCode(...b)).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '')
const deb64u = (s: string): Uint8Array => Uint8Array.from(atob(s.replaceAll('-', '+').replaceAll('_', '/')), (c) => c.charCodeAt(0))

interface Vapid {
  publica: string
  privada: string
  assunto: string
}

let cache: Vapid | null = null

async function vapid(db: SupabaseClient): Promise<Vapid> {
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

interface Assinatura {
  id: string
  endpoint: string
  p256dh: string
  auth: string
  falhas: number
}

interface ResultadoPush {
  aparelhos: number
  enviados: number
  falhas: number
  removidos: number
}

/** Envia para as assinaturas. 404/410 = assinatura morta: desativada na hora. Outras falhas contam; 5 seguidas desativam. */
async function enviarPush(
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

async function assinaturasAtivas(db: SupabaseClient, userId?: string): Promise<Assinatura[]> {
  let q = db.from('push_subscriptions').select('id, endpoint, p256dh, auth, falhas').eq('ativo', true)
  if (userId) q = q.eq('user_id', userId)
  const { data } = await q
  return (data ?? []) as Assinatura[]
}

// Envio pela API oficial do WhatsApp (Graph) usado pelos alertas e pela confirmação ao cliente. O token fica só no servidor.
const GRAPH = 'https://graph.facebook.com/v21.0'

interface WaEnv {
  WHATSAPP_TOKEN: string
  WHATSAPP_PHONE_NUMBER_ID: string
  WHATSAPP_WABA_ID?: string
}

interface WaResultado {
  ok: boolean
  wa_message_id?: string
  codigo?: number | null
  erro?: string
}

async function post(env: WaEnv, body: unknown): Promise<WaResultado> {
  try {
    const res = await fetch(`${GRAPH}/${env.WHATSAPP_PHONE_NUMBER_ID}/messages`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${env.WHATSAPP_TOKEN}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    })
    const r = await res.json().catch(() => ({}))
    if (!res.ok) {
      const codigo = Number(r?.error?.code) || null
      console.error('Erro da Meta ao enviar aviso:', codigo)
      return { ok: false, codigo, erro: `meta_${codigo ?? res.status}` }
    }
    return { ok: true, wa_message_id: r?.messages?.[0]?.id as string | undefined }
  } catch {
    return { ok: false, erro: 'rede' }
  }
}

const enviarTexto = (env: WaEnv, to: string, text: string) =>
  post(env, { messaging_product: 'whatsapp', to, type: 'text', text: { body: text, preview_url: false } })

const enviarTemplate = (env: WaEnv, to: string, name: string, params: string[], language = 'pt_BR') =>
  post(env, {
    messaging_product: 'whatsapp',
    to,
    type: 'template',
    template: {
      name,
      language: { code: language },
      components: [{ type: 'body', parameters: params.map((text) => ({ type: 'text', text })) }],
    },
  })

/** Status atual do template na Meta (atualiza o cache). null = não foi possível consultar (tenta enviar mesmo assim). */
async function statusTemplate(env: WaEnv, db: SupabaseClient, name: string, language = 'pt_BR'): Promise<string | null> {
  if (!env.WHATSAPP_WABA_ID) return null
  try {
    const res = await fetch(`${GRAPH}/${env.WHATSAPP_WABA_ID}/message_templates?name=${encodeURIComponent(name)}&fields=name,status,language,category,components&limit=10`, {
      headers: { Authorization: `Bearer ${env.WHATSAPP_TOKEN}` },
    })
    if (!res.ok) return null
    const r = await res.json()
    // deno-lint-ignore no-explicit-any
    const t = (r?.data ?? []).find((x: any) => x.name === name && x.language === language)
    if (!t) return 'NAO_ENCONTRADO'
    // deno-lint-ignore no-explicit-any
    const body = (t.components ?? []).find((c: any) => c.type === 'BODY')?.text as string | undefined
    await db.from('templates_cache').upsert({ name, language, category: t.category ?? null, status: t.status, body: body ?? null, synced_at: new Date().toISOString() })
    return String(t.status)
  } catch {
    return null
  }
}

// Dispatcher dos alertas ao dono: push (Web Push/VAPID) e WhatsApp (texto na janela de 24 h, senão template aprovado).
// processar: só service role (n8n, a cada minuto). teste e chave_publica: dono logado (Configurações > Notificações).
// Nenhum conteúdo de mensagem de cliente entra nos logs.

type Canal = { status: 'enviado' | 'falhou' | 'aguardando_template' | 'sem_aparelho'; erro?: string }

async function canalPush(db: ReturnType<typeof serviceClient>, a: AlertaFila): Promise<Canal> {
  const subs = await assinaturasAtivas(db)
  if (subs.length === 0) return { status: 'sem_aparelho', erro: 'nenhum aparelho com notificação ativa' }
  const r = await enviarPush(db, subs, { ...montarPush(a) }, { urgente: a.gravidade === 'alta' })
  if (r.enviados > 0) return { status: 'enviado' }
  if (r.removidos === r.aparelhos) return { status: 'sem_aparelho', erro: 'aparelhos desconectados' }
  return { status: 'falhou', erro: 'push recusado' }
}

async function canalWhatsApp(
  db: ReturnType<typeof serviceClient>,
  env: WaEnv,
  destino: { wa_id: string | null; janela_ate: string | null },
  a: AlertaFila,
): Promise<Canal> {
  if (!destino.wa_id) return { status: 'falhou', erro: 'whatsapp_dono não configurado' }
  if (janelaAberta(destino.janela_ate)) {
    const r = await enviarTexto(env, destino.wa_id, montarTexto(a))
    if (r.ok) return { status: 'enviado' }
    if (r.codigo !== 131047) return { status: 'falhou', erro: r.erro }
    // a janela fechou no meio do caminho: cai para o template
  }
  const t = montarTemplate(a)
  const st = await statusTemplate(env, db, t.name)
  if (st && st !== 'APPROVED') return { status: 'aguardando_template', erro: `template ${t.name}: ${st}` }
  const r = await enviarTemplate(env, destino.wa_id, t.name, t.params)
  return r.ok ? { status: 'enviado' } : { status: 'falhou', erro: r.erro }
}

async function processar(db: ReturnType<typeof serviceClient>, env: WaEnv | null, input: { varredura?: boolean }) {
  if (input.varredura) {
    await db.rpc('alertas_varredura')
    await db.from('push_subscriptions').delete().eq('ativo', false).lt('desativado_em', new Date(Date.now() - 30 * 86400_000).toISOString())
  }
  await db.rpc('alertas_resumo_montar')
  const { data: fila, error } = await db.rpc('alertas_proximos', { p_limite: 20 })
  if (error) return { ok: false, erro: 'Não foi possível ler a fila de alertas.' }
  const alertas = (fila ?? []) as AlertaFila[]
  let destino: { wa_id: string | null; janela_ate: string | null } | null = null
  const saida: { id: string; push?: string; whatsapp?: string }[] = []
  for (const a of alertas) {
    const item: { id: string; push?: string; whatsapp?: string } = { id: a.id }
    if (a.enviar_push) {
      const c = await canalPush(db, a)
      await db.rpc('alerta_resultado', { p_id: a.id, p_canal: 'push', p_status: c.status, p_erro: c.erro ?? null })
      item.push = c.status
    }
    if (a.enviar_whatsapp) {
      let c: Canal
      if (!env) c = { status: 'falhou', erro: 'segredos do WhatsApp ausentes' }
      else {
        destino ??= (await db.rpc('alerta_destino_dono')).data as { wa_id: string | null; janela_ate: string | null }
        c = await canalWhatsApp(db, env, destino, a)
      }
      await db.rpc('alerta_resultado', { p_id: a.id, p_canal: 'whatsapp', p_status: c.status, p_erro: c.erro ?? null })
      item.whatsapp = c.status
    }
    saida.push(item)
  }
  return { ok: true, processados: saida.length, resultado: saida }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)
  const input = (await req.json().catch(() => ({}))) as { acao?: string; varredura?: boolean }
  const acao = input.acao ?? 'processar'
  const db = serviceClient()

  if (acao === 'processar') {
    if (!(await requireServiceRole(req))) return json({ error: 'Não autorizado.' }, 401)
    const env = requireEnv('WHATSAPP_TOKEN', 'WHATSAPP_PHONE_NUMBER_ID') as WaEnv | null
    if (env) env.WHATSAPP_WABA_ID = Deno.env.get('WHATSAPP_WABA_ID') ?? undefined
    return json(await processar(db, env, input))
  }

  const staff = await requireStaff(req, db)
  if (!staff) return json({ error: 'Não autorizado.' }, 401)

  if (acao === 'chave_publica') return json({ chave: (await vapid(db)).publica })

  if (acao === 'teste') {
    // Mesmo caminho dos alertas reais, mas direto: vai só para os aparelhos de quem pediu e para o WhatsApp do dono.
    const teste: AlertaFila = {
      id: 'teste', tipo: 'teste_notificacao', gravidade: 'alta', motivo: 'Teste de notificação pelo CRM.', enviar_push: true, enviar_whatsapp: true,
      dados: { cliente: 'Teste', url: 'https://crm.suagraficabh.com.br/configuracoes' },
    }
    const subs = await assinaturasAtivas(db, staff.userId)
    const push = subs.length
      ? await enviarPush(db, subs, { ...montarPush(teste) }, { urgente: true })
      : { aparelhos: 0, enviados: 0, falhas: 0, removidos: 0 }
    let whatsapp: Canal = { status: 'falhou', erro: 'segredos do WhatsApp ausentes' }
    const env = requireEnv('WHATSAPP_TOKEN', 'WHATSAPP_PHONE_NUMBER_ID') as WaEnv | null
    if (env) {
      env.WHATSAPP_WABA_ID = Deno.env.get('WHATSAPP_WABA_ID') ?? undefined
      const destino = (await db.rpc('alerta_destino_dono')).data as { wa_id: string | null; janela_ate: string | null }
      whatsapp = await canalWhatsApp(db, env, destino, teste)
    }
    return json({ ok: true, push, whatsapp })
  }
  return json({ error: 'Ação desconhecida.' }, 400)
})
