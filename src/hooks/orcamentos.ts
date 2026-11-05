import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { invokeFunction } from '@/lib/api'
import type { Orcamento } from '@/lib/orcamentos'
import { supabase } from '@/lib/supabase'

const COLUNAS =
  'id, numero, order_id, contact_id, conversation_id, origem_id, status, subtotal, arte_modo, arte_valor, frete_modo, desconto_valor, total, validade_ate, regra_preco, confianca_preco, margem_liquida_pct, lucro_liquido, pdf_path, pdf_gerado_em, pdf_enviado_em, link_pagamento, teste, criado_em, motivo_perda, motivo_perda_em, motivo_perda_obs'

/** Orçamentos perdidos (sem teste) com o nome do contato, para a coluna Perdidos do Kanban. */
export interface OrcamentoPerdido extends Orcamento {
  contact: { name: string | null; phone: string | null } | null
}

export function useOrcamentosPerdidos() {
  return useQuery({
    queryKey: ['orcamentos-perdidos'],
    queryFn: async (): Promise<OrcamentoPerdido[]> => {
      const { data, error } = await supabase
        .from('orcamentos')
        .select(`${COLUNAS}, contact:contacts(name, phone)`)
        .eq('status', 'perdido')
        .eq('teste', false)
        .order('motivo_perda_em', { ascending: false })
        .limit(200)
      if (error) throw error
      return data as unknown as OrcamentoPerdido[]
    },
  })
}

const MENSAGEM_PERDA: Record<string, string> = {
  motivo_invalido: 'Escolha um motivo da lista.',
  obs_obrigatoria: 'Quando o motivo é Outro, escreva a observação.',
  orcamento_pago: 'Orçamento pago não pode ser marcado como perdido.',
  nao_encontrado: 'Orçamento não encontrado.',
}

export function useRegistrarPerda() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (v: { orcamentoId: string; motivo: string; obs: string | null }) => {
      const { data, error } = await supabase.rpc('orcamento_registrar_perda', { p_orcamento: v.orcamentoId, p_motivo: v.motivo, p_obs: v.obs })
      if (error) throw new Error(error.message)
      const r = data as { ok: boolean; motivo?: string }
      if (!r.ok) throw new Error(MENSAGEM_PERDA[r.motivo ?? ''] ?? 'Não foi possível marcar como perdido.')
      return r
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['orcamentos'] })
      qc.invalidateQueries({ queryKey: ['orcamentos-perdidos'] })
    },
  })
}

/** Orçamentos do pedido, mais os do mesmo contato que ainda não têm pedido ligado (o pedido nasce quando o link é gerado). */
export function useOrcamentosDoPedido(orderId: string, contactId: string) {
  return useQuery({
    queryKey: ['orcamentos', orderId],
    enabled: !!orderId,
    queryFn: async (): Promise<Orcamento[]> => {
      const { data, error } = await supabase
        .from('orcamentos')
        .select(COLUNAS)
        .or(`order_id.eq.${orderId},and(order_id.is.null,contact_id.eq.${contactId})`)
        .order('criado_em', { ascending: false })
        .limit(30)
      if (error) throw error
      return data as Orcamento[]
    },
  })
}

interface Reenvio {
  ok: boolean
  numero: string
  renovado: boolean
  enviado: boolean
  pdf_url?: string
  ja_enviado?: boolean
}

/** Gera o PDF de novo se algo mudou (ou reaproveita) e envia como documento no WhatsApp. Orçamento vencido vira um novo, recalculado. */
export function useReenviarOrcamento() {
  const qc = useQueryClient()
  return useMutation({
    /** texto: a legenda exata que o cliente vai ler (a mesma mostrada na confirmação) */
    mutationFn: (v: { orcamentoId: string; texto: string }) =>
      invokeFunction<Reenvio>('orcamento-pdf', { orcamento_id: v.orcamentoId, acao: 'reenviar', texto: v.texto }),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['orcamentos'] })
      qc.invalidateQueries({ queryKey: ['orders'] })
    },
  })
}

/** Gera (ou reaproveita) o PDF para conferir antes do envio. Não envia nada ao cliente. */
export function usePreverOrcamento() {
  return useMutation({
    mutationFn: (orcamentoId: string) => invokeFunction<Reenvio>('orcamento-pdf', { orcamento_id: orcamentoId, acao: 'gerar' }),
  })
}

/** Só gera (ou reaproveita) o PDF e guarda no pedido, sem enviar nada ao cliente. */
export function useGerarPdfOrcamento() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (orcamentoId: string) => invokeFunction<Reenvio>('orcamento-pdf', { orcamento_id: orcamentoId, acao: 'gerar' }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['orcamentos'] }),
  })
}

/** Link assinado de 5 minutos para abrir o PDF (o arquivo fica em bucket privado). */
export async function abrirPdfOrcamento(path: string): Promise<void> {
  const { data, error } = await supabase.storage.from('orcamentos').createSignedUrl(path, 300)
  if (error || !data?.signedUrl) throw new Error('Não foi possível abrir o PDF.')
  window.open(data.signedUrl, '_blank', 'noopener')
}
