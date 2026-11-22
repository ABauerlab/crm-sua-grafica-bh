// Fase 2: worker da fila de prévia de arte. Chamado pelo agendamento (x-cron-secret) a cada minuto enquanto houver
// pendente, ou disparado na hora pela própria página /previa. Usa só API oficial configurável por variável de
// ambiente (nunca credencial de assinatura pessoal): PREVIA_ARTE_PROVEDOR ('gemini', único com geração de imagem
// hoje) + PREVIA_ARTE_API_KEY. 21/11/2026 (pedido do dono): a prévia deixou de ser uma arte solta e virou um
// mockup de verdade — o modelo recebe a FOTO REAL do produto (image-to-image) e devolve o produto com a arte do
// cliente aplicada nele, com a mesma pose, material e perspectiva da foto. A marca d'água continua sendo aplicada
// sempre por código (nunca pelo modelo), sobre o resultado, renderizada no Gotenberg.
import { corsHeaders, json, requireOwnerOrServer, serviceClient } from '../_shared/http.ts'
import { extrairImagemGemini, montarPaginaPreview, montarPromptMockup, type PreviaBriefing } from '../_shared/previa-arte.ts'

const SITE_BASE = 'https://suagraficabh.com.br'
const PALCO_LARGURA = 1120

class RateLimitError extends Error {}

async function fotoBase64(url: string): Promise<{ base64: string; mimeType: string } | null> {
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(8000) })
    if (!res.ok) return null
    const mimeType = res.headers.get('content-type') ?? 'image/jpeg'
    const bytes = new Uint8Array(await res.arrayBuffer())
    let binario = ''
    for (let i = 0; i < bytes.length; i++) binario += String.fromCharCode(bytes[i])
    return { base64: btoa(binario), mimeType }
  } catch {
    return null
  }
}

/** Gera o mockup (produto + arte aplicada) a partir da foto real do produto. Gemini: único provedor com geração de imagem hoje. */
async function gerarMockup(
  prompt: string, foto: { base64: string; mimeType: string } | null, chave: string, modelo: string,
): Promise<{ base64: string; mimeType: string }> {
  const ctl = new AbortController()
  const t = setTimeout(() => ctl.abort(), 55000)
  try {
    const parts: Record<string, unknown>[] = []
    if (foto) parts.push({ inlineData: { mimeType: foto.mimeType, data: foto.base64 } })
    parts.push({ text: prompt })
    const res = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${modelo}:generateContent?key=${chave}`, {
      method: 'POST', signal: ctl.signal, headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ contents: [{ parts }], generationConfig: { responseModalities: ['IMAGE'] } }),
    })
    if (res.status === 429) throw new RateLimitError('gemini: limite de uso atingido')
    if (!res.ok) throw new Error(`gemini: ${res.status}`)
    const j = await res.json()
    const imagem = extrairImagemGemini(j)
    if (!imagem) throw new Error('gemini: resposta sem imagem')
    return imagem
  } finally {
    clearTimeout(t)
  }
}

async function renderizarPng(html: string): Promise<Uint8Array> {
  const base = Deno.env.get('GOTENBERG_URL')?.replace(/\/$/, '')
  if (!base) throw new Error('Gerador de imagem não configurado no servidor (GOTENBERG_URL).')
  const headers: Record<string, string> = {}
  const user = Deno.env.get('GOTENBERG_USER')
  const pass = Deno.env.get('GOTENBERG_PASSWORD')
  if (user && pass) headers.Authorization = `Basic ${btoa(`${user}:${pass}`)}`
  const form = new FormData()
  form.append('files', new Blob([html], { type: 'text/html' }), 'index.html')
  form.append('width', String(PALCO_LARGURA))
  form.append('height', String(PALCO_LARGURA))
  form.append('format', 'png')
  form.append('waitDelay', '500ms')
  const ctl = new AbortController()
  const t = setTimeout(() => ctl.abort(), 30000)
  try {
    const res = await fetch(`${base}/forms/chromium/screenshot/html`, { method: 'POST', body: form, headers, signal: ctl.signal })
    if (!res.ok) throw new Error(`O gerador de imagem recusou o documento (${res.status}).`)
    return new Uint8Array(await res.arrayBuffer())
  } finally {
    clearTimeout(t)
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)
  const db = serviceClient()
  const cronSecret = Deno.env.get('CRON_SECRET')
  const sent = req.headers.get('x-cron-secret')
  const fromCron = !!cronSecret && !!sent && sent.length === cronSecret.length && sent === cronSecret
  if (!fromCron && !(await requireOwnerOrServer(req, db))) return json({ error: 'Não autorizado.' }, 401)

  const provedor = (Deno.env.get('PREVIA_ARTE_PROVEDOR') ?? 'gemini').toLowerCase()
  const chave = Deno.env.get('PREVIA_ARTE_API_KEY')
  const modelo = Deno.env.get('PREVIA_ARTE_MODELO') ?? 'gemini-2.5-flash-image'

  if (!chave) {
    const { count } = await db.from('previas_arte').select('id', { count: 'exact', head: true }).eq('status', 'pendente')
    if ((count ?? 0) > 0) {
      const hoje = new Date().toISOString().slice(0, 10)
      await db.rpc('alerta_criar', {
        p_tipo: 'previa_arte_sem_segredo', p_gravidade: 'alta', p_contact: null, p_conversation: null, p_order: null,
        p_motivo: `A geração de prévia de arte está sem PREVIA_ARTE_API_KEY: ${count} prévia(s) parada(s) na fila. Cadastre o segredo nas Secrets das Edge Functions do Supabase.`,
        p_dados: { pendentes: count }, p_chave: `previa_arte_sem_segredo:${hoje}`, p_canais: ['whatsapp'],
      }).then(({ error }: { error: unknown }) => { if (error) console.error('previa-arte-processar: alerta falhou', error) })
    }
    return json({ ok: true, configurado: false })
  }

  let processados = 0, erros = 0, limites = 0
  const inicio = Date.now()
  for (let i = 0; i < 3 && Date.now() - inicio < 100_000; i++) {
    const { data, error } = await db.rpc('previa_arte_proxima')
    if (error) { console.error('previa-arte-processar: falha ao pegar da fila', error); break }
    const item = data as {
      ok: boolean; motivo?: string; id?: string; token?: string; sku?: string; produto_descricao?: string
      produto_foto_path?: string | null; briefing?: PreviaBriefing; feedback?: string | null
    }
    if (!item?.ok) break

    try {
      if (provedor !== 'gemini') throw new Error(`provedor "${provedor}" não suporta geração de imagem (mockup)`)
      const prompt = montarPromptMockup(item.produto_descricao ?? item.sku ?? 'produto gráfico', item.briefing ?? {}, item.feedback ?? null)
      const foto = item.produto_foto_path
        ? await fotoBase64(`${Deno.env.get('SUPABASE_URL')}/storage/v1/object/public/${item.produto_foto_path}`)
        : null
      const imagem = await gerarMockup(prompt, foto, chave, modelo)
      const pagina = montarPaginaPreview(`data:${imagem.mimeType};base64,${imagem.base64}`)
      const png = await renderizarPng(pagina)
      const caminho = `${item.id}/${Date.now()}.png`
      const up = await db.storage.from('previas-arte').upload(caminho, png, { contentType: 'image/png', upsert: true })
      if (up.error) throw new Error(`falha ao guardar a imagem: ${up.error.message}`)

      const { data: conclusao } = await db.rpc('previa_arte_concluir', { p_id: item.id, p_status: 'pronta', p_resultado_path: `previas-arte/${caminho}`, p_erro: null })
      processados++
      const conc = conclusao as { recuperou_de_limite?: boolean; conversation_id?: string | null } | null
      if (conc?.recuperou_de_limite && conc.conversation_id) {
        const link = `${SITE_BASE}/previa/${item.token}`
        await fetch(`${Deno.env.get('SUPABASE_URL')}/functions/v1/agente-enviar`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')}` },
          body: JSON.stringify({ conversation_id: conc.conversation_id, text: `Sua prévia já ficou pronta! Dá uma olhada: ${link}` }),
        }).catch((e: unknown) => console.error('previa-arte-processar: aviso de recuperação falhou', e))
      }
    } catch (e) {
      if (e instanceof RateLimitError) {
        limites++
        await db.rpc('previa_arte_concluir', { p_id: item.id, p_status: 'aguardando_limite', p_resultado_path: null, p_erro: e.message })
      } else {
        erros++
        const msg = e instanceof Error ? e.message : 'erro desconhecido'
        console.error('previa-arte-processar: item falhou', item.id, msg)
        await db.rpc('previa_arte_concluir', { p_id: item.id, p_status: 'erro', p_resultado_path: null, p_erro: msg })
      }
    }
  }
  // Limpeza das prévias vencidas (48h) de pedidos não pagos: só no disparo do cron, nunca no disparo imediato
  // do formulário (não atrasa a resposta ao cliente). Preserva as prévias de pedidos pagos.
  let limpas = 0
  if (fromCron) {
    const { data: limpeza, error: erroLimpeza } = await db.rpc('previa_arte_limpar_expiradas')
    if (erroLimpeza) console.error('previa-arte-processar: limpeza falhou', erroLimpeza)
    else {
      const l = limpeza as { removidos?: number; resultado_paths?: string[]; upload_paths?: string[] }
      limpas = l.removidos ?? 0
      const caminhosArte = (l.resultado_paths ?? []).map((p) => p.replace(/^previas-arte\//, '')).filter(Boolean)
      const caminhosUpload = (l.upload_paths ?? []).map((p) => p.replace(/^previas-uploads\//, '')).filter(Boolean)
      if (caminhosArte.length) await db.storage.from('previas-arte').remove(caminhosArte).catch((e: unknown) => console.error('previa-arte-processar: remoção de arte falhou', e))
      if (caminhosUpload.length) await db.storage.from('previas-uploads').remove(caminhosUpload).catch((e: unknown) => console.error('previa-arte-processar: remoção de upload falhou', e))
    }
  }

  console.log(`previa-arte-processar: ${processados} ok, ${erros} com erro, ${limites} no limite de uso, ${limpas} prévias vencidas limpas`)
  return json({ ok: true, processados, erros, limites, limpas })
})
