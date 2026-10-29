const escapeHtml = (value) => String(value ?? '')
  .replaceAll('&', '&amp;')
  .replaceAll('<', '&lt;')
  .replaceAll('>', '&gt;')
  .replaceAll('"', '&quot;')
  .replaceAll("'", '&#039;');

const money = (value) => Number(value || 0).toLocaleString('pt-BR', {
  style: 'currency', currency: 'BRL'
});

const date = (value) => value
  ? new Intl.DateTimeFormat('pt-BR', { dateStyle: 'short' }).format(new Date(value))
  : 'A confirmar';

/**
 * Renderiza somente dados públicos do orçamento.
 * Nunca aceite neste template: custo, margem, piso, fornecedor ou SKU.
 */
export function renderOrcamentoPdf(data) {
  const items = (data.itens || []).map((item) => `
    <tr>
      <td><strong>${escapeHtml(item.descricao)}</strong><br><small>${escapeHtml(item.especificacao || '')}</small></td>
      <td class="number">${escapeHtml(item.quantidade)}</td>
      <td class="number">${money(item.valor_unitario)}</td>
      <td class="number">${money(item.valor_total)}</td>
    </tr>`).join('');

  const special = data.condicaoEspecial
    ? `<div class="special"><strong>Condição especial válida até ${escapeHtml(date(data.condicaoEspecial.validaAte))}</strong><br>${money(data.condicaoEspecial.total)}</div>`
    : '';

  return `<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><style>
    :root{--ink:#202124;--muted:#68707a;--brand:#e85d04;--soft:#fff4eb;--line:#e7e9ec}
    *{box-sizing:border-box}body{font-family:Arial,sans-serif;color:var(--ink);margin:0;font-size:12px}
    .page{max-width:760px;margin:auto;padding:28px}.header{display:flex;justify-content:space-between;gap:20px;border-bottom:3px solid var(--brand);padding-bottom:16px}
    .brand{font-size:22px;font-weight:800;color:var(--brand)}.muted{color:var(--muted)}h1{font-size:22px;margin:24px 0 4px}h2{font-size:13px;margin:20px 0 8px}
    .meta{display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin:18px 0}.box{border:1px solid var(--line);border-radius:8px;padding:10px}.box strong{display:block;margin-top:3px}
    table{width:100%;border-collapse:collapse}th{text-align:left;background:#f6f7f8;padding:9px}td{border-bottom:1px solid var(--line);padding:9px;vertical-align:top}.number{text-align:right;white-space:nowrap}
    .totals{margin-left:auto;max-width:280px;margin-top:14px}.total{font-size:18px;font-weight:800;color:var(--brand)}.special{background:var(--soft);border-left:4px solid var(--brand);padding:12px;margin-top:16px}
    .footer{border-top:1px solid var(--line);margin-top:24px;padding-top:12px;color:var(--muted);line-height:1.5}
    @media(max-width:560px){.page{padding:16px}.meta{grid-template-columns:1fr}.header{display:block}.meta .box{min-height:0}table{font-size:11px}}
  </style></head><body><main class="page">
    <header class="header"><div><div class="brand">Sua Gráfica BH</div><div class="muted">${escapeHtml(data.empresa?.subtitulo || 'Gráfica online em Belo Horizonte')}</div></div><div class="muted">${escapeHtml(data.empresa?.cnpj || 'CNPJ 58.481.181/0001-03')}</div></header>
    <h1>Orçamento ${escapeHtml(data.numero)}</h1><div class="muted">Preparado em ${escapeHtml(date(data.data))}</div>
    <section class="meta"><div class="box">Cliente<strong>${escapeHtml(data.cliente?.nome)}</strong></div><div class="box">Validade<strong>${escapeHtml(date(data.validoAte))}</strong></div><div class="box">Previsão<strong>${escapeHtml(data.dataPrevistaTexto || date(data.dataPrevista))}</strong></div></section>
    <h2>Itens do orçamento</h2><table><thead><tr><th>Descrição</th><th class="number">Qtd.</th><th class="number">Unitário</th><th class="number">Total</th></tr></thead><tbody>${items}</tbody></table>
    <div class="totals"><div>Subtotal: <strong>${money(data.subtotal)}</strong></div><div>Arte: <strong>${money(data.valorArte)}</strong></div><div>Frete: <strong>${escapeHtml(data.freteTexto || money(data.valorFrete))}</strong></div><div class="total">Total: ${money(data.total)}</div></div>
    ${special}${data.upsell ? `<div class="footer"><strong>Você também pode gostar:</strong> ${escapeHtml(data.upsell)}</div>` : ''}
    <div class="footer">Pagamento por Pix ou cartão pelo link. Retirada grátis, sem endereço neste orçamento. O endereço e o horário de retirada são enviados depois da confirmação do pagamento. Este orçamento é válido até ${escapeHtml(date(data.validoAte))}.</div>
  </main></body></html>`;
}
