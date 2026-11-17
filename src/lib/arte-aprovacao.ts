/** Mensagem que pede a aprovação da arte. Mesma redação do template `aprovacao_arte` (utilidade) da Meta. */
export const TEMPLATE_ARTE = { name: 'aprovacao_arte', language: 'pt_BR' } as const

const primeiroNome = (nome: string | null | undefined) => nome?.trim().split(/\s+/)[0] || 'tudo bem'

export const CORPO_APROVACAO_ARTE =
  'Oi, {{1}}! Sua arte está pronta e segue aqui para aprovação.\n\nConfira com calma textos, nomes, telefones, cores e tamanho.\n\nSe estiver tudo certo, responda *APROVADO*. Depois disso a arte entra em produção e não dá mais para corrigir. Se tiver qualquer ajuste, me fala agora.'

export function mensagemAprovacaoArte(nome: string | null | undefined): string {
  return CORPO_APROVACAO_ARTE.replace('{{1}}', primeiroNome(nome))
}
