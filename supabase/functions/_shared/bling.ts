// Bling API v3: assinatura do webhook e textos de anúncio para marketplaces. Funções puras (testadas em Node).

/** O Bling assina o corpo cru com HMAC-SHA256 usando o client secret do app: cabeçalho X-Bling-Signature-256 = "sha256=<hex>". */
export async function assinaturaBlingValida(corpo: string, cabecalho: string | null, segredo: string | undefined): Promise<boolean> {
  if (!cabecalho || !segredo) return false
  const recebida = cabecalho.replace(/^sha256=/i, '').trim().toLowerCase()
  if (!/^[0-9a-f]{64}$/.test(recebida)) return false
  const chave = await crypto.subtle.importKey('raw', new TextEncoder().encode(segredo), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
  const mac = new Uint8Array(await crypto.subtle.sign('HMAC', chave, new TextEncoder().encode(corpo)))
  const esperada = [...mac].map((b) => b.toString(16).padStart(2, '0')).join('')
  let dif = 0
  for (let i = 0; i < 64; i++) dif |= esperada.charCodeAt(i) ^ recebida.charCodeAt(i)
  return dif === 0
}

/** Extrai o tipo de evento e o id do recurso do aviso do Bling (formatos v3: { event, data: { id } } ou { eventId, ... }). */
export function resumoEventoBling(p: Record<string, any>): { evento: string; recurso_id: string | null } {
  const evento = String(p?.event ?? p?.evento ?? p?.topic ?? 'desconhecido').slice(0, 80)
  const id = p?.data?.id ?? p?.data?.pedido?.id ?? p?.retorno?.pedidos?.[0]?.pedido?.numero ?? p?.id ?? null
  return { evento, recurso_id: id === null || id === undefined ? null : String(id).slice(0, 60) }
}

export interface ProdutoAnuncio {
  titulo: string; categoria: string; quantidade: number | null; impressao: string | null; formato: string | null
  material?: string | null; espessura?: string | null; acabamento?: string | null; prazo_dias: number; observacoes?: string[]
}

/** Título de busca (até 60 caracteres, limite do Mercado Livre): quantidade + produto + diferenciais. */
export function tituloMarketplace(p: ProdutoAnuncio, limite = 60): string {
  const qtd = p.quantidade && p.quantidade > 1 ? `${p.quantidade.toLocaleString('pt-BR')} ` : ''
  const base = `${qtd}${p.titulo}`.replace(/\s+/g, ' ').trim()
  const extras = [p.impressao?.replace('Colorido ', '').replace('Apenas na Frente', 'Frente'), 'Personalizado']
  let t = base
  for (const e of extras) if (e && `${t} ${e}`.length <= limite) t = `${t} ${e}`
  return t.length <= limite ? t : t.slice(0, limite).replace(/\s+\S*$/, '')
}

/** Descrição rica com tópicos, ficha e prazo (sem SKU, custo nem fornecedor). */
export function descricaoMarketplace(p: ProdutoAnuncio): string {
  const linhas = [
    `${p.titulo} personalizado com a sua arte, produzido em Belo Horizonte pela Sua Gráfica BH.`,
    '',
    '✔ O que você recebe:',
    p.quantidade ? `• ${p.quantidade.toLocaleString('pt-BR')} unidades` : null,
    p.impressao ? `• Impressão: ${p.impressao}` : null,
    p.formato ? `• Tamanho: ${p.formato}` : null,
    p.material ? `• Material: ${p.material}` : null,
    p.espessura ? `• Espessura: ${p.espessura}` : null,
    p.acabamento ? `• Acabamento: ${p.acabamento}` : null,
    '',
    '✔ Como funciona:',
    '• Depois da compra, você envia a arte pelo chat (PDF, CDR, AI, PNG ou JPG) ou pede a criação.',
    '• Você aprova a prova digital antes da produção.',
    `• Prazo de fabricação: ${p.prazo_dias} dias úteis após a aprovação da arte.`,
    ...(p.observacoes ?? []).slice(0, 3).map((o) => `• ${o}`),
  ]
  return linhas.filter((l) => l !== null).join('\n')
}
