import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { invokeFunction } from '@/lib/api'
import { supabase } from '@/lib/supabase'

export type CobrancaStatus = 'pendente' | 'em_analise' | 'aprovado' | 'recusado' | 'cancelado' | 'expirado' | 'estornado' | 'contestado' | 'invalidado'

export interface Cobranca {
  id: string
  order_id: string
  eh_link: boolean
  link_ativo: boolean
  mp_preference_id: string | null
  mp_payment_id: string | null
  link: string | null
  valor: number
  status: CobrancaStatus
  status_detalhe: string | null
  metodo: string | null
  modo: 'teste' | 'producao' | 'manual'
  divergencia: string | null
  expira_em: string | null
  aprovado_em: string | null
  criado_em: string
  order: { id: string; number: number; title: string; teste: boolean; contact: { name: string | null; wa_id: string } | null } | null
}

export interface AlertaPagamento {
  id: string
  tipo: string
  order_id: string | null
  mp_payment_id: string | null
  mensagem: string
  criado_em: string
  resolvido_em: string | null
  order: { number: number } | null
}

export interface MpStatus {
  modo: 'teste' | 'producao' | null
  pronto: boolean
  faltando: string[]
  webhook_url: string
}

export interface LinkCriado {
  link: string
  pagamento_id: string
  valor: number
  expira_em: string | null
  modo: 'teste' | 'producao'
  referencia: string
  reutilizado: boolean
}

export const STATUS_LABEL: Record<CobrancaStatus, string> = {
  pendente: 'Aguardando',
  em_analise: 'Em análise',
  aprovado: 'Aprovado',
  recusado: 'Recusado',
  cancelado: 'Cancelado',
  expirado: 'Expirado',
  estornado: 'Estornado',
  contestado: 'Contestado',
  invalidado: 'Link substituído',
}

export const ALERTA_LABEL: Record<string, string> = {
  valor_divergente: 'Valor diferente',
  moeda_divergente: 'Moeda diferente',
  referencia_desconhecida: 'Referência desconhecida',
  pagamento_recusado: 'Pagamento recusado',
  estorno: 'Estorno',
  contestacao: 'Contestação',
  reclamacao: 'Reclamação',
  pagamento_duplicado: 'Pagamento duplicado',
  teste_em_pedido_real: 'Teste em pedido real',
  producao_em_pedido_teste: 'Pagamento real em pedido de teste',
  modo_divergente: 'Modo teste/produção',
}

export function useCobrancas() {
  return useQuery({
    queryKey: ['pagamentos'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('pagamentos')
        .select('*, order:orders(id,number,title,teste,contact:contacts(name,wa_id))')
        .order('criado_em', { ascending: false })
        .limit(500)
      if (error) throw error
      return data as unknown as Cobranca[]
    },
  })
}

export function useAlertas() {
  return useQuery({
    queryKey: ['pagamentos-alertas'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('pagamentos_alertas')
        .select('*, order:orders(number)')
        .order('criado_em', { ascending: false })
        .limit(200)
      if (error) throw error
      return data as unknown as AlertaPagamento[]
    },
  })
}

export function useMpStatus() {
  return useQuery({
    queryKey: ['mp-status'],
    staleTime: 60_000,
    retry: false,
    queryFn: () => invokeFunction<MpStatus>('mp-criar-link', { acao: 'status' }),
  })
}

export function useResolveAlerta() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async ({ id, resolvido }: { id: string; resolvido: boolean }) => {
      const { error } = await supabase.from('pagamentos_alertas').update({ resolvido_em: resolvido ? new Date().toISOString() : null }).eq('id', id)
      if (error) throw new Error(error.message)
    },
    onSettled: () => qc.invalidateQueries({ queryKey: ['pagamentos-alertas'] }),
  })
}

export function useCriarLink() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (v: { pedidoId: string; novo?: boolean; horas?: number }) =>
      invokeFunction<LinkCriado>('mp-criar-link', { pedido_id: v.pedidoId, forcar_novo: v.novo === true, ...(v.horas ? { expira_horas: v.horas } : {}) }),
    onSettled: () => {
      qc.invalidateQueries({ queryKey: ['pagamentos'] })
      qc.invalidateQueries({ queryKey: ['orders'] })
    },
  })
}

/** Botão "Marcar como pago": passa pela mesma função do webhook do Mercado Pago. */
export function useConfirmarManual() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (orderId: string) => {
      const { error } = await supabase.rpc('confirmar_pagamento_manual', { p_order: orderId })
      if (error) throw new Error(error.message)
    },
    onSettled: () => {
      qc.invalidateQueries({ queryKey: ['pagamentos'] })
      qc.invalidateQueries({ queryKey: ['orders'] })
    },
  })
}
