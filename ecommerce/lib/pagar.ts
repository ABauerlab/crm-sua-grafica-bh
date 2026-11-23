// Checkout próprio (/pagar/<token>): tipos e chamadas. Tudo passa pelas rotas /api/v1/pagar (a chave secreta nunca vem ao navegador).
export interface ItemPedido { id: string | null; descricao: string; quantidade: number; unitario: number; subtotal: number; extra: boolean; tipo: 'arte' | 'produto' | 'frete'; unidades?: number }
export interface OpcaoArte { codigo: 'pronta' | 'conferencia' | 'criacao'; titulo: string; texto: string; valor: number }
export interface Sugestao { ref: string; slug: string | null; titulo: string; quantidade: number | null; preco: number; parcela_2x: number; prazo_dias_uteis: number | null; foto: string | null; motivo: string; selo: string }
export interface OpcaoQuantidade { ref: string; quantidade: number; preco: number; unitario: number; atual: boolean }
export interface Quantidade { item_id: string; descricao: string; opcoes: OpcaoQuantidade[] }
export interface Checkout {
  ok: true
  estado: 'aberto' | 'em_analise' | 'pago' | 'expirado' | 'cancelado'
  pedido: { numero: string; criado_em: string; teste: boolean }
  itens: ItemPedido[]
  subtotal: number; desconto_valor: number; desconto_pct: number; total: number
  entrega: { texto: string; frete_gratis: boolean }
  prazo: { data_prevista: string | null; texto: string }
  validade_ate: string | null
  cliente: { nome: string | null; email: string | null; documento_final: string | null; tem_documento: boolean; whatsapp_final: string }
  faltando: ('nome' | 'email' | 'documento')[]
  pagamento: { pix: number; max_parcelas: number; parcelas_sem_juros: number; parcelas: { n: number; valor: number }[]; metodo_pago: string | null; parcelas_pagas: number | null }
  arte: { atual: OpcaoArte['codigo']; inclusa: boolean; opcoes: OpcaoArte[] }
  sugestoes: Sugestao[]
  quantidades: Quantidade[]
  campanha?: { ativa: boolean; titulo?: string; ate?: string; dias_restantes?: number; texto?: string }
  cupom?: { codigo: string; percentual: number } | null
  frete?: { valor: number; descricao: string | null; cep_final: string; aplicativo?: boolean }
  whatsapp: string
  mp: { chave_publica: string | null; modo: 'teste' | 'producao' | null }
}
export interface Resposta { ok?: boolean; erro?: string; mensagem?: string; [k: string]: unknown }

export async function chamar<T = Resposta>(fn: 'dados' | 'processar', corpo: Record<string, unknown>): Promise<{ status: number; dados: T }> {
  try {
    const res = await fetch(`/api/v1/pagar/${fn}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(corpo), cache: 'no-store' })
    return { status: res.status, dados: (await res.json().catch(() => ({ mensagem: 'Resposta inválida do servidor.' }))) as T }
  } catch {
    return { status: 0, dados: { ok: false, mensagem: 'Sem conexão. Confira a internet e tente de novo.' } as T }
  }
}

export const apenasDigitos = (v: string) => v.replace(/\D/g, '')

export function mascaraDocumento(v: string): string {
  const d = apenasDigitos(v).slice(0, 14)
  if (d.length <= 11) return d.replace(/(\d{3})(\d)/, '$1.$2').replace(/(\d{3})(\d)/, '$1.$2').replace(/(\d{3})(\d{1,2})$/, '$1-$2')
  return d.replace(/(\d{2})(\d)/, '$1.$2').replace(/(\d{3})(\d)/, '$1.$2').replace(/(\d{3})(\d)/, '$1/$2').replace(/(\d{4})(\d{1,2})$/, '$1-$2')
}

/** Mesma regra do servidor (CPF e CNPJ com dígito verificador). */
export function documentoValido(valor: string): boolean {
  const d = apenasDigitos(valor)
  if (/^(\d)\1+$/.test(d)) return false
  if (d.length === 11) {
    const dv = (n: number) => { let s = 0; for (let i = 0; i < n; i++) s += Number(d[i]) * (n + 1 - i); const r = (s * 10) % 11; return r === 10 ? 0 : r }
    return dv(9) === Number(d[9]) && dv(10) === Number(d[10])
  }
  if (d.length === 14) {
    const dv = (n: number) => {
      const pesos = n === 12 ? [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2] : [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]
      const r = pesos.reduce((a, p, i) => a + p * Number(d[i]), 0) % 11
      return r < 2 ? 0 : 11 - r
    }
    return dv(12) === Number(d[12]) && dv(13) === Number(d[13])
  }
  return false
}

export const emailValido = (v: string) => /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(v.trim())

export const dataCurta = (iso: string | null) => (iso ? new Date(iso.length === 10 ? iso + 'T12:00:00' : iso).toLocaleDateString('pt-BR', { day: '2-digit', month: 'long', weekday: 'long', timeZone: 'America/Sao_Paulo' }) : null)
export const dataHora = (iso: string | null) => (iso ? new Date(iso).toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit', timeZone: 'America/Sao_Paulo' }) : null)

/** Unidades reais do item, como no orçamento do WhatsApp. O banco manda `unidades` (5 crachás = 5, mesmo que o pedido guarde 1 pacote);
 *  sem isso, usa "· 5 un." da descrição. O subtotal nunca muda: só a forma de mostrar (5 un. x valor unitário), nunca "1 un." num lote de 5. */
export function unidadesDoItem(i: { descricao: string; quantidade: number; subtotal: number; unidades?: number }): { unidades: number; unitario: number } {
  const m = i.descricao.match(/·\s*([\d.]+)\s*un\./i)
  const n = m ? Number(m[1].replace(/\./g, '')) : 0
  const unidades = i.unidades && i.unidades > 0 ? i.unidades : i.quantidade > 1 ? i.quantidade : n > 1 ? n : i.quantidade
  return { unidades, unitario: unidades > 0 ? i.subtotal / unidades : i.subtotal }
}

export interface ProdutoBusca { produto_slug: string; titulo: string; foto: string | null; a_partir_de: number; opcoes: { ref: string; quantidade: number; preco: number; parcela_2x: number }[] }
export interface OpcaoFrete { servico: string; nome: string; valor: number; prazo_dias: number | null; a_combinar?: boolean }
export interface CotacaoFrete {
  ok: boolean; erro?: string; mensagem?: string
  endereco?: { logradouro: string | null; bairro: string | null; cidade: string | null; uf: string | null }
  frete_gratis?: boolean; grande_bh?: boolean
  envio?: { disponivel: boolean; motivo: string | null; opcoes: OpcaoFrete[] }
}
