import type { SupabaseClient } from 'npm:@supabase/supabase-js@2'
import { corsHeaders, json, requireOwnerOrServer, serviceClient } from '../_shared/http.ts'
import { bloqueios, corpoContato, corpoProduto, ehServicoDeArte, extrairCodigo, ncmSugerido, textoErroBling } from '../_shared/bling-envio.ts'

// Bling API v3: autorização (OAuth), fila de pedidos pagos e envio. Tokens ficam em app_segredos (nunca no front nem em log).
// Ações: status, url_autorizacao, trocar_codigo, descobrir_loja, ativar, enviar, processar, anuncios_enfileirar, anuncios_processar.
// Anúncios de marketplace (Mercado Livre e Shopee): fila em marketplace_anuncios; cada linha cria ou atualiza o vínculo produto x loja (POST/PUT /produtos/lojas)
// com o preço do canal (marketplace_preco_sku, lucro líquido mínimo configurável) e grava os dias de preparação (crossdocking) no produto.
const API = 'https://api.bling.com.br/Api/v3'
const OAUTH = 'https://www.bling.com.br/Api/v3/oauth'
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const espera = (ms: number) => new Promise((r) => setTimeout(r, ms))

async function seg(db: SupabaseClient, chave: string): Promise<string | null> {
  const { data } = await db.from('app_segredos').select('valor').eq('chave', chave).maybeSingle()
  return (data?.valor as string | undefined) ?? null
}
async function gravaSeg(db: SupabaseClient, chave: string, valor: string) {
  await db.from('app_segredos').upsert({ chave, valor }, { onConflict: 'chave' })
}
async function cfgBling(db: SupabaseClient): Promise<Record<string, any>> {
  const { data } = await db.from('app_settings').select('value').eq('key', 'bling').maybeSingle()
  return (data?.value as Record<string, any>) ?? {}
}
async function gravaCfg(db: SupabaseClient, mudar: Record<string, unknown>) {
  const atual = await cfgBling(db)
  await db.from('app_settings').upsert({ key: 'bling', value: { ...atual, ...mudar } })
}

function credenciais(): { id: string; segredo: string } | null {
  const id = Deno.env.get('BLING_CLIENT_ID')
  const segredo = Deno.env.get('BLING_CLIENT_SECRET')
  return id && segredo ? { id, segredo } : null
}

async function pedirToken(cred: { id: string; segredo: string }, params: Record<string, string>): Promise<Record<string, any>> {
  const res = await fetch(`${OAUTH}/token`, {
    method: 'POST',
    headers: { Authorization: `Basic ${btoa(`${cred.id}:${cred.segredo}`)}`, 'Content-Type': 'application/x-www-form-urlencoded', Accept: '1.0' },
    body: new URLSearchParams(params).toString(),
  })
  const dados = await res.json().catch(() => ({}))
  return { status: res.status, ...dados }
}

async function guardarTokens(db: SupabaseClient, t: Record<string, any>) {
  await gravaSeg(db, 'bling_access_token', String(t.access_token))
  if (t.refresh_token) await gravaSeg(db, 'bling_refresh_token', String(t.refresh_token))
  await gravaSeg(db, 'bling_expira_em', String(Date.now() + Number(t.expires_in ?? 21000) * 1000))
}

async function renovar(db: SupabaseClient): Promise<string | null> {
  const cred = credenciais()
  const refresh = await seg(db, 'bling_refresh_token')
  if (!cred || !refresh) return null
  const t = await pedirToken(cred, { grant_type: 'refresh_token', refresh_token: refresh })
  if (!t.access_token) { console.error('Bling: não foi possível renovar o token', t.status); return null }
  await guardarTokens(db, t)
  return String(t.access_token)
}

async function token(db: SupabaseClient): Promise<string | null> {
  const acesso = await seg(db, 'bling_access_token')
  if (!acesso) return null
  const exp = Number((await seg(db, 'bling_expira_em')) ?? 0)
  return Date.now() > exp - 120_000 ? await renovar(db) : acesso
}

async function bling(db: SupabaseClient, metodo: string, caminho: string, corpo?: unknown): Promise<{ status: number; data: any }> {
  let t = await token(db)
  if (!t) return { status: 0, data: { erro: 'bling_nao_conectado' } }
  for (let tentativa = 0; tentativa < 3; tentativa++) {
    const res = await fetch(`${API}${caminho}`, {
      method: metodo,
      headers: { Authorization: `Bearer ${t}`, 'Content-Type': 'application/json', Accept: 'application/json' },
      body: corpo === undefined ? undefined : JSON.stringify(corpo),
    })
    if (res.status === 401 && tentativa === 0) { t = await renovar(db); if (!t) return { status: 401, data: { erro: 'bling_token_invalido' } }; continue }
    if (res.status === 429) { await espera(1300); continue }
    return { status: res.status, data: await res.json().catch(() => ({})) }
  }
  return { status: 429, data: { erro: 'bling_limite_de_chamadas' } }
}

const norm = (s: string) => s.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^a-z0-9]/g, '')

async function descobrirLoja(db: SupabaseClient): Promise<{ ok: boolean; loja_id?: string; opcoes?: string[]; erro?: string }> {
  const cfg = await cfgBling(db)
  const r = await bling(db, 'GET', '/lojas')
  if (r.status !== 200) return { ok: false, erro: textoErroBling(r) }
  const lojas = (r.data?.data ?? []) as { id: number; descricao?: string; nome?: string }[]
  const alvo = norm(String(cfg.loja_nome ?? 'SUAGRÁFICABH'))
  const achou = lojas.find((l) => norm(String(l.descricao ?? l.nome ?? '')) === alvo) ?? lojas.find((l) => norm(String(l.descricao ?? l.nome ?? '')).includes(alvo))
  if (!achou) return { ok: false, erro: 'Loja não encontrada no Bling.', opcoes: lojas.map((l) => String(l.descricao ?? l.nome ?? l.id)) }
  await gravaCfg(db, { loja_id: String(achou.id) })
  return { ok: true, loja_id: String(achou.id) }
}

async function acharOuCriarContato(db: SupabaseClient, c: Record<string, any>, existente: number | null): Promise<{ id?: string; erro?: string }> {
  if (existente) return { id: String(existente) }
  const doc = String(c.numeroDocumento ?? '')
  if (doc) {
    const b = await bling(db, 'GET', `/contatos?numeroDocumento=${encodeURIComponent(doc)}&criterio=2`)
    const id = b.data?.data?.[0]?.id
    if (b.status === 200 && id) return { id: String(id) }
  }
  const novo = await bling(db, 'POST', '/contatos', corpoContato(c))
  if ((novo.status === 200 || novo.status === 201) && novo.data?.data?.id) return { id: String(novo.data.data.id) }
  if (doc) {
    const b = await bling(db, 'GET', `/contatos?numeroDocumento=${encodeURIComponent(doc)}&criterio=2`)
    const id = b.data?.data?.[0]?.id
    if (id) return { id: String(id) }
  }
  // já cadastrado com o nosso código (envio anterior que não chegou a gravar o id): procura pelo código e reaproveita
  const codigo = String(c.codigo ?? '')
  if (codigo) {
    const b = await bling(db, 'GET', `/contatos?pesquisa=${encodeURIComponent(codigo)}`)
    const achado = ((b.data?.data ?? []) as { id: number; codigo?: string }[]).find((x) => String(x.codigo ?? '') === codigo) ?? b.data?.data?.[0]
    if (b.status === 200 && achado?.id) return { id: String(achado.id) }
  }
  return { erro: `contato: ${textoErroBling(novo)}` }
}

async function garantirProduto(db: SupabaseClient, item: Record<string, any>, cache: Map<string, string>): Promise<{ id?: string; erro?: string }> {
  const codigo = String(item.codigo)
  if (cache.has(codigo)) return { id: cache.get(codigo) }
  const b = await bling(db, 'GET', `/produtos?codigos[]=${encodeURIComponent(codigo)}`)
  const achado = b.data?.data?.[0]?.id
  if (b.status === 200 && achado) { cache.set(codigo, String(achado)); return { id: String(achado) } }
  const novo = await bling(db, 'POST', '/produtos', corpoProduto(item))
  if ((novo.status === 200 || novo.status === 201) && novo.data?.data?.id) { cache.set(codigo, String(novo.data.data.id)); return { id: String(novo.data.data.id) } }
  return { erro: `produto ${codigo}: ${textoErroBling(novo)}` }
}

async function enviarPedido(db: SupabaseClient, orderId: string): Promise<{ ok: boolean; bling_pedido_id?: string; erro?: string; aviso?: string }> {
  const cfg = await cfgBling(db)
  if (!cfg.loja_id) {
    const l = await descobrirLoja(db)
    if (!l.ok) { const erro = `loja do Bling: ${l.erro}${l.opcoes?.length ? ` (lojas: ${l.opcoes.join(', ')})` : ''}`; await db.rpc('bling_resultado', { p_order: orderId, p_pedido_id: null, p_contato_id: null, p_erro: erro }); return { ok: false, erro } }
  }
  const { data: p, error } = await db.rpc('bling_pedido_payload', { p_order: orderId })
  if (error || !p) { const erro = 'não foi possível montar o pedido'; await db.rpc('bling_resultado', { p_order: orderId, p_pedido_id: null, p_contato_id: null, p_erro: erro }); return { ok: false, erro } }

  const pend = ((p.pendencias ?? []) as string[]).filter((x) => x !== 'loja_id_do_bling')
  const duros = bloqueios(pend)
  if (duros.length) { const erro = `bloqueado: falta ${duros.join(', ')}`; await db.rpc('bling_resultado', { p_order: orderId, p_pedido_id: null, p_contato_id: null, p_erro: erro }); return { ok: false, erro } }
  const aviso0 = pend.length ? `Dados fiscais incompletos (complete no Bling antes de emitir a nota): ${pend.join(', ')}` : ''

  let avisoNome = ''
  if (!String(p.contato?.nome ?? '').trim()) {
    const fim = String(p.contato?.celular ?? '').replace(/\D/g, '').slice(-4)
    p.contato = { ...p.contato, nome: `Cliente WhatsApp ${fim}`.trim() }
    avisoNome = 'Nome do cliente não informado: nome provisório, corrigir no Bling'
  }
  const contato = await acharOuCriarContato(db, p.contato, p.pedido?.contato?.id ?? null)
  if (!contato.id) { await db.rpc('bling_resultado', { p_order: orderId, p_pedido_id: null, p_contato_id: null, p_erro: contato.erro }); return { ok: false, erro: contato.erro } }

  // Itens digitados à mão (sem SKU) que não são arte: entram como produto com código SGnnn-i e NCM sugerido (o operador confere antes de emitir)
  const numeroPedido = String(p.pedido?.numeroLoja ?? '').replace(/\D/g, '')
  const manuais = ((p.servicos ?? []) as Record<string, any>[]).filter((s) => !ehServicoDeArte(String(s.descricao ?? '')))
  const itensBase = [...((p.pedido?.itens ?? []) as Record<string, any>[]), ...manuais.map((s, k) => ({
    codigo: `SG${numeroPedido}-${k + 1}`, descricao: s.descricao, unidade: 'UN', quantidade: s.quantidade, valor: s.valor, ncm: ncmSugerido(String(s.descricao ?? '')), origem: 0, manual: true,
  }))]
  const semNcm = manuais.filter((s) => !ncmSugerido(String(s.descricao ?? ''))).length
  const avisoManual = manuais.length ? `Item(ns) sem SKU enviados como produto: conferir NCM${semNcm ? ` (${semNcm} sem NCM sugerido)` : ' sugerido'} antes de emitir a nota` : ''
  if (!itensBase.length) { const erro = 'bloqueado: pedido sem item de mercadoria'; await db.rpc('bling_resultado', { p_order: orderId, p_pedido_id: null, p_contato_id: null, p_erro: erro }); return { ok: false, erro } }

  const aviso = [aviso0, avisoNome, avisoManual].filter(Boolean).join(' | ')
  // idempotente: se o pedido já foi criado no Bling (ex.: o id não chegou a ser gravado), só registra e não cria de novo
  const existente = await bling(db, 'GET', `/pedidos/vendas?numerosLojas[]=${encodeURIComponent(String(p.pedido.numeroLoja))}`)
  const jaId = existente.status === 200 ? ((existente.data?.data ?? []) as { id: number; numeroLoja?: string }[]).find((x) => String(x.numeroLoja ?? '') === String(p.pedido.numeroLoja))?.id ?? null : null
  if (jaId) {
    await db.rpc('bling_resultado', { p_order: orderId, p_pedido_id: String(jaId), p_contato_id: contato.id, p_erro: null, p_aviso: aviso || null })
    return { ok: true, bling_pedido_id: String(jaId), aviso: aviso || undefined }
  }
  const cache = new Map<string, string>()
  const itens: Record<string, unknown>[] = []
  for (const it of itensBase) {
    const prod = await garantirProduto(db, it, cache)
    if (!prod.id) { await db.rpc('bling_resultado', { p_order: orderId, p_pedido_id: null, p_contato_id: null, p_erro: prod.erro }); return { ok: false, erro: prod.erro } }
    itens.push({ codigo: it.codigo, descricao: it.descricao, unidade: it.unidade ?? 'UN', quantidade: it.quantidade, valor: it.valor, produto: { id: Number(prod.id) } })
  }
  const soma = itens.reduce((s, i) => s + Number(i.quantidade) * Number(i.valor), 0)
  const total = Number(p.pedido?.parcelas?.[0]?.valor ?? soma)
  const diff = Math.round((total - soma) * 100) / 100
  const corpo: Record<string, unknown> = {
    numeroLoja: p.pedido.numeroLoja, data: p.pedido.data, contato: { id: Number(contato.id) }, loja: { id: Number(cfg.loja_id ?? (await cfgBling(db)).loja_id) },
    itens, parcelas: p.pedido.parcelas, observacoes: p.pedido.observacoes,
    observacoesInternas: [p.pedido.observacoesInternas, aviso].filter(Boolean).join(' | ') || undefined,
  }
  if (diff > 0) corpo.transporte = { frete: diff }
  if (diff < 0) corpo.desconto = { valor: -diff, unidade: 'REAL' }
  const r = await bling(db, 'POST', '/pedidos/vendas', corpo)
  const id = r.data?.data?.id
  if ((r.status === 200 || r.status === 201) && id) {
    await db.rpc('bling_resultado', { p_order: orderId, p_pedido_id: String(id), p_contato_id: contato.id, p_erro: null, p_aviso: aviso || null })
    return { ok: true, bling_pedido_id: String(id), aviso: aviso || undefined }
  }
  const erro = `pedido: ${textoErroBling(r)}`
  await db.rpc('bling_resultado', { p_order: orderId, p_pedido_id: null, p_contato_id: null, p_erro: erro })
  return { ok: false, erro }
}

const CANAIS = ['mercado_livre', 'shopee'] as const

async function vincularAnuncio(db: SupabaseClient, a: { id: string; sku: string; canal: string; bling_produto_id: number; preco: number; dias_preparacao: number }): Promise<{ ok: boolean; vinculo_id?: number; erro?: string; aviso?: string }> {
  const cfg = await cfgBling(db)
  const lojaId = Number(cfg.lojas_marketplace?.[a.canal])
  if (!lojaId) return { ok: false, erro: `Loja do canal ${a.canal} não configurada em app_settings.bling.lojas_marketplace.` }
  let aviso: string | undefined
  // dias de preparação = crossdocking do produto (o marketplace usa como prazo de postagem)
  const dias = await bling(db, 'PATCH', `/produtos/${a.bling_produto_id}`, { estoque: { crossdocking: a.dias_preparacao } })
  if (dias.status !== 200 && dias.status !== 204) aviso = `dias de preparação não gravados: ${textoErroBling(dias)}`
  const corpo = { codigo: a.sku, preco: a.preco, produto: { id: a.bling_produto_id }, loja: { id: lojaId } }
  const existente = await bling(db, 'GET', `/produtos/lojas?idProduto=${a.bling_produto_id}&idLoja=${lojaId}`)
  const idVinculo = existente.status === 200 ? existente.data?.data?.[0]?.id : null
  const r = idVinculo ? await bling(db, 'PUT', `/produtos/lojas/${idVinculo}`, corpo) : await bling(db, 'POST', '/produtos/lojas', corpo)
  if (r.status === 200 || r.status === 201 || r.status === 204) return { ok: true, vinculo_id: Number(r.data?.data?.id ?? idVinculo ?? 0) || undefined, aviso }
  return { ok: false, erro: textoErroBling(r) }
}

async function anunciosEnfileirar(db: SupabaseClient, itens: { sku: string; bling_produto_id: number }[]) {
  const linhas: Record<string, unknown>[] = []
  const falhas: string[] = []
  for (const it of itens) {
    for (const canal of CANAIS) {
      const { data } = await db.rpc('marketplace_preco_sku', { p_sku: it.sku, p_canal: canal })
      if (!data?.preco) { falhas.push(`${it.sku}/${canal}: ${data?.erro ?? 'sem preço'}`); continue }
      linhas.push({ sku: it.sku, canal, bling_produto_id: it.bling_produto_id, preco: data.preco, dias_preparacao: data.dias_preparacao, status: 'pendente', erro: null, tentativas: 0, atualizado_em: new Date().toISOString() })
    }
  }
  if (linhas.length) await db.from('marketplace_anuncios').upsert(linhas, { onConflict: 'sku,canal' })
  return { ok: true, enfileirados: linhas.length, falhas }
}

async function anunciosProcessar(db: SupabaseClient, limite = 12) {
  const resumo = { ok: true, vinculados: 0, falhas: 0, erros: [] as string[] }
  if (!(await token(db))) return { ...resumo, ok: false, erros: ['Bling não conectado.'] }
  const { data: fila } = await db.from('marketplace_anuncios').select('*').eq('status', 'pendente').lt('tentativas', 3).order('atualizado_em').limit(limite)
  for (const a of (fila ?? []) as { id: string; sku: string; canal: string; bling_produto_id: number; preco: number; dias_preparacao: number; tentativas: number }[]) {
    const r = await vincularAnuncio(db, a)
    if (r.ok) resumo.vinculados++
    else { resumo.falhas++; resumo.erros.push(`${a.sku}/${a.canal}: ${String(r.erro).slice(0, 140)}`) }
    const tent = a.tentativas + 1
    await db.from('marketplace_anuncios').update({ status: r.ok ? 'ok' : tent >= 3 ? 'erro' : 'pendente', vinculo_id: r.vinculo_id ?? null, tentativas: tent, erro: r.ok ? (r.aviso ?? null) : String(r.erro).slice(0, 400), atualizado_em: new Date().toISOString() }).eq('id', a.id)
    await espera(400) // limite do Bling: 3 chamadas por segundo
  }
  return resumo
}

async function processar(db: SupabaseClient) {
  const cfg = await cfgBling(db)
  if (!cfg.ativo) return { ok: true, ativo: false, enviados: 0 }
  if (!(await token(db))) return { ok: false, ativo: true, erro: 'Bling não conectado. Autorize em Configurações > Bling.', enviados: 0 }
  const { data: fila } = await db.rpc('bling_pendentes', { p_limite: 8 })
  const resumo: Record<string, unknown> = { ok: true, ativo: true, enviados: 0, falhas: 0, erros: [] as string[] }
  for (const linha of (fila ?? []) as { order_id: string }[]) {
    const r = await enviarPedido(db, linha.order_id)
    if (r.ok) resumo.enviados = Number(resumo.enviados) + 1
    else {
      resumo.falhas = Number(resumo.falhas) + 1
      ;(resumo.erros as string[]).push(String(r.erro ?? 'erro').slice(0, 160))
      const { data: o } = await db.from('orders').select('number, bling_tentativas, contact_id').eq('id', linha.order_id).maybeSingle()
      if (o && o.bling_tentativas >= 3) {
        await db.rpc('alerta_criar', { p_tipo: 'bling_falha', p_gravidade: 'alta', p_contact: o.contact_id, p_conversation: null, p_order: linha.order_id,
          p_motivo: `Pedido ${o.number} não foi para o Bling: ${r.erro ?? 'erro'}`, p_dados: {}, p_chave: `bling_falha_${linha.order_id}` })
      }
    }
    await espera(400)
  }
  resumo.anuncios = await anunciosProcessar(db, 6)
  return resumo
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)
  const db = serviceClient()
  const cronSecret = Deno.env.get('CRON_SECRET')
  const sent = req.headers.get('x-cron-secret')
  const doCron = !!cronSecret && !!sent && sent.length === cronSecret.length && sent === cronSecret
  const quem = doCron ? 'cron' : await requireOwnerOrServer(req, db)
  if (!quem) return json({ error: 'Não autorizado.' }, 401)

  const input = (await req.json().catch(() => ({}))) as { acao?: string; code?: string; order_id?: string; ativo?: boolean; itens?: { sku: string; bling_produto_id: number }[] }
  const acao = String(input.acao ?? '')
  if (quem === 'cron' && acao !== 'processar') return json({ error: 'Ação não permitida pelo agendador.' }, 403)

  if (acao === 'processar') return json(await processar(db))
  if (acao === 'anuncios_enfileirar') return json(await anunciosEnfileirar(db, (input.itens ?? []).slice(0, 200)))
  if (acao === 'anuncios_processar') return json(await anunciosProcessar(db))

  if (acao === 'status') {
    const cfg = await cfgBling(db)
    return json({ ok: true, configurado: !!credenciais(), conectado: !!(await seg(db, 'bling_refresh_token')), loja_id: cfg.loja_id ?? null, loja_nome: cfg.loja_nome ?? null, ativo: !!cfg.ativo, redirect_uri: cfg.redirect_uri ?? null })
  }
  if (acao === 'url_autorizacao') {
    const cred = credenciais()
    if (!cred) return json({ error: 'Faltam os segredos BLING_CLIENT_ID e BLING_CLIENT_SECRET nas Edge Functions.' }, 400)
    const estado = crypto.randomUUID().replace(/-/g, '')
    await gravaSeg(db, 'bling_oauth_state', estado)
    return json({ ok: true, url: `${OAUTH}/authorize?response_type=code&client_id=${encodeURIComponent(cred.id)}&state=${estado}` })
  }
  if (acao === 'trocar_codigo') {
    const cred = credenciais()
    if (!cred) return json({ error: 'Faltam os segredos BLING_CLIENT_ID e BLING_CLIENT_SECRET nas Edge Functions.' }, 400)
    const codigo = extrairCodigo(String(input.code ?? ''))
    if (!codigo) return json({ error: 'Cole o endereço completo para onde o Bling levou você depois de autorizar (ele tem ?code=...).' }, 400)
    const esperado = await seg(db, 'bling_oauth_state')
    if (codigo.state && esperado && codigo.state !== esperado) return json({ error: 'Este código é de outra tentativa. Gere o link de autorização de novo.' }, 400)
    const cfg = await cfgBling(db)
    const t = await pedirToken(cred, { grant_type: 'authorization_code', code: codigo.code, redirect_uri: String(cfg.redirect_uri ?? '') })
    if (!t.access_token) return json({ error: 'O Bling recusou o código (ele vale poucos minutos e só uma vez). Gere o link de novo.' }, 400)
    await guardarTokens(db, t)
    const loja = await descobrirLoja(db)
    return json({ ok: true, conectado: true, loja: loja.ok ? loja.loja_id : null, lojas_disponiveis: loja.opcoes ?? undefined })
  }
  if (acao === 'descobrir_loja') return json(await descobrirLoja(db))
  if (acao === 'ativar') {
    if (typeof input.ativo !== 'boolean') return json({ error: 'Informe ativo true ou false.' }, 400)
    if (input.ativo && !(await seg(db, 'bling_refresh_token'))) return json({ error: 'Conecte o Bling antes de ligar o envio automático.' }, 400)
    await gravaCfg(db, { ativo: input.ativo })
    return json({ ok: true, ativo: input.ativo })
  }
  if (acao === 'enviar') {
    if (!UUID.test(String(input.order_id ?? ''))) return json({ error: 'order_id inválido.' }, 400)
    await db.rpc('bling_reenviar', { p_order: input.order_id })
    return json(await enviarPedido(db, input.order_id!))
  }
  return json({ error: 'Ação desconhecida.' }, 400)
})
