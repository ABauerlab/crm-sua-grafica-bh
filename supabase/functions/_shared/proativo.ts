// Regras puras do envio proativo (follow-ups, pós-venda e avisos de status). Testadas em scripts/test-proativo.ts.
export const JANELA_MS = 24 * 60 * 60 * 1000

/** A janela de atendimento de 24 h (texto livre) está aberta? Só a mensagem do cliente abre; o clique no anúncio só barateia template. */
export function janelaAberta(lastInboundAt: string | null | undefined, agora = Date.now()): boolean {
  return !!lastInboundAt && new Date(lastInboundAt).getTime() + JANELA_MS > agora
}

/** Variável de template aceita pela Meta: sem quebra de linha, sem tabulação, sem 4 espaços seguidos, não vazia. */
export function limparParametro(valor: unknown): string {
  const t = String(valor ?? '').replace(/[\r\n\t]+/g, ' ').replace(/ {2,}/g, ' ').trim().slice(0, 900)
  return t || '-'
}

export type Decisao =
  | { acao: 'livre' }
  | { acao: 'template' }
  | { acao: 'recusar'; motivo: string; permanente: boolean }

export interface EntradaDecisao {
  via: 'livre' | 'template'
  janelaAberta: boolean
  temTemplate: boolean
  categoria: string | null // categoria do template na Meta (MARKETING, UTILITY...)
  optout: boolean
  consentimento: string | null // none | opted_in | opted_out
  exigirOptin: boolean
}

/** Decide como (e se) enviar. Utilidade (avisos de pedido) não depende de promoções; marketing exige opt-in. */
export function decidirEnvio(e: EntradaDecisao): Decisao {
  if (e.via === 'livre' && e.janelaAberta) return { acao: 'livre' }
  if (!e.temTemplate) return { acao: 'recusar', motivo: 'janela_fechada', permanente: true }
  const marketing = (e.categoria ?? '').toUpperCase() === 'MARKETING'
  if (marketing) {
    if (e.optout || e.consentimento === 'opted_out') return { acao: 'recusar', motivo: 'optout', permanente: true }
    if (e.exigirOptin && e.consentimento !== 'opted_in') return { acao: 'recusar', motivo: 'sem_optin_marketing', permanente: true }
  }
  return { acao: 'template' }
}

/** Erros da Meta que não adianta repetir. */
export function erroPermanente(codigo: number | null | undefined): boolean {
  return codigo != null && [131026, 131049, 131050, 131051, 132000, 132001, 132005, 132007, 132012, 132015, 132016].includes(codigo)
}
