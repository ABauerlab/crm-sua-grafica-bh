// Validação do pedido do site (checkout). Funções puras: usadas pela Edge Function loja-checkout e testadas em Node.

export type Arte = 'pronta' | 'conferencia' | 'criacao'
export interface PedidoSite {
  cliente: { whatsapp: string; nome: string; email: string | null; documento: string | null }
  itens: { ref: string; quantidade: number }[]
  opcoes: { arte: Arte; entrega: 'retirada' | 'entrega'; cep: string | null }
}

const digitos = (s: unknown) => String(s ?? '').replace(/\D/g, '')

/** (31) 97561-8243 -> 5531975618243. Aceita com ou sem 55; exige DDD válido e 8 ou 9 dígitos. */
export function normalizarWhatsapp(v: unknown): string | null {
  let d = digitos(v)
  if (d.length === 10 || d.length === 11) d = `55${d}`
  return /^55[1-9][0-9]9?[0-9]{8}$/.test(d) ? d : null
}

export function cpfValido(v: string): boolean {
  const d = digitos(v)
  if (d.length !== 11 || /^(\d)\1+$/.test(d)) return false
  const dv = (n: number) => { let s = 0; for (let i = 0; i < n; i++) s += Number(d[i]) * (n + 1 - i); const r = (s * 10) % 11; return r === 10 ? 0 : r }
  return dv(9) === Number(d[9]) && dv(10) === Number(d[10])
}

export function cnpjValido(v: string): boolean {
  const d = digitos(v)
  if (d.length !== 14 || /^(\d)\1+$/.test(d)) return false
  const calc = (n: number) => {
    const pesos = n === 12 ? [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2] : [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]
    const s = pesos.reduce((acc, p, i) => acc + Number(d[i]) * p, 0)
    const r = s % 11
    return r < 2 ? 0 : 11 - r
  }
  return calc(12) === Number(d[12]) && calc(13) === Number(d[13])
}

const REF = /^[0-9a-f]{12}$/

/** Confere o corpo do checkout. Devolve o pedido limpo ou a lista de erros (mensagens prontas para a tela). */
export function validarPedido(body: unknown): { ok: true; pedido: PedidoSite } | { ok: false; erros: string[] } {
  const b = (body ?? {}) as Record<string, any>
  const erros: string[] = []
  const c = (b.cliente ?? {}) as Record<string, unknown>
  const whatsapp = normalizarWhatsapp(c.whatsapp)
  if (!whatsapp) erros.push('Informe um WhatsApp válido com DDD.')
  const nome = String(c.nome ?? '').trim().replace(/\s+/g, ' ')
  if (nome.length < 3 || nome.length > 120) erros.push('Informe o nome completo.')
  const email = String(c.email ?? '').trim().toLowerCase() || null
  if (email && !/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email)) erros.push('E-mail inválido.')
  const doc = digitos(c.documento) || null
  if (doc && !(doc.length === 11 ? cpfValido(doc) : doc.length === 14 ? cnpjValido(doc) : false)) erros.push('CPF ou CNPJ inválido.')
  const itensIn = Array.isArray(b.itens) ? b.itens : []
  if (itensIn.length < 1 || itensIn.length > 10) erros.push('O carrinho precisa ter de 1 a 10 itens.')
  const itens = itensIn.map((i: Record<string, unknown>) => ({ ref: String(i?.ref ?? '').trim(), quantidade: Math.trunc(Number(i?.quantidade ?? 1)) }))
  if (itens.some((i) => !REF.test(i.ref))) erros.push('Produto inválido no carrinho.')
  if (itens.some((i) => !Number.isFinite(i.quantidade) || i.quantidade < 1 || i.quantidade > 100)) erros.push('Quantidade inválida no carrinho.')
  const o = (b.opcoes ?? {}) as Record<string, unknown>
  const arte = String(o.arte ?? 'pronta') as Arte
  if (!['pronta', 'conferencia', 'criacao'].includes(arte)) erros.push('Escolha uma opção de arte.')
  const entrega = String(o.entrega ?? 'retirada') as 'retirada' | 'entrega'
  if (!['retirada', 'entrega'].includes(entrega)) erros.push('Escolha retirada ou entrega.')
  const cep = digitos(o.cep) || null
  if (cep && cep.length !== 8) erros.push('CEP inválido.')
  if (entrega === 'entrega' && !cep) erros.push('Informe o CEP para a entrega.')
  if (erros.length) return { ok: false, erros }
  return { ok: true, pedido: { cliente: { whatsapp: whatsapp!, nome, email, documento: doc }, itens, opcoes: { arte, entrega, cep } } }
}

/** Códigos do banco -> mensagem para o cliente (sem detalhe interno). */
export function mensagemErro(codigo: string | undefined): { status: number; mensagem: string } {
  switch (codigo) {
    case 'muitas_tentativas': return { status: 429, mensagem: 'Muitas tentativas seguidas. Aguarde alguns minutos ou fale com a gente no WhatsApp.' }
    case 'produto_nao_encontrado': case 'produto_indisponivel': return { status: 409, mensagem: 'Um dos produtos do carrinho não está mais disponível. Atualize o carrinho.' }
    case 'orcamento_bloqueado': return { status: 422, mensagem: 'Não conseguimos fechar este pedido pelo site. Fale com a gente no WhatsApp que resolvemos na hora.' }
    case 'whatsapp_invalido': return { status: 400, mensagem: 'Informe um WhatsApp válido com DDD.' }
    case 'cep_obrigatorio_para_entrega': return { status: 400, mensagem: 'Informe o CEP para a entrega.' }
    default: return { status: 400, mensagem: 'Não foi possível criar o pedido. Confira os dados e tente de novo.' }
  }
}
