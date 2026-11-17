const primeiroNome = (nome: string | null | undefined) => nome?.trim().split(/\s+/)[0] || 'tudo bem'

/** Campos que o Bling exige para a nota. O código IBGE não vai ao cliente: sai do CEP (ViaCEP). */
export const CAMPOS_NF = [
  'Nome completo ou razão social',
  'CPF ou CNPJ',
  'CEP',
  'Rua ou avenida',
  'Número (e complemento, se tiver)',
  'Bairro',
  'Cidade e estado (ex: Belo Horizonte/MG)',
  'E-mail',
] as const

/** Mensagem curta pedindo os dados da nota fiscal, numa lista fácil de responder. */
export function mensagemNotaFiscal(nome: string | null | undefined): string {
  const lista = CAMPOS_NF.map((c, i) => `${i + 1}. ${c}`).join('\n')
  return `Oi, ${primeiroNome(nome)}! Pra emitir sua nota fiscal, me manda por aqui:\n\n${lista}\n\nPode mandar tudo numa mensagem só.`
}
