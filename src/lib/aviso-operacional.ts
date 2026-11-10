import { windowInfo } from '@/lib/window'

/** Template aprovado (utilidade) que reabre a janela de 24 h: "Olá, {{1}}! ... sobre o seu pedido. {{2}} Qualquer dúvida...". */
export const TEMPLATE_AVISO = { name: 'aviso_operacional_pedido', language: 'pt_BR' } as const

/** O WhatsApp não aceita quebra de linha nem 4 espaços seguidos em variável de template. */
export const limparVariavel = (t: string) => t.replace(/\s*\n+\s*/g, ' ').replace(/ {2,}/g, ' ').trim()

export const primeiroNome = (nome: string | null | undefined) => (nome?.trim().split(/\s+/)[0]) || 'tudo bem'

export function textoPedidoPronto(entrega: 'retirada' | 'uber' | null): string {
  return entrega === 'uber'
    ? 'Seu pedido está pronto e embalado, e já vamos combinar a entrega por aqui.'
    : 'Seu pedido está pronto e embalado, aguardando retirada na Rua Rio de Janeiro, 462, sala 2217, Edifício Helena Passig (Praça Sete). Me avise o melhor horário para agendarmos a retirada.'
}

/** Corpo que será enviado: texto livre com a janela aberta, ou o template quando fechada. */
export function montarAviso(conv: { last_inbound_at: string | null } | null, nome: string | null | undefined, detalhe: string) {
  const aberta = !!conv && windowInfo(conv).open
  const d = limparVariavel(detalhe)
  return aberta
    ? { aberta, body: { text: `Olá, ${primeiroNome(nome)}! ${d}` } }
    : { aberta, body: { template_name: TEMPLATE_AVISO.name, language: TEMPLATE_AVISO.language, variables: [primeiroNome(nome), d] } }
}
