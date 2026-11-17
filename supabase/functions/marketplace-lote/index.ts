import type { SupabaseClient } from 'npm:@supabase/supabase-js@2'
import { corsHeaders, json, requireOwnerOrServer, serviceClient } from '../_shared/http.ts'

// Lote dos marketplaces: publica no Bling cada família de marketplace_familias (produto pai + variações por quantidade),
// com estoque 10 no depósito Geral, dias de preparação (crossdocking), 5 imagens e fila de vínculo com a loja do site.
// Cron (x-cron-secret) só roda com app_settings.marketplaces.lote_ativo = true. O vínculo com Mercado Livre e Shopee depende dos IDs dos anúncios.
const API = 'https://api.bling.com.br/Api/v3'
const OAUTH = 'https://www.bling.com.br/Api/v3/oauth'
const DEPOSITO_GERAL = 14888119377
const espera = (ms: number) => new Promise((r) => setTimeout(r, ms))

async function seg(db: SupabaseClient, chave: string): Promise<string | null> {
  const { data } = await db.from('app_segredos').select('valor').eq('chave', chave).maybeSingle()
  return (data?.valor as string | undefined) ?? null
}
async function gravaSeg(db: SupabaseClient, chave: string, valor: string) { await db.from('app_segredos').upsert({ chave, valor }, { onConflict: 'chave' }) }
async function renovar(db: SupabaseClient): Promise<string | null> {
  const id = Deno.env.get('BLING_CLIENT_ID'), segredo = Deno.env.get('BLING_CLIENT_SECRET'), refresh = await seg(db, 'bling_refresh_token')
  if (!id || !segredo || !refresh) return null
  const res = await fetch(`${OAUTH}/token`, { method: 'POST', headers: { Authorization: `Basic ${btoa(`${id}:${segredo}`)}`, 'Content-Type': 'application/x-www-form-urlencoded', Accept: '1.0' }, body: new URLSearchParams({ grant_type: 'refresh_token', refresh_token: refresh }).toString() })
  const t = await res.json().catch(() => ({}))
  if (!t.access_token) return null
  await gravaSeg(db, 'bling_access_token', String(t.access_token))
  if (t.refresh_token) await gravaSeg(db, 'bling_refresh_token', String(t.refresh_token))
  await gravaSeg(db, 'bling_expira_em', String(Date.now() + Number(t.expires_in ?? 21000) * 1000))
  return String(t.access_token)
}
async function token(db: SupabaseClient): Promise<string | null> {
  const a = await seg(db, 'bling_access_token')
  if (!a) return null
  return Date.now() > Number((await seg(db, 'bling_expira_em')) ?? 0) - 120_000 ? await renovar(db) : a
}
async function bling(db: SupabaseClient, metodo: string, caminho: string, corpo?: unknown): Promise<{ status: number; data: any }> {
  let t = await token(db)
  if (!t) return { status: 0, data: { erro: 'bling_nao_conectado' } }
  for (let i = 0; i < 3; i++) {
    const res = await fetch(`${API}${caminho}`, { method: metodo, headers: { Authorization: `Bearer ${t}`, 'Content-Type': 'application/json', Accept: 'application/json' }, body: corpo === undefined ? undefined : JSON.stringify(corpo) })
    if (res.status === 401 && i === 0) { t = await renovar(db); if (!t) return { status: 401, data: { erro: 'bling_token_invalido' } }; continue }
    if (res.status === 429) { await espera(1300); continue }
    return { status: res.status, data: await res.json().catch(() => ({})) }
  }
  return { status: 429, data: { erro: 'bling_limite_de_chamadas' } }
}
const erroBling = (r: { status: number; data: any }) => {
  const e = r.data?.error
  const campos = Array.isArray(e?.fields) ? e.fields.map((f: any) => f?.msg ?? f?.element).filter(Boolean).join('; ') : ''
  return `${e?.description || e?.message || r.data?.erro || `HTTP ${r.status}`}${campos ? ` (${campos})` : ''}`.replace(/\s+/g, ' ').slice(0, 300)
}

type Variacao = { sku: string; quantidade: number; preco_site: number; peso_kg: number; embalagem_cm: string; prazo_dias: number; ncm: string | null; bling_id?: number }
type Familia = { id: string; codigo_pai: string; categoria: string | null; descricao: string | null; cores: string | null; ficha: Record<string, any> | null; variacoes: Variacao[] }

export function tituloAnuncio(f: Familia): string {
  let t = String(f.ficha?.titulo ?? `${f.categoria ?? ''} ${f.descricao ?? ''}`).replace(/\s+/g, ' ').trim()
  t = t.replace(/\bsem lamina[cç][aã]o e sem acabamento extra\b/gi, '').replace(/\bsem acabamento extra\b/gi, '').replace(/\s+/g, ' ').trim()
  if (!/personaliz/i.test(t) && `${t} Personalizado`.length <= 60) t = `${t} Personalizado`
  if (t.length > 60) t = t.slice(0, 60).replace(/\s+\S*$/, '')
  return t
}
const num = (n: number) => n.toLocaleString('pt-BR')
function descricaoHtml(f: Familia, dias: number): string {
  const fi = f.ficha ?? {}
  const linhas = [
    fi.material && `- Material: ${fi.material}${fi.espessura ? ` (${fi.espessura})` : ''}`, fi.tamanho_final && `- Tamanho final: ${fi.tamanho_final}`,
    fi.arte_com_sangria && `- Arte com sangria: ${fi.arte_com_sangria}`, (fi.impressao || f.cores) && `- Impressão: ${fi.impressao ?? f.cores}`,
    fi.acabamento && `- Acabamento: ${fi.acabamento}`, `- Quantidades disponíveis: ${f.variacoes.map((v) => num(v.quantidade)).join(', ')} unidades`,
  ].filter(Boolean).join('<br>')
  const obs = ((fi.observacoes ?? []) as string[]).filter(Boolean).slice(0, 3).map((o) => `- ${o}`).join('<br>')
  return `<b>${tituloAnuncio(f).toUpperCase()}</b><br><br>Impressão profissional com a sua arte, pronta para uso.<br><br><b>Ficha técnica</b><br>${linhas}<br><br>${obs ? `<b>Observações</b><br>${obs}<br><br>` : ''}<b>Como personalizar (passo a passo)</b><br>1. Escolha a quantidade e finalize a compra.<br>2. Depois da compra, envie sua logo ou arte (PDF, CDR, AI, PNG em alta resolução ou Canva) pelo chat do pedido.<br>3. Nossa equipe confere medidas, sangria e resolução.<br>4. Produzimos e enviamos com embalagem reforçada.<br><br><b>Prazo</b><br>Produção em ${dias} dias úteis depois da aprovação da arte, mais o prazo de entrega do envio escolhido.<br><br><b>Perguntas frequentes</b><br><b>Não tenho arte pronta, e agora?</b> Fale conosco pelo chat do pedido para combinarmos como criar.<br><b>Posso enviar mais de um modelo de arte?</b> Cada pedido leva uma arte. Para modelos diferentes, faça um pedido para cada.`
}
function dims(emb: string): { profundidade: number; largura: number; altura: number; unidadeMedida: string } {
  const [c, l, a] = emb.split('x').map((x) => Number(x.trim().replace(',', '.')) || 1)
  return { profundidade: c, largura: l, altura: a, unidadeMedida: '1' }
}
const IMAGENS = ['01_capa', '02_medidas', '03_especificacoes', '04_como_funciona', '05_beneficios_nichos']

async function publicarFamilia(db: SupabaseClient, f: Familia): Promise<{ ok: boolean; erro?: string }> {
  const existe = await bling(db, 'GET', `/produtos?codigos[]=${encodeURIComponent(f.codigo_pai)}&criterio=5`)
  const jaId = existe.status === 200 ? existe.data?.data?.[0]?.id : null
  if (jaId) { await db.from('marketplace_familias').update({ bling_pai_id: jaId, status: 'publicada', erro: 'já existia no Bling', atualizado_em: new Date().toISOString() }).eq('id', f.id); return { ok: true } }
  const titulo = tituloAnuncio(f)
  const prazoMax = Math.max(...f.variacoes.map((v) => v.prazo_dias ?? 3))
  const dias = prazoMax + 2
  const precos: Record<string, number> = {}
  for (const v of f.variacoes) { const { data } = await db.rpc('marketplace_preco_sku', { p_sku: v.sku, p_canal: 'mercado_livre' }); precos[v.sku] = Number(data?.preco ?? v.preco_site) }
  const base = `${Deno.env.get('SUPABASE_URL')}/storage/v1/object/public/marketplace-images/${f.codigo_pai}`
  const v0 = f.variacoes[0]
  const corpo = {
    nome: titulo, codigo: f.codigo_pai, tipo: 'P', situacao: 'A', formato: 'V', unidade: 'UN', preco: Math.min(...Object.values(precos)), condicao: '1', tipoProducao: 'T', marca: 'Sua Gráfica BH',
    pesoLiquido: v0.peso_kg, pesoBruto: Number((v0.peso_kg + 0.006).toFixed(3)), volumes: 1, dimensoes: dims(v0.embalagem_cm), tributacao: { ncm: v0.ncm ?? undefined, origem: 0 },
    descricaoCurta: titulo, descricaoComplementar: descricaoHtml(f, dias),
    midia: { video: { url: '' }, imagens: { imagensURL: IMAGENS.map((n) => ({ link: `${base}/${n}.jpg` })) } },
    variacoes: f.variacoes.map((v, i) => ({
      nome: `${titulo} Quantidade:${num(v.quantidade)} un`.slice(0, 120), codigo: v.sku, tipo: 'P', situacao: 'A', formato: 'S', unidade: 'UN', preco: precos[v.sku],
      pesoLiquido: v.peso_kg, pesoBruto: Number((v.peso_kg + 0.006).toFixed(3)), dimensoes: dims(v.embalagem_cm), tributacao: { ncm: v.ncm ?? undefined, origem: 0 },
      estoque: { crossdocking: dias }, midia: { video: {}, imagens: {} }, variacao: { nome: `Quantidade:${num(v.quantidade)} un`, ordem: i + 1, produtoPai: {} },
    })),
  }
  const r = await bling(db, 'POST', '/produtos', corpo)
  const paiId = r.data?.data?.id
  if (!(r.status === 200 || r.status === 201) || !paiId) return { ok: false, erro: `produto: ${erroBling(r)}` }
  const salvas = (r.data?.data?.variations?.saved ?? []) as { id: number; nomeVariacao: string }[]
  const variacoes = f.variacoes.map((v) => ({ ...v, bling_id: salvas.find((s) => s.nomeVariacao === `Quantidade:${num(v.quantidade)} un`)?.id }))
  const falhasEstoque: string[] = []
  for (const v of variacoes) {
    if (!v.bling_id) { falhasEstoque.push(`${v.sku}: sem id`); continue }
    await espera(350)
    const e = await bling(db, 'POST', '/estoques', { produto: { id: v.bling_id }, deposito: { id: DEPOSITO_GERAL }, quantidade: 10, operacao: 'B', observacoes: 'Estoque virtual de segurança (produção sob demanda)' })
    if (e.status !== 200 && e.status !== 201) falhasEstoque.push(`${v.sku}: ${erroBling(e)}`)
  }
  const fila = variacoes.filter((v) => v.bling_id).map((v) => ({ sku: v.sku, canal: 'site', bling_produto_id: v.bling_id, preco: v.preco_site, dias_preparacao: dias, status: 'pendente', erro: null, tentativas: 0 }))
  if (fila.length) await db.from('marketplace_anuncios').upsert(fila, { onConflict: 'sku,canal' })
  await db.from('marketplace_familias').update({ bling_pai_id: paiId, variacoes, status: 'publicada', erro: falhasEstoque.length ? `estoque: ${falhasEstoque.join(' | ').slice(0, 300)}` : null, atualizado_em: new Date().toISOString() }).eq('id', f.id)
  return { ok: true }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)
  const db = serviceClient()
  const cronSecret = Deno.env.get('CRON_SECRET'), sent = req.headers.get('x-cron-secret')
  const doCron = !!cronSecret && !!sent && sent.length === cronSecret.length && sent === cronSecret
  if (!doCron && !(await requireOwnerOrServer(req, db))) return json({ error: 'Não autorizado.' }, 401)
  const input = (await req.json().catch(() => ({}))) as { acao?: string; codigos?: string[]; limite?: number }
  if (input.acao === 'status') {
    const { data } = await db.from('marketplace_familias').select('status')
    const c: Record<string, number> = {}
    for (const l of (data ?? []) as { status: string }[]) c[l.status] = (c[l.status] ?? 0) + 1
    return json({ ok: true, familias: c })
  }
  if (input.acao !== 'publicar') return json({ error: 'Ação desconhecida.' }, 400)
  const { data: cfg } = await db.from('app_settings').select('value').eq('key', 'marketplaces').maybeSingle()
  const manual = Array.isArray(input.codigos) && input.codigos.length > 0
  if (!manual && !(cfg?.value as any)?.lote_ativo) return json({ ok: true, lote_ativo: false })
  if (!(await token(db))) return json({ ok: false, erro: 'Bling não conectado.' })
  let q = db.from('marketplace_familias').select('id, codigo_pai, categoria, descricao, cores, ficha, variacoes').in('status', ['rascunho', 'imagens_ok', 'erro'])
  if (manual) q = q.in('codigo_pai', input.codigos!)
  const { data: fam } = await q.order('codigo_pai').limit(Math.min(input.limite ?? 4, 8))
  const resumo = { ok: true, publicadas: 0, falhas: 0, erros: [] as string[] }
  for (const f of (fam ?? []) as Familia[]) {
    await db.from('marketplace_familias').update({ status: 'publicando', atualizado_em: new Date().toISOString() }).eq('id', f.id)
    const r = await publicarFamilia(db, f).catch((e) => ({ ok: false, erro: String(e?.message ?? e) }))
    if (r.ok) resumo.publicadas++
    else { resumo.falhas++; resumo.erros.push(`${f.codigo_pai}: ${r.erro}`.slice(0, 200)); await db.from('marketplace_familias').update({ status: 'erro', erro: r.erro?.slice(0, 400), atualizado_em: new Date().toISOString() }).eq('id', f.id) }
  }
  return json(resumo)
})
