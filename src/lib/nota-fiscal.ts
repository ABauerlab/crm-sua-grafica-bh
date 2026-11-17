const primeiroNome = (nome: string | null | undefined) => nome?.trim().split(/\s+/)[0] || 'tudo bem'

/** O que o cliente precisa informar. Rua, bairro, cidade, UF e código IBGE saem do CEP (contato-cep-completar). */
export const CAMPOS_NF = [
  'Nome completo ou razão social',
  'CPF ou CNPJ',
  'CEP',
  'Número (e complemento, se tiver)',
  'E-mail',
] as const

/** Mensagem curta pedindo os dados da nota fiscal, numa lista fácil de responder. */
export function mensagemNotaFiscal(nome: string | null | undefined): string {
  const lista = CAMPOS_NF.map((c, i) => `${i + 1}. ${c}`).join('\n')
  return `Oi, ${primeiroNome(nome)}! Pra emitir sua nota fiscal, me manda por aqui:\n\n${lista}\n\nPode mandar tudo numa mensagem só.`
}

export const NF_FALTA_LABEL: Record<string, string> = {
  nome: 'nome completo',
  documento: 'CPF/CNPJ',
  email: 'e-mail',
  cep: 'CEP',
  numero: 'número',
  endereco: 'endereço (completar pelo CEP)',
}

/** Texto do marcador: "NF: faltam CPF/CNPJ, e-mail". Vazio quando nada falta. */
export function resumoNfFaltando(chaves: string[] | null | undefined): string {
  const l = (chaves ?? []).map((c) => NF_FALTA_LABEL[c] ?? c)
  return l.length ? `Faltam dados da NF: ${l.join(', ')}` : ''
}
