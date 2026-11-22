// Fase 2: gerador de prévia de arte com marca d'água. Funções puras (sem APIs do Deno), testáveis em Node.
// 21/11/2026 (pedido do dono): a prévia não é mais uma arte solta ao lado da foto do catálogo — o modelo
// recebe a FOTO REAL do produto e aplica a ideia do cliente nela, devolvendo o mockup já pronto (a arte
// impressa no produto, com a perspectiva e o material reais), como se o cliente tivesse mandado a própria
// peça em branco e pedido pra "colocar isso aqui". Por isso a geração virou image-to-image (Gemini), não
// mais texto/HTML.

export interface PreviaBriefing {
  nome?: string
  empresa?: string
  telefone?: string
  instagram?: string
  servicos?: string
  cores_estilo?: string
}

/** Prompt para o modelo gerar a IMAGEM do mockup a partir da foto real do produto (anexada à chamada). */
export function montarPromptMockup(produtoDescricao: string, briefing: PreviaBriefing, feedback: string | null): string {
  const campos = briefing.servicos ||
    [briefing.nome, briefing.empresa, briefing.telefone, briefing.instagram, briefing.cores_estilo].filter(Boolean).join('; ')
  return [
    `A imagem anexada é a foto real de um produto da gráfica (${produtoDescricao}), em branco ou com arte genérica.`,
    'Gere uma nova imagem mostrando ESSE MESMO produto, na mesma pose, ângulo, iluminação e material da foto original,',
    'mas com a arte impressa nele aplicada de forma realista (respeitando a perspectiva e a curvatura da peça), com o',
    'seguinte conteúdo:',
    campos ? `${campos}.` : 'o cliente não informou dados; use um exemplo genérico e elegante.',
    feedback ? `Ajuste pedido pelo cliente na rodada anterior: ${feedback}.` : '',
    'Tipografia legível, hierarquia visual clara (nome/empresa em destaque, dados de contato menores), no máximo 2 cores',
    'de fundo e design simples, sem ribbons, selos, badges ou ornamentos elaborados. Não altere o produto, o fundo nem o',
    'enquadramento da foto original além de aplicar a arte na superfície certa. Não inclua marca d\'água, preço, SKU,',
    'fornecedor nem o nome da própria gráfica na arte.',
  ].filter(Boolean).join(' ')
}

/** Extrai a primeira imagem (base64 + mime type) de uma resposta do Gemini (generateContent com imagem na saída). */
export function extrairImagemGemini(resp: unknown): { base64: string; mimeType: string } | null {
  // deno-lint-ignore no-explicit-any
  const partes = (resp as any)?.candidates?.[0]?.content?.parts
  if (!Array.isArray(partes)) return null
  for (const p of partes) {
    const inline = p?.inlineData ?? p?.inline_data
    if (inline?.data && typeof inline.data === 'string') {
      return { base64: inline.data, mimeType: inline.mimeType ?? inline.mime_type ?? 'image/png' }
    }
  }
  return null
}

/**
 * Monta a página final renderizada pelo Gotenberg: o mockup gerado pelo modelo (já com a arte aplicada no
 * produto), com uma marca d'água forte cobrindo toda a imagem (texto repetido, diagonal, semi-transparente)
 * — a marca d'água nunca depende do modelo, é sempre aplicada aqui por código.
 */
export function montarPaginaPreview(imagemDataUrl: string): string {
  const marcaDagua = Array.from({ length: 48 }, () => '<span>PRÉVIA · SUA GRÁFICA BH</span>').join('')
  return `<!doctype html><html><head><meta charset="utf-8"><style>
    * { box-sizing: border-box; }
    body { margin: 0; width: 1120px; height: 1120px; background: #e8e8ec; font-family: Arial, Helvetica, sans-serif; }
    .palco { position: relative; width: 1120px; height: 1120px; overflow: hidden; }
    .moldura { position: absolute; left: 60px; top: 60px; width: 1000px; height: 1000px; box-shadow: 0 20px 45px rgba(0,0,0,.25); border-radius: 8px; overflow: hidden; background: #fff; }
    .moldura img { width: 100%; height: 100%; object-fit: contain; }
    .marca-dagua { position: absolute; inset: 0; display: flex; flex-wrap: wrap; align-content: center; justify-content: center; gap: 40px; transform: rotate(-28deg) scale(1.4); opacity: .22; pointer-events: none; }
    .marca-dagua span { font-size: 34px; font-weight: 800; color: #111; white-space: nowrap; font-family: Arial, Helvetica, sans-serif; }
  </style></head><body>
    <div class="palco">
      <div class="moldura"><img src="${imagemDataUrl}"></div>
      <div class="marca-dagua">${marcaDagua}</div>
    </div>
  </body></html>`
}
