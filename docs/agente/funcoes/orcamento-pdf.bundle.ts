// GERADO por "npm run bundle:orcamento-pdf" (scripts/bundle-orcamento-pdf.ts). NÃO edite aqui: edite supabase/functions/ e gere de novo.
// Painel do Supabase > Edge Functions > Deploy a new function > Via Editor. Nome: orcamento-pdf. Desligue "Verify JWT" (a função confere o dono ou a service role).
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

/** Chamador autorizado a cobrar: o dono logado (JWT) ou outro servidor da própria Sua Gráfica usando a service role key. */
async function requireOwnerOrServer(req: Request, db: SupabaseClient): Promise<'dono' | 'servidor' | null> {
  const token = req.headers.get('Authorization')?.replace(/^Bearer\s+/i, '')
  if (!token) return null
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
  if (serviceKey && token.length === serviceKey.length && token === serviceKey) return 'servidor'
  const { data: userData, error } = await db.auth.getUser(token)
  if (error || !userData.user) return null
  const { data: profile } = await db.from('profiles').select('id').eq('id', userData.user.id).maybeSingle()
  if (!profile) return null
  const { data: owner } = await db.from('app_settings').select('value').eq('key', 'owner').maybeSingle()
  const ownerEmail = String((owner?.value as { email?: string } | null)?.email ?? '').toLowerCase()
  if (ownerEmail && (userData.user.email ?? '').toLowerCase() !== ownerEmail) return null
  return 'dono'
}

// Modelo HTML do orçamento em PDF. Puro (sem APIs do Deno), para rodar na Edge Function e nos testes do Node.
// Recebe só o documento público de `orcamento_documento`: nunca custo, margem, piso, fornecedor, SKU nem endereço de retirada.
// Identidade: paleta e logo do CRM (brand kit: ciano, magenta, amarelo, tinta e azul) e fonte Inter.

interface OrcamentoDoc {
  numero: string
  versao: number
  data: string
  validade_ate: string | null
  cliente: { nome: string }
  itens: { descricao: string; especificacao?: string | null; quantidade: number; valor_unitario: number; valor_total: number }[]
  subtotal: number
  arte: { modo: 'nenhuma' | 'cliente' | 'paga' | 'com_frete'; valor: number; opcoes?: { texto: string; valor: number }[] | null }
  frete: { modo: 'retirada' | 'bike_gratis' | 'uber_cliente'; valor: number }
  desconto: number
  total: number
  condicao_especial?: { valida_ate: string; tipo: string; total: number; texto: string } | null
  data_prevista: string | null
  prazo_inicio: string | null
  hoje: string
  corte_hora: number
  upsell?: { tipo: string; texto: string } | null
  empresa: { nome: string; cnpj: string; telefone?: string | null; email?: string | null; instagram?: string | null; site?: string | null }
}

const TZ = 'America/Sao_Paulo'

const esc = (v: unknown): string =>
  String(v ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;')

const brl = (n: number) => new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' }).format(Number(n) || 0).replace(/ /g, ' ')
const ddmm = (iso: string) => {
  const [, m, d] = iso.slice(0, 10).split('-')
  return `${d}/${m}`
}
const dmy = (iso: string) => {
  const [y, m, d] = iso.slice(0, 10).split('-')
  return `${d}/${m}/${y}`
}
const dataHora = (iso: string) => {
  const p = new Intl.DateTimeFormat('pt-BR', { timeZone: TZ, day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit', hour12: false }).formatToParts(new Date(iso))
  const g = (t: string) => p.find((x) => x.type === t)?.value ?? ''
  return `${g('day')}/${g('month')} às ${g('hour')}:${g('minute')}`
}
const soDia = (iso: string) => {
  const p = new Intl.DateTimeFormat('pt-BR', { timeZone: TZ, day: '2-digit', month: '2-digit', year: 'numeric' }).formatToParts(new Date(iso))
  const g = (t: string) => p.find((x) => x.type === t)?.value ?? ''
  return `${g('day')}/${g('month')}/${g('year')}`
}
const diaSemana = (iso: string) =>
  ['domingo', 'segunda-feira', 'terça-feira', 'quarta-feira', 'quinta-feira', 'sexta-feira', 'sábado'][new Date(`${iso.slice(0, 10)}T12:00:00Z`).getUTCDay()]

// Logo: as três circunferências do brand kit (mesma arte do favicon do CRM)
const LOGO = `<svg class="logo" viewBox="0 0 335.76 320.75" role="img" aria-label="Sua Gráfica BH"><defs><clipPath id="c"><circle cx="112" cy="112" r="100"/></clipPath><clipPath id="m"><circle cx="224" cy="112" r="100"/></clipPath></defs><circle cx="112" cy="112" r="100" fill="#00A6D6"/><circle cx="224" cy="112" r="100" fill="#E6007E"/><circle cx="168" cy="208.995" r="100" fill="#FFD500"/><g clip-path="url(#c)"><circle cx="224" cy="112" r="100" fill="#1F2A86"/><circle cx="168" cy="208.995" r="100" fill="#0E8A3E"/></g><g clip-path="url(#m)"><circle cx="168" cy="208.995" r="100" fill="#E3061E"/></g><g clip-path="url(#c)"><g clip-path="url(#m)"><circle cx="168" cy="208.995" r="100" fill="#171717"/></g></g></svg>`

const CSS = `
@page { size: A4; margin: 12mm 12mm; }
* { box-sizing: border-box; }
html { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
body { margin: 0; font-family: 'Inter', 'Helvetica Neue', Arial, sans-serif; font-size: 11.5pt; line-height: 1.4; color: #171717; background: #fff; }
.topbar { display: flex; height: 4px; margin-bottom: 14px; }
.topbar i { flex: 1; } .topbar i:nth-child(1) { background: #00A6D6; } .topbar i:nth-child(2) { background: #E6007E; } .topbar i:nth-child(3) { background: #FFD500; }
header { display: flex; justify-content: space-between; align-items: center; gap: 16px; }
.marca { display: flex; align-items: center; gap: 10px; }
.logo { width: 46px; height: auto; }
.marca b { display: block; font-family: 'Inter Display', 'Inter', sans-serif; font-size: 19pt; font-weight: 900; letter-spacing: -0.01em; color: #1F2A86; line-height: 1.05; }
.marca span { font-size: 9.5pt; color: #5c5c5c; }
.doc { text-align: right; }
.doc h1 { margin: 0; font-family: 'Inter Display', 'Inter', sans-serif; font-size: 22pt; font-weight: 900; letter-spacing: -0.01em; line-height: 1; }
.doc span { font-size: 9.5pt; color: #5c5c5c; }
.meta { display: grid; grid-template-columns: 1.3fr 1fr 1.2fr; gap: 8px; margin: 14px 0 12px; }
.box { border: 1px solid #dedede; border-radius: 6px; padding: 7px 10px; background: #F7F7F4; }
.box small { display: block; font-size: 8.5pt; text-transform: uppercase; letter-spacing: .12em; font-weight: 500; color: #5c5c5c; }
.box strong { font-size: 12.5pt; font-weight: 600; }
table { width: 100%; border-collapse: collapse; }
th { text-align: left; font-size: 8.5pt; font-weight: 500; text-transform: uppercase; letter-spacing: .12em; color: #fff; background: #1F2A86; padding: 6px 8px; }
th.n, td.n { text-align: right; white-space: nowrap; }
td { padding: 8px; border-bottom: 1px solid #e6e6e6; vertical-align: top; }
tr { page-break-inside: avoid; }
td small { display: block; color: #5c5c5c; font-size: 9.5pt; margin-top: 1px; }
.cols { display: flex; gap: 14px; margin-top: 12px; align-items: flex-start; }
.cols > div { flex: 1; }
.totais { max-width: 290px; margin-left: auto; }
.totais .l { display: flex; justify-content: space-between; gap: 10px; padding: 3px 0; font-size: 11.5pt; }
.totais .l.g { color: #0E8A3E; font-weight: 600; }
.totais .t { display: flex; justify-content: space-between; align-items: baseline; margin-top: 4px; padding: 8px 10px; background: #171717; color: #fff; border-radius: 6px; }
.totais .t span { font-size: 10.5pt; } .totais .t b { font-family: 'Inter Display', 'Inter', sans-serif; font-size: 19pt; font-weight: 900; letter-spacing: -0.01em; }
.aviso { border-radius: 6px; padding: 8px 10px; margin-top: 8px; font-size: 10.5pt; }
.especial { background: #FFF6BF; border-left: 4px solid #FFD500; }
.especial b { font-size: 12pt; }
.prazo { background: #E5F6FB; border-left: 4px solid #00A6D6; }
.arte { border: 1px dashed #b5b5b5; }
.arte ul { margin: 4px 0 0; padding-left: 16px; }
.sec { font-size: 8.5pt; text-transform: uppercase; letter-spacing: .12em; color: #5c5c5c; margin: 0 0 3px; font-weight: 500; }
.nota { font-size: 10.5pt; color: #333; margin: 0 0 5px; }
.upsell { margin-top: 12px; font-size: 10.5pt; color: #5c5c5c; }
footer { margin-top: 16px; padding-top: 8px; border-top: 1px solid #dedede; font-size: 9.5pt; color: #5c5c5c; display: flex; justify-content: space-between; gap: 14px; }
footer b { color: #171717; }
`

function orcamentoHtml(d: OrcamentoDoc): string {
  const emp = d.empresa
  const linhas = d.itens
    .map(
      (i) => `<tr><td>${esc(i.descricao)}${i.especificacao ? `<small>${esc(i.especificacao)}</small>` : ''}</td><td class="n">${esc(i.quantidade)}</td><td class="n">${brl(i.valor_unitario)}</td><td class="n">${brl(i.valor_total)}</td></tr>`,
    )
    .join('')

  const artePago = d.arte.modo === 'paga' || d.arte.modo === 'com_frete'
  const freteLinha =
    d.frete.modo === 'bike_gratis'
      ? `<div class="l g"><span>Entrega (região central)</span><span>Grátis</span></div>`
      : d.frete.modo === 'uber_cliente'
        ? `<div class="l"><span>Entrega por Uber</span><span>por conta do cliente</span></div>`
        : `<div class="l g"><span>Retirada</span><span>Grátis</span></div>`

  const totais = `<div class="totais">
    <div class="l"><span>Subtotal</span><span>${brl(d.subtotal)}</span></div>
    ${artePago ? (d.arte.valor > 0 ? `<div class="l"><span>${d.arte.modo === 'com_frete' ? 'Arte + frete grátis' : 'Criação de arte'}</span><span>${brl(d.arte.valor)}</span></div>` : `<div class="l g"><span>Criação de arte</span><span>Grátis</span></div>`) : d.arte.modo === 'cliente' ? `<div class="l"><span>Arte</span><span>enviada por você</span></div>` : ''}
    ${freteLinha}
    ${d.desconto > 0 ? `<div class="l g"><span>Desconto especial</span><span>- ${brl(d.desconto)}</span></div>` : ''}
    <div class="t"><span>Total</span><b>${brl(d.total)}</b></div>
  </div>`

  const especial = d.condicao_especial
    ? `<div class="aviso especial"><b>Condição especial válida até ${esc(dataHora(d.condicao_especial.valida_ate))}</b><br>${esc(d.condicao_especial.texto)}. Valor final: <b>${brl(d.condicao_especial.total)}</b></div>`
    : ''

  let prazo = ''
  if (d.data_prevista) {
    const quando = d.prazo_inicio && d.prazo_inicio.slice(0, 10) === d.hoje.slice(0, 10) ? 'hoje' : d.prazo_inicio ? ddmm(d.prazo_inicio) : 'hoje'
    const semArte = d.arte.modo === 'nenhuma' || d.arte.modo === 'cliente' ? 'enviar a arte' : 'aprovar a arte'
    prazo = `<div class="aviso prazo"><b>Previsão: ${esc(ddmm(d.data_prevista))}</b> (${esc(diaSemana(d.data_prevista))})<br>Se pagar e ${semArte} até ${esc(d.corte_hora)}h de ${esc(quando)}, fica pronto em ${esc(ddmm(d.data_prevista))}.</div>`
  }

  const opcoesArte =
    d.arte.modo === 'nenhuma' && d.arte.opcoes?.length
      ? `<div class="aviso arte"><p class="sec">Precisa de arte?</p>Fazemos a sua arte, é só escolher:<ul>${d.arte.opcoes.map((o) => `<li>${esc(o.texto)}: <b>${brl(o.valor)}</b></li>`).join('')}</ul></div>`
      : ''

  const contato = [emp.telefone ? `WhatsApp ${esc(emp.telefone)}` : '', emp.instagram ? esc(emp.instagram) : '', emp.site ? esc(emp.site) : '', emp.email ? esc(emp.email) : '']
    .filter(Boolean)
    .join(' · ')

  const validade = d.validade_ate ? soDia(d.validade_ate) : ''
  const versao = d.versao > 1 ? ` · versão ${esc(d.versao)}` : ''

  return `<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Orçamento ${esc(d.numero)}</title>
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;900&display=swap">
<style>${CSS}</style></head><body>
<div class="topbar"><i></i><i></i><i></i></div>
<header>
  <div class="marca">${LOGO}<div><b>${esc(emp.nome)}</b><span>Gráfica digital em Belo Horizonte</span></div></div>
  <div class="doc"><h1>Orçamento ${esc(d.numero)}</h1><span>Emitido em ${esc(dmy(d.data))}${versao}</span></div>
</header>
<section class="meta">
  <div class="box"><small>Cliente</small><strong>${esc(d.cliente.nome)}</strong></div>
  <div class="box"><small>Válido até</small><strong>${esc(validade)}</strong></div>
  <div class="box"><small>Pronto em</small><strong>${d.data_prevista ? esc(ddmm(d.data_prevista)) : 'a confirmar'}</strong></div>
</section>
<table><thead><tr><th>Item</th><th class="n">Qtd.</th><th class="n">Unitário</th><th class="n">Total</th></tr></thead><tbody>${linhas}</tbody></table>
<section class="cols">
  <div>
    ${prazo}
    ${opcoesArte}
    ${especial}
  </div>
  <div>${totais}</div>
</section>
<section class="cols">
  <div>
    <p class="sec">Pagamento</p>
    <p class="nota">Pix (de qualquer banco) ou cartão, pelo link de pagamento enviado no WhatsApp. O pedido só entra em produção depois da confirmação do pagamento.</p>
  </div>
  <div>
    <p class="sec">Retirada e entrega</p>
    <p class="nota">Retirada grátis no centro de BH. O endereço e o horário de retirada são enviados depois da confirmação do pagamento.${d.frete.modo === 'bike_gratis' ? ' Entrega grátis de bicicleta na região central, em horário comercial.' : ''}${d.frete.modo === 'uber_cliente' ? ' Se preferir receber em casa, a entrega é por Uber Entrega, por conta do cliente.' : ''}</p>
  </div>
</section>
${d.upsell ? `<p class="upsell">${esc(d.upsell.texto)}</p>` : ''}
<footer><div><b>${esc(emp.nome)}</b> · CNPJ ${esc(emp.cnpj)}<br>${contato}</div><div style="text-align:right">Este orçamento vale até ${esc(validade)}.<br>Depois dessa data, os valores e o prazo são recalculados.</div></footer>
</body></html>`
}


const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const GRAPH = 'https://graph.facebook.com/v21.0'
const WINDOW_MS = 24 * 60 * 60 * 1000
const LINK_SEGUNDOS = 7 * 24 * 60 * 60

interface Body {
  orcamento_id?: string
  /** gerar: só o PDF. enviar: PDF + WhatsApp (uma vez por versão do PDF). reenviar: manda de novo (botão do CRM). */
  acao?: 'gerar' | 'enviar' | 'reenviar'
  /** frase natural do agente (legenda do documento no WhatsApp) */
  texto?: string
}

// Renderiza o HTML em PDF no Gotenberg (Chromium), instalado no Coolify junto do n8n. Credenciais só nos segredos da função.
async function renderizar(html: string): Promise<Uint8Array> {
  const base = Deno.env.get('GOTENBERG_URL')?.replace(/\/$/, '')
  if (!base) throw new Error('Gerador de PDF não configurado no servidor (GOTENBERG_URL).')
  const headers: Record<string, string> = {}
  const user = Deno.env.get('GOTENBERG_USER')
  const pass = Deno.env.get('GOTENBERG_PASSWORD')
  if (user && pass) headers.Authorization = `Basic ${btoa(`${user}:${pass}`)}`
  for (let tentativa = 1; tentativa <= 2; tentativa++) {
    const form = new FormData()
    form.append('files', new Blob([html], { type: 'text/html' }), 'index.html')
    form.append('preferCssPageSize', 'true')
    form.append('printBackground', 'true')
    form.append('emulatedMediaType', 'print')
    form.append('waitDelay', '1s')
    const ctl = new AbortController()
    const t = setTimeout(() => ctl.abort(), 30000)
    try {
      const res = await fetch(`${base}/forms/chromium/convert/html`, { method: 'POST', body: form, headers, signal: ctl.signal })
      if (res.ok) return new Uint8Array(await res.arrayBuffer())
      if (res.status < 500 || tentativa === 2) throw new Error(`O gerador de PDF recusou o documento (${res.status}).`)
    } catch (e) {
      if (tentativa === 2) throw e instanceof Error ? e : new Error('Falha ao gerar o PDF.')
    } finally {
      clearTimeout(t)
    }
    await new Promise((r) => setTimeout(r, 1500))
  }
  throw new Error('Falha ao gerar o PDF.')
}

// Gera (ou reaproveita) o PDF do orçamento e, se pedido, envia como documento no WhatsApp.
// Só lê o documento público de orcamento_documento: nunca custo, margem, piso, fornecedor, SKU nem endereço de retirada.
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)

  const db = serviceClient()
  if (!(await requireOwnerOrServer(req, db))) return json({ error: 'Não autorizado.' }, 401)

  let input: Body
  try {
    input = await req.json()
  } catch {
    return json({ error: 'Corpo da requisição inválido.' }, 400)
  }
  let id = input.orcamento_id ?? ''
  const acao = input.acao ?? 'gerar'
  if (!UUID.test(id)) return json({ error: 'Informe orcamento_id.' }, 400)
  if (!['gerar', 'enviar', 'reenviar'].includes(acao)) return json({ error: 'Ação inválida.' }, 400)
  const texto = input.texto?.trim().slice(0, 1000) || undefined

  const lerDoc = async (oid: string) => {
    const { data, error } = await db.rpc('orcamento_documento', { p_orcamento: oid })
    if (error) throw new Error('Não foi possível montar o documento do orçamento.')
    return data as (OrcamentoDoc & { hash: string; vencido: boolean; status: string }) | null
  }

  let doc = await lerDoc(id).catch(() => null)
  if (!doc) return json({ error: 'Orçamento não encontrado.' }, 404)
  if (['pago', 'cancelado', 'perdido'].includes(doc.status)) return json({ error: 'Este orçamento já foi encerrado.' }, 409)

  // Vencido: gera um orçamento novo com tudo recalculado (preço, prazo e frete) e o antigo expira
  let renovado = false
  if (doc.vencido || doc.status === 'expirado') {
    const { data: r, error } = await db.rpc('orcamento_renovar', { p_orcamento: id })
    if (error || !r || r.status !== 'ok') return json({ error: 'O orçamento venceu e não foi possível renovar automaticamente. Chame o dono.', motivo: r?.motivo ?? null }, 422)
    id = r.orcamento_id as string
    renovado = true
    doc = await lerDoc(id).catch(() => null)
    if (!doc) return json({ error: 'Orçamento renovado não encontrado.' }, 500)
  }

  const { data: row } = await db.from('orcamentos').select('id, status, pdf_path, pdf_hash, pdf_gerado_em, pdf_enviado_em, conversation_id').eq('id', id).maybeSingle()
  if (!row) return json({ error: 'Orçamento não encontrado.' }, 404)

  // Antes de qualquer envio ao cliente: trava de lucro. Rascunho vira enviado (o banco recusa prejuízo).
  if (acao !== 'gerar') {
    const { data: val } = await db.rpc('validar_margem', { p_orcamento: id })
    if (!val || val.status !== 'ok') return json({ error: 'Orçamento recusado pela trava de lucro. Chame o dono.', motivo: val?.motivo ?? null }, 422)
  }

  // PDF: reaproveita quando nada mudou (mesmo hash do documento público)
  let reutilizado = false
  let path = row.pdf_path as string | null
  if (!(path && row.pdf_hash === doc.hash)) {
    let pdf: Uint8Array
    try {
      pdf = await renderizar(orcamentoHtml(doc))
    } catch (e) {
      console.error('Falha ao gerar o PDF do orçamento:', (e as Error).message)
      return json({ error: (e as Error).message }, 502)
    }
    path = `${id}/${doc.numero}-v${doc.versao}-${doc.hash.slice(0, 8)}.pdf`
    const up = await db.storage.from('orcamentos').upload(path, pdf, { contentType: 'application/pdf', upsert: true })
    if (up.error) {
      console.error('Falha ao guardar o PDF:', up.error.message)
      return json({ error: 'Não foi possível guardar o PDF.' }, 500)
    }
    const { error } = await db.from('orcamentos').update({ pdf_path: path, pdf_hash: doc.hash, pdf_gerado_em: new Date().toISOString() }).eq('id', id)
    if (error) return json({ error: 'PDF gerado, mas não foi possível registrá-lo no orçamento.' }, 500)
  } else {
    reutilizado = true
  }
  const { data: signed } = await db.storage.from('orcamentos').createSignedUrl(path!, LINK_SEGUNDOS)
  if (!signed?.signedUrl) return json({ error: 'Não foi possível criar o link do PDF.' }, 500)
  const resposta = { ok: true, orcamento_id: id, numero: doc.numero, versao: doc.versao, pdf_url: signed.signedUrl, reutilizado, renovado, enviado: false, ja_enviado: false }
  if (acao === 'gerar') return json(resposta)

  // Envio: uma vez por versão do PDF (o botão Reenviar do CRM força de novo)
  const { data: atual } = await db.from('orcamentos').select('pdf_gerado_em, pdf_enviado_em').eq('id', id).maybeSingle()
  if (acao === 'enviar' && atual?.pdf_enviado_em && atual.pdf_gerado_em && atual.pdf_enviado_em >= atual.pdf_gerado_em) return json({ ...resposta, ja_enviado: true })

  const env = requireEnv('WHATSAPP_TOKEN', 'WHATSAPP_PHONE_NUMBER_ID')
  if (!env) return json({ error: 'Integração com o WhatsApp não configurada no servidor.' }, 500)
  if (!row.conversation_id) return json({ ...resposta, error: 'Este orçamento não tem conversa de WhatsApp ligada.' }, 422)
  const { data: conv } = await db.from('conversations').select('id, last_inbound_at, ad_window_until, contact:contacts(wa_id)').eq('id', row.conversation_id).maybeSingle()
  // deno-lint-ignore no-explicit-any
  const waId = (conv as any)?.contact?.wa_id as string | undefined
  if (!conv || !waId) return json({ ...resposta, error: 'Conversa não encontrada.' }, 404)
  const ate = Math.max(conv.last_inbound_at ? new Date(conv.last_inbound_at).getTime() + WINDOW_MS : 0, conv.ad_window_until ? new Date(conv.ad_window_until).getTime() : 0)
  if (ate <= Date.now()) return json({ ...resposta, error: 'A janela de atendimento está fechada. O PDF foi gerado; envie um template aprovado.', code: 'window_closed' }, 409)

  if (row.status === 'rascunho') {
    const { error } = await db.from('orcamentos').update({ status: 'enviado' }).eq('id', id)
    if (error) return json({ ...resposta, error: 'Orçamento recusado pela trava de lucro. Chame o dono.' }, 422)
  }

  const legenda = texto ?? `Segue o orçamento ${doc.numero}.`
  let res: Response
  try {
    res = await fetch(`${GRAPH}/${env.WHATSAPP_PHONE_NUMBER_ID}/messages`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${env.WHATSAPP_TOKEN}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ messaging_product: 'whatsapp', to: waId, type: 'document', document: { link: signed.signedUrl, filename: `Orcamento-${doc.numero}.pdf`, caption: legenda } }),
    })
  } catch {
    return json({ ...resposta, error: 'Não foi possível falar com a API do WhatsApp. Tente novamente.' }, 502)
  }
  const result = await res.json().catch(() => ({}))
  if (!res.ok) {
    console.error('Erro da Meta ao enviar o orçamento:', result?.error?.code)
    return json({ ...resposta, error: 'A Meta recusou o envio do orçamento.', meta_code: result?.error?.code ?? null }, 502)
  }

  const agora = new Date().toISOString()
  await db.from('messages').insert({ conversation_id: conv.id, wa_message_id: result?.messages?.[0]?.id ?? null, direction: 'out', type: 'document', body: `[Orçamento ${doc.numero} em PDF] ${legenda}`, status: 'sent', created_at: agora })
  await db.from('conversations').update({ last_message_at: agora, last_message_preview: `Orçamento ${doc.numero} (PDF)` }).eq('id', conv.id)
  await db.from('orcamentos').update({ pdf_enviado_em: agora }).eq('id', id)
  return json({ ...resposta, enviado: true })
})
