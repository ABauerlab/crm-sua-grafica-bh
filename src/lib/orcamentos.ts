export type OrcamentoStatus = 'rascunho' | 'enviado' | 'aceito' | 'pago' | 'expirado' | 'perdido' | 'cancelado'

export interface Orcamento {
  id: string
  numero: number
  order_id: string | null
  contact_id: string
  conversation_id: string | null
  origem_id: string | null
  status: OrcamentoStatus
  subtotal: number
  arte_modo: 'nenhuma' | 'cliente' | 'paga' | 'com_frete'
  arte_valor: number
  frete_modo: 'retirada' | 'bike_gratis' | 'uber_cliente'
  desconto_valor: number
  total: number
  validade_ate: string | null
  regra_preco: string | null
  confianca_preco: 'alta' | 'media' | 'baixa' | null
  margem_liquida_pct: number | null
  lucro_liquido: number | null
  pdf_path: string | null
  pdf_gerado_em: string | null
  pdf_enviado_em: string | null
  link_pagamento: string | null
  teste: boolean
  criado_em: string
}

export const ORCAMENTO_STATUS: Record<OrcamentoStatus, { label: string; chip: string }> = {
  rascunho: { label: 'Rascunho', chip: 'bg-ink/10 text-ink' },
  enviado: { label: 'Enviado', chip: 'bg-brand-cyan/15 text-ink' },
  aceito: { label: 'Aceito', chip: 'bg-brand-yellow/30 text-ink' },
  pago: { label: 'Pago', chip: 'bg-brand-green/10 text-brand-green' },
  expirado: { label: 'Vencido', chip: 'bg-brand-red/10 text-brand-red' },
  perdido: { label: 'Perdido', chip: 'bg-brand-red/10 text-brand-red' },
  cancelado: { label: 'Cancelado', chip: 'bg-ink/10 text-ink' },
}

export const orcamentoNumero = (n: number) => `SG-${String(n).padStart(4, '0')}`

export const REGRA_PRECO: Record<string, string> = {
  mercado: 'Pesquisa de mercado',
  mercado_com_ancora_vendas: 'Mercado + vendas anteriores',
  historico_vendas: 'Vendas anteriores',
  custo_x_multiplicador: 'Custo x multiplicador (sem mercado)',
  piso: 'Piso de lucro',
}

export const CONFIANCA_PRECO: Record<string, string> = { alta: 'Alta', media: 'Média', baixa: 'Baixa' }

export const ARTE_LABEL: Record<Orcamento['arte_modo'], string> = { nenhuma: 'Arte a definir', cliente: 'Arte do cliente', paga: 'Criação de arte', com_frete: 'Arte com frete grátis' }
