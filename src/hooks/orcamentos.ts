import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { invokeFunction } from '@/lib/api'
import type { Orcamento } from '@/lib/orcamentos'
import { supabase } from '@/lib/supabase'

const COLUNAS =
  'id, numero, order_id, contact_id, conversation_id, origem_id, status, subtotal, arte_modo, arte_valor, frete_modo, desconto_valor, total, validade_ate, regra_preco, confianca_preco, margem_liquida_pct, lucro_liquido, pdf_path, pdf_gerado_em, pdf_enviado_em, link_pagamento, teste, criado_em'

/** Orçamentos do pedido, mais os do mesmo contato que ainda não têm pedido ligado (o pedido nasce quando o link é gerado). */
export function useOrcamentosDoPedido(orderId: string, contactId: string) {
  return useQuery({
    queryKey: ['orcamentos', orderId],
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
}

/** Gera o PDF de novo se algo mudou (ou reaproveita) e envia como documento no WhatsApp. Orçamento vencido vira um novo, recalculado. */
export function useReenviarOrcamento() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (orcamentoId: string) => invokeFunction<Reenvio>('orcamento-pdf', { orcamento_id: orcamentoId, acao: 'reenviar' }),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['orcamentos'] })
      qc.invalidateQueries({ queryKey: ['orders'] })
    },
  })
}

/** Link assinado de 5 minutos para abrir o PDF (o arquivo fica em bucket privado). */
export async function abrirPdfOrcamento(path: string): Promise<void> {
  const { data, error } = await supabase.storage.from('orcamentos').createSignedUrl(path, 300)
  if (error || !data?.signedUrl) throw new Error('Não foi possível abrir o PDF.')
  window.open(data.signedUrl, '_blank', 'noopener')
}
