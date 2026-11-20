// Fase 2: página pública /previa/<token>. O token é o comprovante (como /pagar/<token>), sem JWT.
// Carrega o status, recebe o briefing (nome, empresa, telefone, instagram, serviços, cores/estilo + até 2 uploads
// já enviados por previa-arte-upload), pede uma nova geração, um ajuste por feedback, ou fecha para /pagar/<token>.
// Nunca devolve SKU, custo, piso, margem, fornecedor nem o caminho interno do bucket: só uma URL assinada da prévia.
import { corsHeaders, json, serviceClient } from '../_shared/http.ts'

const TOKEN = /^[0-9a-f]{32}$/
const ASSINATURA_SEGUNDOS = 3600

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)
  let b: Record<string, unknown>
  try {
    b = await req.json()
  } catch {
    return json({ error: 'Corpo da requisição inválido.' }, 400)
  }
  const token = String(b.token ?? '')
  if (!TOKEN.test(token)) return json({ ok: false, erro: 'link_invalido' }, 404)
  const db = serviceClient()

  /** Troca o caminho interno do PNG por uma URL assinada de curta duração, nunca o caminho do bucket. */
  async function comUrlAssinada(r: Record<string, unknown>): Promise<Record<string, unknown>> {
    const caminho = typeof r.resultado_path === 'string' ? r.resultado_path.replace(/^previas-arte\//, '') : null
    if (!caminho) return { ...r, resultado_url: null, resultado_path: undefined }
    const { data } = await db.storage.from('previas-arte').createSignedUrl(caminho, ASSINATURA_SEGUNDOS)
    return { ...r, resultado_url: data?.signedUrl ?? null, resultado_path: undefined }
  }

  switch (b.acao) {
    case 'carregar': {
      const { data, error } = await db.rpc('previa_arte_status', { p_token: token })
      if (error) { console.error('previa-arte: carregar falhou', error.code); return json({ ok: false, erro: 'indisponivel' }, 503) }
      const r = data as Record<string, unknown>
      if (r?.ok === false) return json(r, r.erro === 'link_invalido' ? 404 : 410)
      return json(await comUrlAssinada(r))
    }
    case 'enviar_briefing': {
      const briefing = typeof b.briefing === 'object' && b.briefing ? b.briefing as Record<string, unknown> : {}
      const camposOk: Record<string, string> = {}
      for (const k of ['nome', 'empresa', 'telefone', 'instagram', 'servicos', 'cores_estilo']) {
        const v = briefing[k]
        if (typeof v === 'string' && v.trim()) camposOk[k] = v.trim().slice(0, 300)
      }
      const uploads = Array.isArray(b.uploads) ? b.uploads.filter((u) => typeof u === 'string').slice(0, 2) : []
      const { data, error } = await db.rpc('previa_arte_enviar_briefing', { p_token: token, p_briefing: camposOk, p_uploads: uploads })
      if (error) { console.error('previa-arte: enviar_briefing falhou', error.code); return json({ ok: false, erro: 'indisponivel' }, 503) }
      return json(data, (data as { ok?: boolean })?.ok === false ? 409 : 200)
    }
    case 'regenerar': {
      const { data, error } = await db.rpc('previa_arte_regenerar', { p_token: token })
      if (error) { console.error('previa-arte: regenerar falhou', error.code); return json({ ok: false, erro: 'indisponivel' }, 503) }
      return json(data, (data as { ok?: boolean })?.ok === false ? 409 : 200)
    }
    case 'ajustar': {
      const feedback = String(b.feedback ?? '').slice(0, 2000)
      const { data, error } = await db.rpc('previa_arte_ajustar', { p_token: token, p_feedback: feedback })
      if (error) { console.error('previa-arte: ajustar falhou', error.code); return json({ ok: false, erro: 'indisponivel' }, 503) }
      return json(data, (data as { ok?: boolean })?.ok === false ? 409 : 200)
    }
    case 'fechar': {
      const { data, error } = await db.rpc('previa_arte_fechar', { p_token: token })
      if (error) { console.error('previa-arte: fechar falhou', error.code); return json({ ok: false, erro: 'indisponivel' }, 503) }
      return json(data, (data as { ok?: boolean })?.ok === false ? 409 : 200)
    }
    default:
      return json({ error: 'Ação inválida.' }, 400)
  }
})
