// Fase 2: gerador de prévia de arte com marca d'água. Funções puras (sem APIs do Deno), testáveis em Node.

export interface PreviaBriefing {
  nome?: string
  empresa?: string
  telefone?: string
  instagram?: string
  servicos?: string
  cores_estilo?: string
}

/** Prompt para o modelo de IA: só pede o HTML/CSS/SVG da arte (sem a foto do produto nem a marca d'água, que entram depois).
 * O cliente escreve a ideia num único campo de texto livre (nome, empresa, contato, cores, estilo, o que quiser);
 * os campos estruturados antigos (nome/empresa/telefone/instagram/cores_estilo) ficam como fallback de compatibilidade. */
export function montarPromptArte(produtoDescricao: string, briefing: PreviaBriefing, feedback: string | null): string {
  const campos = briefing.servicos ||
    [briefing.nome, briefing.empresa, briefing.telefone, briefing.instagram, briefing.cores_estilo].filter(Boolean).join('; ')
  return [
    'Você é um designer gráfico. Crie o layout de uma arte profissional para o seguinte item de gráfica rápida:',
    `Produto: ${produtoDescricao}.`,
    campos ? `A ideia do cliente, nas próprias palavras dele: ${campos}.` : 'O cliente não informou dados; use um exemplo genérico e elegante.',
    feedback ? `Ajuste pedido pelo cliente na rodada anterior: ${feedback}.` : '',
    'Responda SOMENTE com <div id="arte"> ... </div> (nada de <html>, <head> nem <!doctype>, nada fora dessa div),',
    'de exatamente 1000x1000 pixels (unidades em px), CSS só inline (atributo style, nunca <style> nem classes), sem imagens',
    'externas nem JavaScript. Fundo preenchido, tipografia legível, hierarquia visual clara (nome/empresa em destaque, dados',
    'de contato menores). Design simples e direto: no máximo 2 cores de fundo (gradiente simples permitido) e no máximo um',
    'elemento decorativo (uma borda, uma faixa ou um ícone simples em CSS); nunca use ribbons, selos, badges, logos ou',
    'ornamentos elaborados. Seja econômico: a resposta inteira deve ficar bem abaixo de 1500 palavras. Não inclua marca d\'água,',
    'não inclua texto algum sobre preço, SKU, fornecedor ou a própria Sua Gráfica BH. Não escreva nada fora da div.',
  ].filter(Boolean).join(' ')
}

/** Extrai o HTML da resposta do modelo (às vezes vem em bloco markdown ```html ... ```) e valida que não ficou
 * truncado (resposta cortada pelo limite de tokens virava quadrado branco com um fragmento de texto solto, ex.: "ion"). */
export function extrairHtml(texto: string): string | null {
  const fechado = texto.match(/```(?:html)?\s*([\s\S]*?)```/i)
  // Bloco markdown sem fechar (resposta cortada no meio): usa o que vier depois da cerca de abertura.
  const aberto = !fechado ? texto.match(/```(?:html)?\s*([\s\S]*)/i) : null
  const bruto = (fechado ? fechado[1] : aberto ? aberto[1] : texto).trim()
  if (bruto.length < 200) return null
  if (!/<div[^>]*id=["']arte["']/i.test(bruto)) return null
  const abertura = (bruto.match(/<div\b/gi) ?? []).length
  const fechamento = (bruto.match(/<\/div>/gi) ?? []).length
  if (abertura === 0 || abertura !== fechamento) return null
  if (!/<\/div>\s*$/i.test(bruto) && !/<\/html>\s*$/i.test(bruto)) return null
  return bruto
}

const ESCAPAR: Record<string, string> = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }
export const esc = (s: string): string => String(s ?? '').replace(/[&<>"]/g, (c) => ESCAPAR[c])

/**
 * Monta a página final renderizada pelo Gotenberg: só a arte do modelo (1000x1000, proporção exata), com
 * moldura/sombra limpa e uma marca d'água forte cobrindo toda a imagem (texto repetido, diagonal,
 * semi-transparente). A foto real do produto é mostrada separada, pela própria página /previa (sem cortar,
 * object-contain), não fica mais composta nesta imagem — item 2 do pedido do dono, 21/11/2026.
 */
export function montarPaginaPreview(artHtml: string, _fotoUrl: string | null): string {
  const marcaDagua = Array.from({ length: 48 }, () => '<span>PRÉVIA · SUA GRÁFICA BH</span>').join('')
  return `<!doctype html><html><head><meta charset="utf-8"><style>
    * { box-sizing: border-box; }
    body { margin: 0; width: 1120px; height: 1120px; background: #e8e8ec; font-family: Arial, Helvetica, sans-serif; }
    .palco { position: relative; width: 1120px; height: 1120px; overflow: hidden; }
    .moldura { position: absolute; left: 60px; top: 60px; width: 1000px; height: 1000px; box-shadow: 0 20px 45px rgba(0,0,0,.25); border-radius: 8px; overflow: hidden; background: #fff; }
    .marca-dagua { position: absolute; inset: 0; display: flex; flex-wrap: wrap; align-content: center; justify-content: center; gap: 40px; transform: rotate(-28deg) scale(1.4); opacity: .22; pointer-events: none; }
    .marca-dagua span { font-size: 34px; font-weight: 800; color: #111; white-space: nowrap; font-family: Arial, Helvetica, sans-serif; }
  </style></head><body>
    <div class="palco">
      <div class="moldura">${artHtml}</div>
      <div class="marca-dagua">${marcaDagua}</div>
    </div>
  </body></html>`
}
