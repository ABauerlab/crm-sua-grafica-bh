// Origem declarada do cliente ("como nos conheceu?"). Os valores são os mesmos de contacts.origem_declarada.
export const ORIGENS = [
  { value: 'instagram', label: 'Instagram' },
  { value: 'google', label: 'Google' },
  { value: 'site', label: 'Site' },
  { value: 'indicacao', label: 'Indicação' },
  { value: 'ja_era_cliente', label: 'Já era cliente' },
  { value: 'balcao', label: 'Passou pelo balcão' },
  { value: 'anuncio', label: 'Viu um anúncio' },
  { value: 'outro', label: 'Outro' },
] as const

export type Origem = (typeof ORIGENS)[number]['value']

/** Pedido manual: a origem é obrigatória quando o contato não veio de anúncio e ainda não tem origem declarada (cliente novo conta como "sem origem"). */
export function origemObrigatoria(c?: { first_referral?: Record<string, string> | null; origem_declarada?: string | null } | null): boolean {
  if (!c) return true
  return !c.first_referral && !c.origem_declarada
}
