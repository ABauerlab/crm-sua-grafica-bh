import { corsHeaders, json, requireEnv, requireServiceRole, requireStaff, serviceClient } from '../_shared/http.ts'
import { type AlertaFila, janelaAberta, montarPush, montarTemplate, montarTexto } from '../_shared/alertas.ts'
import { assinaturasAtivas, enviarPush, vapid } from '../_shared/push.ts'
import { enviarTemplate, enviarTexto, statusTemplate, type WaEnv } from '../_shared/wapp.ts'

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
