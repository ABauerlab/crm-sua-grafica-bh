import { corsHeaders, json, requireStaff, serviceClient } from '../_shared/http.ts'

// Botão "Responder com IA" do chat (18/11/2026). Só atendente logado.
// Prepara o rascunho no banco (execução em modo rascunho, texto recente do cliente e contexto) e avisa o n8n (WF1, gatilho de rascunho),
// que chama o mesmo cérebro da Laura (WF2) e grava o texto em ia_rascunhos. NADA é enviado ao cliente: o atendente revisa e envia.
// Configuração: URL do gatilho de rascunho do n8n em app_settings.ia_rascunho.url (ou segredo N8N_RASCUNHO_URL) e segredo N8N_WF1_TOKEN (o mesmo do WF1).
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)
  const db = serviceClient()
  const staff = await requireStaff(req, db)
  if (!staff) return json({ error: 'Não autorizado.' }, 401)

  const input = (await req.json().catch(() => ({}))) as { conversation_id?: string }
  if (!UUID.test(String(input.conversation_id ?? ''))) return json({ error: 'Conversa inválida.' }, 400)

  const { data: prep, error } = await db.rpc('ia_rascunho_preparar', { p_conversation: input.conversation_id, p_user: staff.userId })
  if (error) return json({ error: 'Não foi possível preparar a resposta agora.' }, 500)
  if (!prep?.ok) return json({ error: String(prep?.erro ?? 'Não foi possível preparar a resposta.') }, 400)
  if (prep.ja_gerando) return json({ rascunho_id: prep.rascunho_id, ja_gerando: true })

  const falhar = async (msg: string, status: number) => {
    await db.rpc('ia_rascunho_salvar', { p_rascunho: prep.rascunho_id, p_texto: '', p_erro: msg })
    return json({ error: msg }, status)
  }

  const { data: cfg } = await db.from('app_settings').select('value').eq('key', 'ia_rascunho').maybeSingle()
  const url = Deno.env.get('N8N_RASCUNHO_URL') ?? ((cfg?.value ?? {}) as { url?: string }).url
  const token = Deno.env.get('N8N_WF1_TOKEN')
  if (!url || !token) return await falhar('O motor da IA ainda não está configurado para rascunhos.', 500)

  try {
    const r = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-gbh-token': token },
      body: JSON.stringify({
        rascunho_id: prep.rascunho_id, execucao_id: prep.execucao_id, conversation_id: prep.conversation_id, contact_id: prep.contact_id,
        texto_cliente: prep.texto_cliente, contexto: prep.contexto, modelo: prep.modelo, nome_atendente: prep.nome_atendente,
      }),
      signal: AbortSignal.timeout(15000),
    })
    if (!r.ok) return await falhar('O motor da IA não respondeu. Tente de novo em instantes.', 502)
  } catch {
    return await falhar('O motor da IA não respondeu. Tente de novo em instantes.', 502)
  }
  return json({ rascunho_id: prep.rascunho_id })
})
