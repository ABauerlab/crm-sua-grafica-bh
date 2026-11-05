import { corsHeaders, json, requireEnv, requireOwnerOrServer, serviceClient } from '../_shared/http.ts'
import { nomeArquivoOrcamento, orcamentoHtml, type OrcamentoDoc } from '../_shared/orcamento-html.ts'

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
/** Resumo curto do pedido que vai na legenda do PDF (gerado a partir do orçamento: sem custo, margem, piso, SKU nem endereço). */
function resumoDoPedido(doc: OrcamentoDoc): string {
  const brl = (n: number) => 'R$ ' + (Number(n) || 0).toLocaleString('pt-BR', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
  const dm = (iso: string) => { const [, m, d] = iso.slice(0, 10).split('-'); return `${d}/${m}` }
  const linhas: string[] = [`Resumo do seu pedido (orçamento ${doc.numero})`, '']
  for (const i of doc.itens) {
    const nome = [i.descricao, i.especificacao].filter(Boolean).join(' ').replace(/\s+/g, ' ').trim()
    linhas.push(`${i.quantidade > 1 ? i.quantidade + 'x ' : ''}${nome}: ${brl(i.valor_total)}`)
  }
  if (doc.arte.modo === 'paga' || doc.arte.modo === 'com_frete') linhas.push(`Criação da arte: ${brl(doc.arte.valor)}`)
  else if (doc.arte.modo === 'cliente') linhas.push('Arte: você envia pronta')
  if (doc.frete.modo === 'bike_gratis') linhas.push('Entrega: grátis na região central, em horário comercial')
  else if (doc.frete.modo === 'uber_cliente') linhas.push(`Entrega: Uber ou 99 Entrega por conta do cliente, saindo da Praça Sete${doc.frete.valor > 0 ? ` (valor de referência ${brl(doc.frete.valor)})` : ''}`)
  else linhas.push('Retirada: grátis no centro de BH, depois do pagamento')
  if (doc.desconto > 0) linhas.push(`Desconto: ${brl(doc.desconto)}`)
  linhas.push('', `Total: ${brl(doc.total)}`)
  if (doc.data_prevista) linhas.push(`Fica pronto em ${dm(doc.data_prevista)}, pagando e enviando a arte até as ${doc.corte_hora}h`)
  if (doc.validade_ate) linhas.push(`Válido até ${dm(doc.validade_ate)}`)
  linhas.push('', 'Se estiver tudo certo, responda APROVADO que eu envio o link de pagamento.')
  return linhas.join('\n')
}

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
    const { data: pol } = await db.rpc('politica_texto', { p_chave: 'resumo_pdf' })
    return (data ? { ...data, politica: typeof pol === 'string' ? pol : null } : null) as (OrcamentoDoc & { hash: string; vencido: boolean; status: string }) | null
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
    const { data: val, error: valErr } = await db.rpc('orcamento_validar_margem', { p_orcamento: id })
    if (valErr) {
      console.error('Falha ao validar a margem:', valErr.message)
      return json({ error: 'Não foi possível validar a margem do orçamento. Tente de novo ou chame o dono.' }, 500)
    }
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
  const nomeArquivo = nomeArquivoOrcamento(doc.numero, doc.data)
  // download: o navegador salva com o nome organizado (número e data), não com o nome interno do Storage
  const { data: signed } = await db.storage.from('orcamentos').createSignedUrl(path!, LINK_SEGUNDOS, { download: nomeArquivo })
  if (!signed?.signedUrl) return json({ error: 'Não foi possível criar o link do PDF.' }, 500)
  const resposta = { ok: true, orcamento_id: id, numero: doc.numero, versao: doc.versao, pdf_url: signed.signedUrl, reutilizado, renovado, enviado: false, ja_enviado: false }
  if (acao === 'gerar') return json(resposta)

  // Envio: uma vez por versão do PDF (o botão Reenviar do CRM força de novo)
  const { data: atual } = await db.from('orcamentos').select('pdf_gerado_em, pdf_enviado_em').eq('id', id).maybeSingle()
  if (acao === 'enviar' && atual?.pdf_enviado_em && atual.pdf_gerado_em && atual.pdf_enviado_em >= atual.pdf_gerado_em) return json({ ...resposta, ja_enviado: true })

  const env = requireEnv('WHATSAPP_TOKEN', 'WHATSAPP_PHONE_NUMBER_ID')
  if (!env) return json({ error: 'Integração com o WhatsApp não configurada no servidor.' }, 500)
  if (!row.conversation_id) return json({ ...resposta, error: 'Este orçamento não tem conversa de WhatsApp ligada.' }, 422)
  const { data: conv } = await db.from('conversations').select('id, contact_id, labels, last_inbound_at, ad_window_until, contact:contacts(wa_id)').eq('id', row.conversation_id).maybeSingle()
  // deno-lint-ignore no-explicit-any
  const waId = (conv as any)?.contact?.wa_id as string | undefined
  if (!conv || !waId) return json({ ...resposta, error: 'Conversa não encontrada.' }, 404)
  const ate = Math.max(conv.last_inbound_at ? new Date(conv.last_inbound_at).getTime() + WINDOW_MS : 0, conv.ad_window_until ? new Date(conv.ad_window_until).getTime() : 0)
  if (ate <= Date.now()) {
    // janela fechada: alerta de prioridade alta para o dono e tag "reabrir_janela" na conversa, para o CRM mostrar o que fazer
    const { error: alertaErr } = await db.rpc('alerta_criar', {
      p_tipo: 'janela_fechada_orcamento', p_gravidade: 'alta', p_contact: conv.contact_id, p_conversation: conv.id, p_order: null,
      p_motivo: `Orçamento ${doc.numero} pronto, mas a janela de 24 h está fechada. Peça ao cliente para responder ou envie um template.`,
      p_dados: { orcamento_id: id }, p_chave: `janela_fechada:${id}`,
    })
    if (alertaErr) console.error('Falha ao criar o alerta de janela fechada:', alertaErr.message)
    const labels = Array.from(new Set([...(conv.labels ?? []), 'reabrir_janela']))
    const { error: tagErr } = await db.from('conversations').update({ labels }).eq('id', conv.id)
    if (tagErr) console.error('Falha ao marcar a tag reabrir_janela:', tagErr.message)
    return json({ ...resposta, status: 'janela_fechada', tag: 'reabrir_janela', error: 'A janela de atendimento está fechada. O PDF foi gerado; a conversa foi marcada para reabrir a janela.', code: 'window_closed' }, 409)
  }

  if (row.status === 'rascunho') {
    const { data: marcado, error } = await db.rpc('orcamento_marcar_enviado', { p_orcamento: id })
    if (error) {
      console.error('Falha ao marcar o orçamento como enviado:', error.message)
      return json({ ...resposta, error: 'Não foi possível marcar o orçamento como enviado. Tente de novo ou chame o dono.' }, 500)
    }
    if (!marcado?.ok) return json({ ...resposta, error: 'Orçamento recusado pela trava de lucro. Chame o dono.' }, 422)
  }

  // legenda curta: o cliente recebe o PDF, não um resumo
  const legenda = (texto ?? `Orçamento ${doc.numero} em PDF. Qualquer dúvida, é só responder por aqui.`).slice(0, 1000)
  const urlEnvio = `${GRAPH}/${env.WHATSAPP_PHONE_NUMBER_ID}/messages`
  const cabecalhos = { Authorization: `Bearer ${env.WHATSAPP_TOKEN}`, 'Content-Type': 'application/json' }
  // deno-lint-ignore no-explicit-any
  let result: any = {}
  let metaCode: number | null = null
  let enviadoComo: 'documento' | 'link' = 'documento'
  let res: Response | null = null
  try {
    res = await fetch(urlEnvio, {
      method: 'POST',
      headers: cabecalhos,
      body: JSON.stringify({ messaging_product: 'whatsapp', to: waId, type: 'document', document: { link: signed.signedUrl, filename: nomeArquivo, caption: legenda } }),
    })
    result = await res.json().catch(() => ({}))
  } catch (e) {
    console.error('Falha de rede ao enviar o PDF:', (e as Error).message)
  }
  if (!res?.ok) {
    // Fallback: a Meta não aceitou o arquivo. Manda o resumo dos valores e o link assinado para abrir o PDF no navegador.
    metaCode = Number(result?.error?.code) || null
    console.error('Meta recusou o PDF do orçamento; enviando resumo e link em texto. Código:', metaCode)
    const corpo = `${legenda}\n\nAbra o PDF do orçamento neste link:\n${signed.signedUrl}`.slice(0, 4000)
    let fallback: Response | null = null
    try {
      fallback = await fetch(urlEnvio, {
        method: 'POST',
        headers: cabecalhos,
        body: JSON.stringify({ messaging_product: 'whatsapp', to: waId, type: 'text', text: { body: corpo, preview_url: true } }),
      })
      result = await fallback.json().catch(() => ({}))
    } catch (e) {
      console.error('Falha de rede no resumo em texto do orçamento:', (e as Error).message)
    }
    if (!fallback?.ok) return json({ ...resposta, error: 'A Meta recusou o envio do orçamento, inclusive o resumo em texto. Tente de novo ou chame o dono.', meta_code: metaCode }, 502)
    enviadoComo = 'link'
  }

  const agora = new Date().toISOString()
  const corpoRegistro = enviadoComo === 'documento' ? `[Orçamento ${doc.numero} em PDF] ${legenda}` : `[Orçamento ${doc.numero}: resumo e link do PDF] ${legenda}`
  await db.from('messages').insert({ conversation_id: conv.id, wa_message_id: result?.messages?.[0]?.id ?? null, direction: 'out', type: enviadoComo === 'documento' ? 'document' : 'text', body: corpoRegistro, status: 'sent', created_at: agora })
  await db.from('conversations').update({ last_message_at: agora, last_message_preview: `Orçamento ${doc.numero} (PDF)` }).eq('id', conv.id)
  await db.from('orcamentos').update({ pdf_enviado_em: agora }).eq('id', id)
  return json({ ...resposta, enviado: true, enviado_como: enviadoComo, meta_code: metaCode })
})
