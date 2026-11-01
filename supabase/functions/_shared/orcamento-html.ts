// Modelo HTML do orçamento em PDF. Puro (sem APIs do Deno), para rodar na Edge Function e nos testes do Node.
// Recebe só o documento público de `orcamento_documento`: nunca custo, margem, piso, fornecedor, SKU nem endereço de retirada.
// Identidade: paleta e logo do CRM (brand kit: ciano, magenta, amarelo, tinta e azul) e fonte Inter.

export interface OrcamentoDoc {
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
  /** Resumo curto da política de troca e cancelamento (app_settings.politica.resumo_pdf), no rodapé */
  politica?: string | null
  empresa: { nome: string; cnpj: string; telefone?: string | null; email?: string | null; instagram?: string | null; site?: string | null }
}

const TZ = 'America/Sao_Paulo'

/** Nome do arquivo que o cliente recebe: número do orçamento e data de emissão (ex.: Orcamento-SG-0032-29-10-2026.pdf). */
export const nomeArquivoOrcamento = (numero: string, dataIso: string): string => {
  const [y, m, d] = dataIso.slice(0, 10).split('-')
  return `Orcamento-${String(numero).replace(/[^A-Za-z0-9-]/g, '')}-${d}-${m}-${y}.pdf`
}

export const esc = (v: unknown): string =>
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
body { margin: 0; font-family: 'Inter', 'Helvetica Neue', Arial, sans-serif; font-size: 12.5pt; line-height: 1.45; color: #171717; background: #fff; }
.page { min-height: 255mm; display: flex; flex-direction: column; }
.topbar { display: flex; height: 5px; margin-bottom: 18px; }
.topbar i { flex: 1; } .topbar i:nth-child(1) { background: #00A6D6; } .topbar i:nth-child(2) { background: #E6007E; } .topbar i:nth-child(3) { background: #FFD500; }
header { display: flex; justify-content: space-between; align-items: center; gap: 16px; }
.marca { display: flex; align-items: center; gap: 10px; }
.logo { width: 54px; height: auto; }
.marca b { display: block; font-family: 'Inter Display', 'Inter', sans-serif; font-size: 21pt; font-weight: 900; letter-spacing: -0.01em; color: #1F2A86; line-height: 1.05; }
.marca span { font-size: 10pt; color: #5c5c5c; }
.doc { text-align: right; }
.doc h1 { margin: 0; font-family: 'Inter Display', 'Inter', sans-serif; font-size: 25pt; font-weight: 900; letter-spacing: -0.01em; line-height: 1; }
.doc span { font-size: 10pt; color: #5c5c5c; }
.meta { display: grid; grid-template-columns: 1.3fr 1fr 1.2fr; gap: 10px; margin: 20px 0 18px; }
.box { border: 1px solid #dedede; border-radius: 6px; padding: 10px 12px; background: #F7F7F4; }
.box small { display: block; font-size: 8.5pt; text-transform: uppercase; letter-spacing: .12em; font-weight: 500; color: #5c5c5c; }
.box strong { font-size: 13.5pt; font-weight: 600; }
table { width: 100%; border-collapse: collapse; }
th { text-align: left; font-size: 9pt; padding-top: 8px; padding-bottom: 8px; font-weight: 500; text-transform: uppercase; letter-spacing: .12em; color: #fff; background: #1F2A86; padding: 6px 8px; }
th.n, td.n { text-align: right; white-space: nowrap; }
td { padding: 10px 8px; border-bottom: 1px solid #e6e6e6; vertical-align: top; }
tr { page-break-inside: avoid; }
td small { display: block; color: #5c5c5c; font-size: 9.5pt; margin-top: 1px; }
.cols { display: flex; gap: 18px; margin-top: 16px; align-items: flex-start; }
.cols > div { flex: 1; }
.totais { max-width: 310px; margin-left: auto; }
.totais .l { display: flex; justify-content: space-between; gap: 10px; padding: 4px 0; font-size: 12.5pt; }
.totais .l span:last-child { text-align: right; white-space: nowrap; }
.totais .l.g { color: #0E8A3E; font-weight: 600; }
.totais .t { display: flex; justify-content: space-between; align-items: baseline; margin-top: 4px; padding: 11px 12px; background: #171717; color: #fff; border-radius: 6px; }
.totais .t span { font-size: 10.5pt; } .totais .t b { font-family: 'Inter Display', 'Inter', sans-serif; font-size: 22pt; font-weight: 900; letter-spacing: -0.01em; }
.aviso { border-radius: 6px; padding: 8px 10px; margin-top: 10px; font-size: 11.5pt; }
.especial { background: #FFF6BF; border-left: 4px solid #FFD500; }
.especial b { font-size: 12pt; }
.prazo { background: #E5F6FB; border-left: 4px solid #00A6D6; }
.arte { border: 1px dashed #b5b5b5; }
.arte ul { margin: 4px 0 0; padding-left: 16px; }
.sec { font-size: 8.5pt; text-transform: uppercase; letter-spacing: .12em; color: #5c5c5c; margin: 0 0 3px; font-weight: 500; }
.nota { font-size: 11.5pt; color: #333; margin: 0 0 5px; }
.upsell { margin-top: 18px; font-size: 11.5pt; color: #5c5c5c; }
p.politica { margin: 8px 0 0; font-size: 8.5pt; color: #5c5c5c; line-height: 1.35; }
footer { margin-top: auto; padding-top: 10px; border-top: 1px solid #dedede; font-size: 10pt; color: #5c5c5c; display: flex; justify-content: space-between; gap: 14px; }
footer b { color: #171717; }
.passos { margin-top: 18px; }
.passos ol { list-style: none; margin: 6px 0 0; padding: 0; display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; counter-reset: p; }
.passos li { counter-increment: p; border: 1px solid #dedede; border-radius: 6px; padding: 10px 12px 10px 42px; position: relative; font-size: 11pt; background: #fff; }
.passos li::before { content: counter(p); position: absolute; left: 10px; top: 9px; width: 22px; height: 22px; border-radius: 50%; background: #00A6D6; color: #171717; font-weight: 600; text-align: center; line-height: 22px; font-size: 11pt; }
.passos li b { display: block; font-weight: 600; }
`

export function orcamentoHtml(d: OrcamentoDoc): string {
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
<title>${esc(nomeArquivoOrcamento(d.numero, d.data).replace(/\.pdf$/, ''))}</title>
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;900&display=swap">
<style>${CSS}</style></head><body><div class="page">
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
    <p class="nota">Retirada grátis no centro de BH. O endereço e o horário de retirada são enviados depois da confirmação do pagamento.${d.frete.modo === 'bike_gratis' ? ' Entrega grátis na região central, em horário comercial.' : ''}${d.frete.modo === 'uber_cliente' ? ' Se preferir receber em casa, a entrega é por Uber Entrega, por conta do cliente.' : ''}</p>
  </div>
</section>
<section class="passos"><p class="sec">Como fechar seu pedido</p><ol>
  <li><b>Pague pelo link</b>Pix (de qualquer banco) ou cartão, no WhatsApp.</li>
  <li><b>Envie a arte</b>${d.arte.modo === 'paga' || d.arte.modo === 'com_frete' ? 'Ou aprove a que criamos para você.' : 'Pronta para impressão, até o horário de corte.'}</li>
  <li><b>Receba ou retire</b>Avisamos assim que estiver pronto.</li>
</ol></section>
${d.upsell ? `<p class="upsell">${esc(d.upsell.texto)}</p>` : ''}
${d.politica ? `<p class="nota politica"><b>Condições:</b> ${esc(d.politica)}</p>` : ''}
<footer><div><b>${esc(emp.nome)}</b> · CNPJ ${esc(emp.cnpj)}<br>${contato}</div><div style="text-align:right">Este orçamento vale até ${esc(validade)}.<br>Depois dessa data, os valores e o prazo são recalculados.</div></footer>
</div></body></html>`
}
