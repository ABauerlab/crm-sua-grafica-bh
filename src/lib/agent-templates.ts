// Templates do WhatsApp usados pelo agente de IA e pelas automações. A fonte da verdade do status é a Meta (templates_cache);
// aqui ficam o texto enviado para aprovação, a categoria pedida e onde cada um é usado.

export interface AgentTemplate {
  name: string
  category: 'UTILITY' | 'MARKETING'
  body: string
  vars: string[]
  use: string
}

export const AGENT_TEMPLATES: AgentTemplate[] = [
  {
    name: 'pedido_pago_dono',
    category: 'UTILITY',
    body: 'Pedido pago por {{1}}. Itens: {{2}}. Valor: {{3}}. Lucro líquido: {{4}}. Previsão: {{5}}. Abra o pedido no CRM: {{6}} para dar atenção agora.',
    vars: ['cliente', 'itens', 'valor', 'lucro líquido', 'previsão', 'link do pedido no CRM'],
    use: 'Alerta ao dono quando o pagamento é confirmado',
  },
  {
    name: 'alerta_atencao_dono',
    category: 'UTILITY',
    body: 'Atenção no atendimento. Cliente: {{1}}. Motivo: {{2}}. Abra a conversa no CRM: {{3}} para ver os detalhes.',
    vars: ['cliente', 'motivo', 'link da conversa no CRM'],
    use: 'Alerta ao dono quando o agente chama o responsável',
  },
  {
    name: 'pedido_pago_confirmacao',
    category: 'UTILITY',
    body: 'Pagamento confirmado, {{1}}! Seu pedido {{2}} já entrou na fila. Previsão de ficar pronto: {{3}}. Se ainda não enviou a arte, pode mandar por aqui mesmo.',
    vars: ['nome', 'número do pedido', 'previsão'],
    use: 'Confirmação ao cliente depois do pagamento',
  },
  {
    name: 'pedido_pronto_retirada',
    category: 'UTILITY',
    body: 'Oi, {{1}}! Seu pedido {{2}} está pronto para retirada. Endereço: R. Rio de Janeiro, 462, 22º andar, Sala 2217, Centro, Belo Horizonte. Atendimento: segunda a quinta das 9h às 17h e sexta das 9h às 18h30. Quando chegar, é só avisar por aqui.',
    vars: ['nome', 'número do pedido'],
    use: 'Aviso de pedido pronto (o endereço só vai para quem já pagou)',
  },
  {
    name: 'pedido_saiu_entrega',
    category: 'UTILITY',
    body: 'Oi, {{1}}! Seu pedido {{2}} saiu para entrega. Acompanhe por aqui: {{3}}. Qualquer dúvida, é só responder esta mensagem.',
    vars: ['nome', 'número do pedido', 'link de acompanhamento'],
    use: 'Aviso de saída para entrega',
  },
  {
    name: 'pagamento_pendente',
    category: 'UTILITY',
    body: 'Oi, {{1}}! Seu orçamento {{2}} está aguardando o pagamento. O link é {{3}}. Se precisar de ajuda para pagar, é só responder por aqui.',
    vars: ['nome', 'número do orçamento', 'link de pagamento'],
    use: 'Lembretes de pagamento pendente (1 h, 6 h e 24 h)',
  },
  {
    name: 'pos_venda_satisfacao',
    category: 'UTILITY',
    body: 'Oi, {{1}}! Seu pedido {{2}} foi entregue. Deu tudo certo? Se precisar de mais alguma coisa, é só chamar por aqui.',
    vars: ['nome', 'número do pedido'],
    use: 'Satisfação depois da entrega',
  },
  {
    name: 'orcamento_vence_hoje',
    category: 'MARKETING',
    body: 'Oi, {{1}}! Seu orçamento {{2}} vale até {{3}}. Dá para fechar hoje e garantir a entrega no prazo. Quer que eu reenvie o link de pagamento?',
    vars: ['nome', 'número do orçamento', 'validade'],
    use: 'Follow-up F2 e F3 com a janela de 24 h fechada',
  },
  {
    name: 'ultima_chance_orcamento',
    category: 'MARKETING',
    body: 'Oi, {{1}}, passando para saber se ainda faz sentido seguir com o seu pedido de {{2}}. Se quiser ajustar quantidade ou acabamento, me chama por aqui que a gente resolve rápido.',
    vars: ['nome', 'produto'],
    use: 'Follow-up F4 sem benefício',
  },
  {
    name: 'recompra_lembrete',
    category: 'MARKETING',
    body: 'Oi, {{1}}! Já faz um tempinho desde o seu pedido de {{2}}. Quer repor ou aproveitar para incluir algo novo? Me responde por aqui que eu monto o orçamento rapidinho.',
    vars: ['nome', 'produto'],
    use: 'Lembrete de recompra',
  },
  {
    name: 'condicao_especial_orcamento',
    category: 'MARKETING',
    body: 'Oi, {{1}}! Consegui uma condição especial no seu orçamento {{2}}: {{3}}. Vale até {{4}}. Quer que eu envie o link de pagamento atualizado?',
    vars: ['nome', 'número do orçamento', 'condição', 'validade'],
    use: 'Follow-ups F3 e F4 com a janela de 24 h fechada',
  },
]

/** Regras da Meta: o corpo não começa nem termina com variável e duas variáveis não ficam coladas. */
export function templateProblems(t: AgentTemplate): string[] {
  const problems: string[] = []
  if (/^\s*\{\{\d+\}\}/.test(t.body)) problems.push('começa com variável')
  if (/\{\{\d+\}\}\s*[.!?]?\s*$/.test(t.body)) problems.push('termina com variável')
  if (/\{\{\d+\}\}\s*\{\{\d+\}\}/.test(t.body)) problems.push('variáveis coladas')
  const found = [...t.body.matchAll(/\{\{(\d+)\}\}/g)].map((m) => Number(m[1]))
  if (found.join(',') !== found.map((_, i) => i + 1).join(',')) problems.push('variáveis fora de ordem')
  if (found.length !== t.vars.length) problems.push('número de variáveis diferente da lista')
  return problems
}
