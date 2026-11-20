// Fase 2: gerador de prévia de arte com marca d'água. Funções puras (sem APIs do Deno), testáveis em Node.

export interface PreviaBriefing {
  nome?: string
  empresa?: string
  telefone?: string
  instagram?: string
  servicos?: string
  cores_estilo?: string
}

/** Prompt para o modelo de IA: só pede o HTML/CSS/SVG da arte (sem a foto do produto nem a marca d'água, que entram depois). */
export function montarPromptArte(produtoDescricao: string, briefing: PreviaBriefing, feedback: string | null): string {
  const campos = [
    briefing.nome && `nome: ${briefing.nome}`,
    briefing.empresa && `empresa: ${briefing.empresa}`,
    briefing.telefone && `telefone: ${briefing.telefone}`,
    briefing.instagram && `instagram: ${briefing.instagram}`,
    briefing.servicos && `serviços/produtos: ${briefing.servicos}`,
    briefing.cores_estilo && `cores ou estilo pedido: ${briefing.cores_estilo}`,
  ].filter(Boolean).join('; ')
  return [
    'Você é um designer gráfico. Crie o layout de uma arte profissional para o seguinte item de gráfica rápida:',
    `Produto: ${produtoDescricao}.`,
    campos ? `Informações do cliente: ${campos}.` : 'O cliente não informou dados; use um exemplo genérico e elegante.',
    feedback ? `Ajuste pedido pelo cliente na rodada anterior: ${feedback}.` : '',
    'Responda SOMENTE com um documento HTML completo e autônomo (um único arquivo, CSS inline ou em <style>, sem imagens externas,',
    'sem JavaScript), com um elemento raiz <div id="arte"> de exatamente 1000x1000 pixels (unidades em px), fundo preenchido,',
    'tipografia legível e hierarquia visual clara (nome/empresa em destaque, dados de contato menores). Não inclua marca d\'água,',
    'não inclua texto algum sobre preço, SKU, fornecedor ou a própria Sua Gráfica BH. Não escreva nada fora do HTML.',
  ].filter(Boolean).join(' ')
}

/** Extrai o HTML da resposta do modelo (às vezes vem em bloco markdown ```html ... ```). */
export function extrairHtml(texto: string): string | null {
  const m = texto.match(/```(?:html)?\s*([\s\S]*?)```/i)
  const bruto = (m ? m[1] : texto).trim()
  if (!/<html|<div/i.test(bruto)) return null
  return bruto
}

const ESCAPAR: Record<string, string> = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }
export const esc = (s: string): string => String(s ?? '').replace(/[&<>"]/g, (c) => ESCAPAR[c])

/**
 * Monta a página final renderizada pelo Gotenberg: a arte do modelo sobreposta à foto real do produto,
 * com uma marca d'água forte cobrindo toda a imagem (texto repetido, diagonal, semi-transparente).
 * fotoUrl é uma URL já assinada/pública; nunca o caminho interno do bucket.
 */
export function montarPaginaPreview(artHtml: string, fotoUrl: string | null): string {
  const marcaDagua = Array.from({ length: 48 }, () => '<span>PRÉVIA · SUA GRÁFICA BH</span>').join('')
  return `<!doctype html><html><head><meta charset="utf-8"><style>
    * { box-sizing: border-box; }
    body { margin: 0; width: 1400px; height: 1400px; background: #e8e8ec; font-family: Arial, Helvetica, sans-serif; }
    .palco { position: relative; width: 1400px; height: 1400px; overflow: hidden; }
    .foto { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; filter: brightness(0.96); }
    .semfoto { position: absolute; inset: 0; background: linear-gradient(135deg, #d9d9e3, #c3c3cf); }
    .moldura { position: absolute; left: 200px; top: 200px; width: 1000px; height: 1000px; box-shadow: 0 30px 60px rgba(0,0,0,.35); border-radius: 8px; overflow: hidden; background: #fff; }
    .marca-dagua { position: absolute; inset: 0; display: flex; flex-wrap: wrap; align-content: center; justify-content: center; gap: 40px; transform: rotate(-28deg) scale(1.4); opacity: .22; pointer-events: none; }
    .marca-dagua span { font-size: 34px; font-weight: 800; color: #111; white-space: nowrap; font-family: Arial, Helvetica, sans-serif; }
  </style></head><body>
    <div class="palco">
      ${fotoUrl ? `<img class="foto" src="${esc(fotoUrl)}">` : '<div class="semfoto"></div>'}
      <div class="moldura">${artHtml}</div>
      <div class="marca-dagua">${marcaDagua}</div>
    </div>
  </body></html>`
}
