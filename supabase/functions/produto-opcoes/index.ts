import { corsHeaders, json, requireEnv, requireOwnerOrServer, serviceClient } from '../_shared/http.ts'

// Opções com foto para o agente (uma mensagem por opção): "opcoes: <produto>; <quantidade>".
// A legenda é montada AQUI a partir de buscar_produto (preço de calcular_preco, ficha traduzida, prazo): o modelo não escreve nada,
// então custo, margem, piso, fornecedor, SKU e origem das imagens nunca aparecem. Sem foto da opção, vai só o texto.
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const GRAPH = 'https://graph.facebook.com/v21.0'
const WINDOW_MS = 24 * 60 * 60 * 1000
const BUCKET = 'produto-fotos'

interface Opcao { sku: string; descricao_curta?: string; em_palavras?: string; quantidade: number; preco: number; prazo_dias_uteis?: number; vendavel?: boolean }

const brl = (n: number) => 'R$ ' + (Number(n) || 0).toLocaleString('pt-BR', { minimumFractionDigits: 2, maximumFractionDigits: 2 })

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)
  const db = serviceClient()
  if (!(await requireOwnerOrServer(req, db))) return json({ error: 'Não autorizado.' }, 401)

  let input: { termo_ou_sku?: string; conversation_id?: string }
  try { input = await req.json() } catch { return json({ error: 'Corpo da requisição inválido.' }, 400) }
  const m = String(input.termo_ou_sku ?? '').trim().match(/^opcoes:\s*(.+?)\s*;\s*(\d+)\s*$/i)
  if (!m) return json({ error: 'Use o formato "opcoes: produto; quantidade".' }, 400)
  if (!input.conversation_id || !UUID.test(input.conversation_id)) return json({ error: 'Informe a conversa.' }, 400)

  const { data: conv } = await db.from('conversations').select('id, contact_id, last_inbound_at, ad_window_until, contact:contacts(wa_id)').eq('id', input.conversation_id).maybeSingle()
  // deno-lint-ignore no-explicit-any
  const waId = (conv as any)?.contact?.wa_id as string | undefined
  if (!conv || !waId) return json({ error: 'Conversa não encontrada.' }, 404)
  const ate = Math.max(conv.last_inbound_at ? new Date(conv.last_inbound_at).getTime() + WINDOW_MS : 0, conv.ad_window_until ? new Date(conv.ad_window_until).getTime() : 0)
  if (ate <= Date.now()) return json({ error: 'A janela de atendimento está fechada.', code: 'window_closed' }, 409)
  const env = requireEnv('WHATSAPP_TOKEN', 'WHATSAPP_PHONE_NUMBER_ID')
  if (!env) return json({ error: 'Integração com o WhatsApp não configurada no servidor.' }, 500)

  const { data: cfgRow } = await db.from('app_settings').select('value').eq('key', 'fotos').maybeSingle()
  const fotosLigadas = ((cfgRow?.value ?? {}) as { ligado?: boolean }).ligado !== false
  const { data: lim } = await db.rpc('foto_limites', { p_conversation: conv.id, p_contact: conv.contact_id })
  let restantesHoje = Math.max(0, 10 - Number(lim?.imagens_hoje ?? 0))

  const { data: bp } = await db.rpc('buscar_produto', { p_termo: m[1], p_quantidade: Number(m[2]), p_filtros: {} })
  const ops = ((bp?.opcoes ?? []) as Opcao[]).filter((o) => o.vendavel !== false).slice(0, 4)
  if (!ops.length) return json({ enviadas: 0, orientacao: 'Não achei opções com esses termos. Tente outros termos em buscar_produto ou chame o dono.' })

  const base = Deno.env.get('SUPABASE_URL') ?? ''
  const auth = req.headers.get('Authorization') ?? ''
  // abertura ANTES das fotos (a resposta do modelo sempre chega depois das ferramentas)
  const produto = m[1].replace(/[^\p{L}\p{N} ]/gu, '').trim().slice(0, 60)
  const intro = `Separei ${ops.length} opções de ${produto} para ${m[2]} unidades. Olha só:`
  try {
    const ri = await fetch(`${GRAPH}/${env.WHATSAPP_PHONE_NUMBER_ID}/messages`, { method: 'POST', headers: { Authorization: `Bearer ${env.WHATSAPP_TOKEN}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ messaging_product: 'whatsapp', to: waId, type: 'text', text: { body: intro } }) })
    const oi = await ri.json().catch(() => ({}))
    if (ri.ok) {
      const agora = new Date().toISOString()
      await db.from('messages').insert({ conversation_id: conv.id, wa_message_id: oi?.messages?.[0]?.id ?? null, direction: 'out', type: 'text', body: intro, status: 'sent', created_at: agora })
    }
  } catch { /* segue sem a abertura */ }
  await new Promise((res) => setTimeout(res, 1200))

  let enviadas = 0
  let fotos = 0
  let bytes = 0
  for (let i = 0; i < ops.length; i++) {
    const o = ops[i]
    const nome = String(o.descricao_curta ?? '').replace(/\s+\d[xX]\d\s+.*$/, '').trim()
    const linhas = [`Opção ${i + 1}: ${nome}`]
    if (o.em_palavras) linhas.push(String(o.em_palavras))
    linhas.push(`${o.quantidade} unidades por ${brl(Number(o.preco))} (valor de referência)`)
    if (o.prazo_dias_uteis) linhas.push(`Pronto em ${o.prazo_dias_uteis} dia(s) útil(eis) depois da arte aprovada`)

    let arquivo: string | null = null
    let ilustrativa = false
    if (fotosLigadas && restantesHoje > 0) {
      try {
        const { data: rg } = await db.rpc('foto_resolver_grupo', { p_termo: o.sku })
        if (rg?.ok) {
          const grupo = rg.grupo as string
          const ler = async () => ((await db.rpc('foto_aprovadas', { p_grupo: grupo, p_quantidade: 1, p_sku: o.sku })).data ?? []) as { arquivo: string; bytes: number; aproximada: boolean }[]
          let l = await ler()
          if (!l.length) {
            // guarda as fotos do grupo (não envia nada): ação "rebuscar" da função de fotos
            const ctl = new AbortController()
            const t = setTimeout(() => ctl.abort(), 40000)
            try { await fetch(`${base}/functions/v1/produto-fotos`, { method: 'POST', headers: { Authorization: auth, 'Content-Type': 'application/json' }, body: JSON.stringify({ acao: 'rebuscar', grupo, termo_ou_sku: o.sku }), signal: ctl.signal }) } catch { /* segue só com texto */ } finally { clearTimeout(t) }
            l = await ler()
          }
          if (l[0]) { arquivo = l[0].arquivo; bytes += l[0].bytes; ilustrativa = l[0].aproximada }
        }
      } catch (e) { console.error('foto da opção falhou', e instanceof Error ? e.message : 'erro') }
    }
    if (arquivo && ilustrativa) linhas.push('Foto ilustrativa: o acabamento pode variar um pouco.')
    const legenda = linhas.join('\n').slice(0, 1000)

    let corpo: Record<string, unknown> | null = null
    if (arquivo) {
      const { data: signed } = await db.storage.from(BUCKET).createSignedUrl(arquivo, 300)
      if (signed?.signedUrl) { corpo = { messaging_product: 'whatsapp', to: waId, type: 'image', image: { link: signed.signedUrl, caption: legenda } }; restantesHoje--; fotos++ }
    }
    if (!corpo) corpo = { messaging_product: 'whatsapp', to: waId, type: 'text', text: { body: legenda } }
    let r: Response
    try {
      r = await fetch(`${GRAPH}/${env.WHATSAPP_PHONE_NUMBER_ID}/messages`, { method: 'POST', headers: { Authorization: `Bearer ${env.WHATSAPP_TOKEN}`, 'Content-Type': 'application/json' }, body: JSON.stringify(corpo) })
    } catch { continue }
    const out = await r.json().catch(() => ({}))
    if (!r.ok) { console.error('Erro da Meta ao enviar opção:', out?.error?.code); continue }
    const agora = new Date().toISOString()
    await db.from('messages').insert({ conversation_id: conv.id, wa_message_id: out?.messages?.[0]?.id ?? null, direction: 'out', type: corpo.type === 'image' ? 'image' : 'text', body: corpo.type === 'image' ? `[foto] ${legenda}` : legenda, status: 'sent', created_at: agora })
    await db.from('conversations').update({ last_message_at: agora, last_message_preview: `Opção ${i + 1}` }).eq('id', conv.id)
    enviadas++
    await new Promise((res) => setTimeout(res, 1200))
  }
  if (!enviadas) return json({ error: 'Não foi possível enviar as opções agora. Descreva as opções por texto.' }, 502)
  if (fotos) await db.rpc('foto_registrar_envio', { p_conversation: conv.id, p_contact: conv.contact_id, p_grupo: null, p_quantidade: fotos, p_bytes: bytes, p_via: 'cache', p_resultado: 'enviada' })
  // resposta mínima ao agente: nunca traz origem, URL, SKU nem nome de arquivo
  return json({ enviadas, ja_enviou_abertura: true, legenda_sugerida: '' })
})
