// Montagem dos avisos ao dono (push e WhatsApp). Funções puras: testadas em Node (scripts/test-alertas.ts), usadas pela Edge Function alertas-enviar.
// Nunca entram aqui custo, piso, margem de fornecedor nem endereço de retirada: o lucro líquido é do dono e só vai para o número dele.

export interface AlertaFila {
  id: string
  tipo: string
  gravidade: 'alta' | 'baixa'
  motivo: string
  dados: Record<string, unknown>
  conversation_id?: string | null
  order_id?: string | null
  enviar_push: boolean
  enviar_whatsapp: boolean
  badge?: number
}

export interface PushPayload {
  title: string
  body: string
  url: string
  tag: string
  tipo: string
  badge: number
  gravidade: string
}

const str = (v: unknown, fallback = ''): string => (typeof v === 'string' && v.trim() ? v.trim() : fallback)
const corta = (s: string, n: number): string => (s.length <= n ? s : s.slice(0, n - 1).trimEnd() + '…')

export function montarPush(a: AlertaFila): PushPayload {
  const d = a.dados ?? {}
  const cliente = str(d.cliente, 'Cliente')
  const url = str(d.url, '/painel')
  let title: string
  let body: string
  switch (a.tipo) {
    case 'pedido_pago':
      title = `${d.teste ? '[TESTE] ' : ''}Pedido pago: ${str(d.pedido, 'novo pedido')}`
      body = `${cliente} pagou ${str(d.valor, '')}. Lucro líquido ${str(d.lucro_liquido, 'a confirmar')}. Previsão ${str(d.previsao, 'a confirmar')}.`
      break
    case 'nova_mensagem_humano':
      title = 'Nova mensagem'
      body = `${cliente} escreveu e está esperando você.`
      break
    case 'resumo':
      title = 'Resumo de avisos'
      body = a.motivo
      break
    case 'teste_notificacao':
      title = 'Notificação de teste'
      body = 'Deu certo: este aparelho recebe os avisos da Sua Gráfica BH.'
      break
    default:
      title = `Atenção: ${cliente}`
      body = a.motivo
  }
  return {
    title: corta(title, 60),
    body: corta(body, 170),
    url,
    // mesmo tipo e mesma conversa/pedido: a notificação nova substitui a anterior
    tag: `${a.tipo}:${a.conversation_id ?? a.order_id ?? 'geral'}`,
    tipo: a.tipo,
    badge: Math.max(0, Number(a.badge ?? 0)),
    gravidade: a.gravidade,
  }
}

/** Variáveis de template: sem quebra de linha, tabulação nem 4 espaços seguidos (regra da Meta); nunca vazias. */
export function varTemplate(v: unknown, max = 200): string {
  const s = String(v ?? '').replace(/[\r\n\t]+/g, ' ').replace(/ {2,}/g, ' ').trim()
  return corta(s || '-', max)
}

export type TemplateDono = { name: 'pedido_pago_dono' | 'alerta_atencao_dono'; params: string[] }

/** pedido_pago_dono: cliente, itens, valor, lucro líquido, previsão, link. alerta_atencao_dono: cliente, motivo, link. */
export function montarTemplate(a: AlertaFila): TemplateDono {
  const d = a.dados ?? {}
  if (a.tipo === 'pedido_pago') {
    return {
      name: 'pedido_pago_dono',
      params: [d.cliente, d.itens, d.valor, d.lucro_liquido, d.previsao, d.url].map((v, i) => varTemplate(v, i === 1 ? 300 : 200)),
    }
  }
  return { name: 'alerta_atencao_dono', params: [varTemplate(d.cliente ?? 'Resumo', 80), varTemplate(a.motivo, 300), varTemplate(d.url)] }
}

/** Texto livre (janela de 24 h do dono aberta). */
export function montarTexto(a: AlertaFila): string {
  const d = a.dados ?? {}
  const url = str(d.url)
  if (a.tipo === 'pedido_pago') {
    return [
      `${d.teste ? '[TESTE] ' : ''}Pedido pago por ${str(d.cliente, 'cliente')}.`,
      `Itens: ${str(d.itens, '-')}`,
      `Valor: ${str(d.valor, '-')} (${str(d.metodo, 'método não informado')})`,
      `Lucro líquido: ${str(d.lucro_liquido, 'a confirmar')}`,
      `Previsão: ${str(d.previsao, 'a confirmar')}`,
      `Abra o pedido no CRM: ${url}`,
    ].join('\n')
  }
  if (a.tipo === 'resumo') return `Resumo de avisos (${a.motivo})\nAbra o CRM: ${url}`
  return `Atenção no atendimento. Cliente: ${str(d.cliente, '-')}.\nMotivo: ${a.motivo}\nAbra no CRM: ${url}`
}

/** Mensagem ao cliente depois do pagamento. Sem SKU, custo, margem ou lucro. Endereço só aqui, depois de pago. */
export function montarConfirmacaoCliente(i: {
  nome: string
  pedido: string
  previsao: string
  arte_status?: string | null
  entrega?: string | null
  /** Persona do pós-pagamento (ex.: João Victor) e o artigo ("o" ou "a"). Sem persona, a mensagem é a de sempre. */
  persona?: string | null
  artigo?: string | null
}): string {
  // Versão curta: confirmação, pedido, previsão, uma frase sobre a arte e uma sobre a retirada. Sem "assistente virtual".
  const arte =
    i.arte_status === 'aprovada'
      ? 'Arte aprovada, seguimos para produção.'
      : i.arte_status === 'enviada'
        ? 'Recebemos a sua arte e estamos conferindo.'
        : i.arte_status === 'em_criacao'
          ? 'Estamos montando a arte para você aprovar.'
          : 'Tem arte? É só mandar aqui.'
  const entrega = i.entrega === 'uber' ? 'Combinamos a entrega por aqui.' : 'Aviso aqui quando estiver pronto para retirada.'
  const quem = i.persona ? `Aqui é ${i.artigo ? i.artigo + ' ' : ''}${i.persona}. ` : ''
  return `${i.persona ? `Oi, ${i.nome}! ` : ''}${quem}${i.persona ? 'Pagamento confirmado' : `Pagamento confirmado, ${i.nome}`}! Pedido ${i.pedido} na fila. Previsão: ${i.previsao}. ${arte} ${entrega}`
}

/** Variáveis do template pedido_pago_confirmacao: nome, número do pedido, previsão. */
export function templateConfirmacaoCliente(i: { nome: string; pedido: string; previsao: string }): string[] {
  return [varTemplate(i.nome, 60), varTemplate(i.pedido, 30), varTemplate(i.previsao, 30)]
}

/** O erro da Meta é definitivo para este canal (não adianta repetir)? Hoje: nenhum; o recuo do banco decide. */
export function janelaAberta(janelaAte: string | null | undefined, agora = Date.now()): boolean {
  if (!janelaAte) return false
  const t = Date.parse(janelaAte)
  return Number.isFinite(t) && t > agora
}
