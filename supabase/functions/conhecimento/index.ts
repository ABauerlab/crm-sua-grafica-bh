import { corsHeaders, json, requireOwnerOrServer, serviceClient } from '../_shared/http.ts'

// Banco de conhecimento do agente: gera os vetores (gte-small, 384 dimensões, modelo embutido no Supabase) e busca os trechos.
//   { acao: "indexar" }                       refaz o vetor dos trechos sem vetor (cron a cada 5 min, botão "Reindexar" e edição na tela)
//   { acao: "reindexar_todos" }               apaga todos os vetores; o cron refaz em lotes
//   { acao: "buscar", pergunta, conversation_id? }   embeda a pergunta e devolve até 3 trechos (ou encontrou = false)
// Aceita o dono logado, a service role (n8n) ou o agendamento (x-cron-secret). Não registra conteúdo de mensagens em log.

// deno-lint-ignore no-explicit-any
declare const Supabase: any

const LOTE = 20
let sessao: unknown = null
async function embed(texto: string): Promise<number[]> {
  // deno-lint-ignore no-explicit-any
  if (!sessao) sessao = new Supabase.ai.Session('gte-small') as any
  // deno-lint-ignore no-explicit-any
  return await (sessao as any).run(texto, { mean_pool: true, normalize: true })
}

const vetor = (v: number[]) => `[${v.join(',')}]`

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)

  const db = serviceClient()
  const cronSecret = Deno.env.get('CRON_SECRET')
  const sent = req.headers.get('x-cron-secret')
  const fromCron = !!cronSecret && !!sent && sent.length === cronSecret.length && sent === cronSecret
  if (!fromCron && !(await requireOwnerOrServer(req, db))) return json({ error: 'Não autorizado.' }, 401)

  const input = await req.json().catch(() => ({})) as { acao?: string; pergunta?: string; conversation_id?: string }

  if (input.acao === 'buscar') {
    const pergunta = (input.pergunta ?? '').trim()
    if (pergunta.length < 2 || pergunta.length > 1000) return json({ error: 'Informe a pergunta (até 1000 caracteres).' }, 400)
    let v: number[] | null = null
    try {
      v = await embed(pergunta)
    } catch (e) {
      // sem o modelo, a busca textual ainda funciona
      console.error('embedding da pergunta falhou', e instanceof Error ? e.message : 'erro')
    }
    const { data, error } = await db.rpc('buscar_conhecimento', {
      p_pergunta: pergunta, p_embedding: v ? vetor(v) : null, p_limite: 3, p_conversation: input.conversation_id ?? null, p_registrar: true,
    })
    if (error) {
      console.error('buscar_conhecimento falhou', error.message)
      return json({ error: 'Não foi possível consultar o conhecimento.' }, 500)
    }
    return json({ ...(data as Record<string, unknown>), busca: v ? 'vetorial_e_texto' : 'texto' })
  }

  if (input.acao === 'reindexar_todos') {
    const { error } = await db.from('conhecimento').update({ embedding: null, embedding_em: null }).not('id', 'is', null)
    if (error) return json({ error: 'Não foi possível limpar os vetores.' }, 500)
  } else if (input.acao !== 'indexar') {
    return json({ error: 'Ação inválida.' }, 400)
  }

  const { data: pend, error: eList } = await db.from('conhecimento').select('id, titulo, quando_usar, resposta_pronta')
    .is('embedding', null).eq('ativo', true).not('resposta_pronta', 'is', null).limit(LOTE)
  if (eList) return json({ error: 'Não foi possível listar os trechos.' }, 500)

  let feitos = 0
  const erros: string[] = []
  for (const t of pend ?? []) {
    const texto = [t.titulo, t.quando_usar, t.resposta_pronta].filter(Boolean).join('. ')
    try {
      const v = await embed(texto)
      if (v.length !== 384) throw new Error(`vetor com ${v.length} dimensões`)
      const { error } = await db.from('conhecimento').update({ embedding: vetor(v), embedding_texto: texto, embedding_em: new Date().toISOString() }).eq('id', t.id)
      if (error) throw new Error(error.message)
      feitos++
    } catch (e) {
      erros.push(`${t.id}: ${e instanceof Error ? e.message : 'erro'}`)
    }
  }
  const { count } = await db.from('conhecimento').select('id', { count: 'exact', head: true }).is('embedding', null).eq('ativo', true)
  return json({ ok: true, indexados: feitos, faltam: count ?? 0, erros })
})
