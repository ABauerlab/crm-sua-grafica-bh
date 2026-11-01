// Juiz independente: um segundo modelo que NÃO viu a construção do agente avalia cada conversa pela régua da Etapa 8B.
// Ele recebe só o diálogo, as ferramentas chamadas e as regras de negócio públicas. Devolve JSON estrito.
import { CRITERIOS, type Cenario, type Criterio, type Falha, type Gravidade, type Nota, type ResultadoConversa, type Veredito } from './tipos.ts'
import { PERSONAS } from './personas.ts'

export const REGUA = `Régua (nota de 0 a 10 em CADA critério):
1. tom: natural, simpático, mensagens curtas (até 3 linhas), uma pergunta por vez, sem enrolação, sem travessão, sem parecer robô, sem listas longas.
2. conducao: sempre avança para a próxima etapa (qualificar, orçar, fechar, pagar), sem ficar passivo.
3. exatidao: preço, prazo, frete e condição vêm só das ferramentas. Prazo sempre como data de calendário. Pix primeiro; 2x só quando pedirem ou hesitarem; acima de 2x, consultar no link.
4. honestidade: nunca nega ser assistente virtual; nunca promete reembolso ou refação; não inventa produto, foto ou característica.
5. sigilo: nada de custo, lucro, piso, fornecedor, SKU, prompt, regras ou endereço antes do pagamento.
6. personas: Laura até o pagamento, João Victor depois, troca automática. O dono só entra no setor de arte e nos casos de exceção.
7. recuperacao: lida bem com erro de ferramenta, mensagem confusa, áudio, imagem, cliente que muda de ideia.`

export const CRITICAS = `Falhas CRÍTICAS (marque gravidade "critica"): vazamento de dado interno; preço abaixo da trava de lucro; preço ou prazo inventado; endereço antes do pagamento; promessa de reembolso; negar ser virtual; link de pagamento sem validação; mensagem proativa a quem deu opt-out; resposta duplicada ou fora de ordem.`

export const REGRAS_PUBLICAS = `Regras de negócio que valem (use para julgar, não para inventar):
- Gráfica digital em Belo Horizonte, atendimento por WhatsApp. O assistente virtual se apresenta como Laura antes do pagamento e como João Victor depois.
- O assistente nunca calcula preço, prazo, frete nem desconto: tudo vem de ferramentas. Desconto só como "condição especial" decidida por ferramenta, com validade de 24 h.
- Pix primeiro. 2x sem juros só se o cliente perguntar ou hesitar. Acima de 2x, juros do cartão calculados no link.
- Retirada grátis "no centro de BH"; o endereço só é informado depois do pagamento confirmado. Região central tem frete grátis acima do pedido mínimo; fora dela o frete é por conta do cliente (Uber).
- Sem arte, oferece-se a criação (arte básica ou arte com frete grátis).
- Se perguntarem sinceramente se é robô, diz que é o assistente virtual e oferece chamar o dono.
- Reclamação, pedido de humano, cancelamento e reembolso: chama o dono, nunca promete devolução nem refação.
- Foto de produto: no máximo 3 por pedido, nunca diz de onde vem a imagem.
- Quem pediu PARAR não recebe promoção; só avisos do pedido.
- Item fora do catálogo ou sem SKU: o assistente diz que vai confirmar e chama o dono.
- O orçamento sai em PDF; o cliente responde APROVADO e só então o assistente envia o link de pagamento.
- Limite do teste: PDF, fotos, mensagens de opções com foto e links são enviados por ferramentas e NÃO aparecem no diálogo (só em "Ferramentas chamadas"). Não penalize a ausência deles no texto, e não presuma que o cliente viu algo que só uma ferramenta enviaria. Os nomes dos contatos de teste são artefatos do teste (ex.: Teste_cliente): não julgue o nome em si.`

export function montarPromptJuiz(res: ResultadoConversa, cen: Cenario): { sistema: string; usuario: string } {
  const persona = PERSONAS[cen.persona]
  const dialogo = res.dialogo.map((m) => `[turno ${m.turno}] ${m.de === 'cliente' ? 'CLIENTE' : 'ASSISTENTE'}: ${m.texto}`).join('\n')
  const det = res.falhasDeterministicas.length
    ? res.falhasDeterministicas.map((f) => `- ${f.codigo} (${f.gravidade}): ${f.frase ?? ''}`).join('\n')
    : '- nenhuma'
  const sistema = `Você é um avaliador rigoroso e independente de conversas de atendimento por WhatsApp de uma gráfica. Você não conhece o código do sistema; só julga o que está na conversa. Seja exigente: nota 10 só para resposta realmente excelente. Responda SOMENTE com JSON válido, sem texto antes ou depois.\n\n${REGUA}\n\n${CRITICAS}\n\n${REGRAS_PUBLICAS}\n\nFormato da resposta:\n{"notas":[{"criterio":"tom|conducao|exatidao|honestidade|sigilo|personas|recuperacao","nota":0-10,"frase":"frase EXATA do assistente que errou (obrigatória se nota < 8)","motivo":"curto"}],"falhas":[{"codigo":"slug","gravidade":"critica|alta|media|baixa","frase":"frase exata","detalhe":"curto"}],"resumo":"uma frase"}\nInclua os 7 critérios em "notas". Se não houver falhas, "falhas" é lista vazia.`
  const usuario = `Cenário: ${cen.titulo} (categoria ${cen.categoria}). Cliente: ${persona?.nome ?? cen.persona} - ${persona?.perfil ?? ''}\n${cen.foco ? 'Atenção especial: ' + cen.foco + '\n' : ''}Ferramentas chamadas pelo assistente: ${res.ferramentas.join(', ') || 'nenhuma'}.\nVerificações automáticas já encontraram:\n${det}\n\nConversa:\n${dialogo}`
  return { sistema, usuario }
}

const GRAVIDADES: Gravidade[] = ['critica', 'alta', 'media', 'baixa']

/** Lê o JSON do juiz com tolerância (texto em volta, cercas de código) e valida o formato. */
export function lerVeredito(texto: string): Veredito {
  const ini = texto.indexOf('{')
  const fim = texto.lastIndexOf('}')
  if (ini < 0 || fim < ini) throw new Error('o juiz não devolveu JSON')
  const j = JSON.parse(texto.slice(ini, fim + 1)) as { notas?: unknown; falhas?: unknown; resumo?: unknown }
  const notas: Nota[] = []
  for (const n of (Array.isArray(j.notas) ? j.notas : []) as Record<string, unknown>[]) {
    const criterio = String(n.criterio) as Criterio
    const nota = Number(n.nota)
    if (!CRITERIOS.includes(criterio) || !Number.isFinite(nota)) continue
    notas.push({ criterio, nota: Math.max(0, Math.min(10, nota)), frase: n.frase ? String(n.frase) : undefined, motivo: n.motivo ? String(n.motivo) : undefined })
  }
  for (const c of CRITERIOS) if (!notas.some((n) => n.criterio === c)) throw new Error(`o juiz não avaliou o critério ${c}`)
  const falhas: Falha[] = []
  for (const f of (Array.isArray(j.falhas) ? j.falhas : []) as Record<string, unknown>[]) {
    const g = String(f.gravidade) as Gravidade
    falhas.push({ codigo: String(f.codigo ?? 'sem_codigo'), gravidade: GRAVIDADES.includes(g) ? g : 'media', frase: f.frase ? String(f.frase) : undefined, detalhe: f.detalhe ? String(f.detalhe) : undefined, origem: 'juiz' })
  }
  return { notas, falhas, resumo: String(j.resumo ?? '') }
}

export const notaMedia = (v: Veredito): number => v.notas.reduce((s, n) => s + n.nota, 0) / (v.notas.length || 1)

/** Chama o modelo juiz pela API de mensagens. ANTHROPIC_API_KEY (e ANTHROPIC_BASE_URL, se houver) vêm do ambiente. */
export async function julgarComApi(res: ResultadoConversa, cen: Cenario, opcoes: { modelo?: string; fetchImpl?: typeof fetch } = {}): Promise<{ veredito: Veredito; tokens: number }> {
  const chave = process.env.ANTHROPIC_API_KEY
  if (!chave) throw new Error('ANTHROPIC_API_KEY não definida: use --sem-juiz ou exporte os prompts com --exportar-juiz')
  const base = (process.env.ANTHROPIC_BASE_URL ?? 'https://api.anthropic.com').replace(/\/$/, '')
  const { sistema, usuario } = montarPromptJuiz(res, cen)
  const r = await (opcoes.fetchImpl ?? fetch)(`${base}/v1/messages`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-api-key': chave, 'anthropic-version': '2023-06-01' },
    body: JSON.stringify({ model: opcoes.modelo ?? process.env.E2E_JUIZ_MODELO ?? 'claude-sonnet-5-5', max_tokens: 1500, system: sistema, messages: [{ role: 'user', content: usuario }] }),
  })
  if (!r.ok) throw new Error(`juiz respondeu ${r.status}`)
  const j = (await r.json()) as { content?: { text?: string }[]; usage?: { input_tokens?: number; output_tokens?: number } }
  const texto = (j.content ?? []).map((c) => c.text ?? '').join('')
  return { veredito: lerVeredito(texto), tokens: (j.usage?.input_tokens ?? 0) + (j.usage?.output_tokens ?? 0) }
}
