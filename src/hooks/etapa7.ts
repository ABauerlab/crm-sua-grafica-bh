import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'

/** Chama uma função do banco e transforma `{ ok: false, mensagem }` em erro com texto claro. */
async function rpc<T = Record<string, unknown>>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args)
  if (error) throw new Error(error.message)
  const r = data as { ok?: boolean; mensagem?: string; motivo?: string } | null
  if (r && r.ok === false) throw new Error(r.mensagem ?? r.motivo ?? 'Não foi possível concluir.')
  return data as T
}

// ---------------------------------------------------------------- avisos de status do pedido
export type AvisoTipo = 'pronto_retirada' | 'saiu_entrega'
export interface PedidoAviso {
  id: string
  order_id: string
  tipo: AvisoTipo
  status: 'pendente' | 'reservado' | 'enviado' | 'falhou' | 'pulado'
  via: 'livre' | 'template' | 'simulado' | null
  erro: string | null
  enviado_em: string | null
  criado_em: string
}

export function usePedidoAvisos() {
  return useQuery({
    queryKey: ['pedido_avisos'],
    queryFn: async (): Promise<Map<string, PedidoAviso[]>> => {
      const { data, error } = await supabase.from('pedido_avisos').select('id,order_id,tipo,status,via,erro,enviado_em,criado_em').order('criado_em', { ascending: false }).limit(2000)
      if (error) throw error
      const m = new Map<string, PedidoAviso[]>()
      for (const a of data as PedidoAviso[]) m.set(a.order_id, [...(m.get(a.order_id) ?? []), a])
      return m
    },
  })
}

export const AVISO_LABEL: Record<AvisoTipo, string> = { pronto_retirada: 'Aviso de pronto', saiu_entrega: 'Aviso de saída' }
export const AVISO_STATUS: Record<PedidoAviso['status'], { label: string; chip: string }> = {
  pendente: { label: 'na fila', chip: 'bg-secondary text-foreground' },
  reservado: { label: 'enviando', chip: 'bg-secondary text-foreground' },
  enviado: { label: 'enviado ✓', chip: 'bg-brand-green/15 text-brand-green' },
  falhou: { label: 'falhou', chip: 'bg-brand-red/10 text-brand-red' },
  pulado: { label: 'não enviado', chip: 'bg-secondary text-muted-foreground' },
}

export function useDefinirSubestatus() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (v: { order_id: string; sub: 'em_producao' | AvisoTipo; rastreio?: string | null }) =>
      rpc('pedido_definir_subestatus', { p_order: v.order_id, p_sub: v.sub, p_rastreio: v.rastreio ?? null }),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['orders'] })
      qc.invalidateQueries({ queryKey: ['pedido_avisos'] })
    },
  })
}

export function useMarcarEntregue() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (order_id: string) => rpc('pedido_marcar_entregue', { p_order: order_id }),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['orders'] })
      qc.invalidateQueries({ queryKey: ['recompra'] })
    },
  })
}

// ---------------------------------------------------------------- lista do fornecedor
export interface FornecedorLista {
  itens: { sku: string; descricao: string; quantidade: number; pedidos: string[] }[]
  pedidos: { id: string; numero: string }[]
}
export function useFornecedorLista() {
  return useQuery({ queryKey: ['fornecedor_lista'], queryFn: () => rpc<FornecedorLista>('fornecedor_lista_pendente') })
}
export function useMarcarFabrica() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (ids: string[]) => rpc('fornecedor_marcar_enviado', { p_orders: ids }),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['fornecedor_lista'] })
      qc.invalidateQueries({ queryKey: ['orders'] })
    },
  })
}

// ---------------------------------------------------------------- recompra e follow-ups
export interface RecompraLinha {
  fila_id: string
  order_id: string
  regra: string
  produto: string | null
  status: string
  motivo: string | null
  quando: string
  enviado_em: string | null
  contato: string
  contact_id: string
  optout: boolean
  pedido: string
  entregue_em: string | null
  pode_disparar: boolean
}
export function useRecompraLista() {
  return useQuery({ queryKey: ['recompra'], queryFn: () => rpc<RecompraLinha[]>('recompra_lista') })
}
export function useDispararRecompra() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (fila_id: string) => rpc('recompra_disparar', { p_fila: fila_id }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['recompra'] }),
  })
}

export interface FollowupRegra {
  codigo: string
  descricao: string
  referencia: string
  atraso_minutos: number
  grupo_produto: string | null
  gatilho_condicao: 'G2' | 'G3' | null
  template_janela_fechada: string | null
  hora_min: number
  hora_max: number
  ativo: boolean
}
export function useFollowupRegras() {
  return useQuery({
    queryKey: ['followup_regras'],
    queryFn: async (): Promise<FollowupRegra[]> => {
      const { data, error } = await supabase.from('followup_regras').select('*').order('codigo')
      if (error) throw error
      return data as FollowupRegra[]
    },
  })
}
export function useSalvarRegra() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (r: Pick<FollowupRegra, 'codigo' | 'atraso_minutos' | 'hora_min' | 'hora_max' | 'ativo'>) => {
      const { error } = await supabase.from('followup_regras').update({ atraso_minutos: r.atraso_minutos, hora_min: r.hora_min, hora_max: r.hora_max, ativo: r.ativo }).eq('codigo', r.codigo)
      if (error) throw error
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['followup_regras'] }),
  })
}

export interface FollowupCfg { max_por_dia: number; exigir_optin_marketing: boolean; tentativas_max: number }
export interface ObservabilidadeCfg { teto_custo_dia_brl: number; custo_template_marketing_brl: number; custo_template_utilidade_brl: number }
export function useConfig<T>(key: 'followup' | 'observabilidade', padrao: T) {
  return useQuery({
    queryKey: ['setting', key],
    queryFn: async (): Promise<T> => {
      const { data, error } = await supabase.from('app_settings').select('value').eq('key', key).maybeSingle()
      if (error) throw error
      return { ...padrao, ...((data?.value as object) ?? {}) } as T
    },
  })
}
export function useSalvarConfig() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (v: { key: 'followup' | 'observabilidade'; value: Record<string, unknown> }) => {
      const { data: atual } = await supabase.from('app_settings').select('value').eq('key', v.key).maybeSingle()
      const { error } = await supabase.from('app_settings').upsert({ key: v.key, value: { ...((atual?.value as object) ?? {}), ...v.value } })
      if (error) throw error
    },
    onSuccess: (_d, v) => qc.invalidateQueries({ queryKey: ['setting', v.key] }),
  })
}

export interface FilaLinha {
  id: string
  regra_codigo: string
  status: string
  motivo: string | null
  agendado_para: string
  enviado_em: string | null
  via: string | null
  contact: { name: string | null; wa_id: string } | null
}
export function useFollowupFila(limit = 40) {
  return useQuery({
    queryKey: ['followup_fila', limit],
    refetchInterval: 60_000,
    queryFn: async (): Promise<FilaLinha[]> => {
      const { data, error } = await supabase
        .from('followup_fila')
        .select('id,regra_codigo,status,motivo,agendado_para,enviado_em,via,contact:contacts(name,wa_id)')
        .order('agendado_para', { ascending: false })
        .limit(limit)
      if (error) throw error
      return data as unknown as FilaLinha[]
    },
  })
}

// ---------------------------------------------------------------- painel do agente
export interface PainelAgente {
  ia_ligada: boolean
  conversas_ia: number
  orcamentos_enviados: number
  funil: { conversas: number; orcamentos: number; com_link: number; pagos: number }
  pedidos_pagos_do_agente: number
  tokens_por_conversa: number
  custo_por_conversa: number
  custo_dia: number
  teto_custo_dia: number
  custo_templates_mes: number
  templates_enviados_mes: number
  tempo_resposta_seg: number
  chamadas_ao_dono: number
  erros_recentes: { quando: string; workflow: string | null; mensagem: string | null }[]
  erros_agente: number
  condicoes: { concedidas: number; convertidas: number; enviadas: number; desconto_medio_sobre_lucro_pct: number }
  margem_liquida_real_pct: number
  followups: Record<string, number>
  leads_frios: number
}
export function usePainelAgente(dias: number) {
  return useQuery({
    queryKey: ['painel_agente', dias],
    refetchInterval: 120_000,
    queryFn: () => {
      const ate = new Date()
      const de = new Date(ate.getTime() - dias * 86_400_000)
      return rpc<PainelAgente>('painel_agente', { p_de: de.toISOString(), p_ate: ate.toISOString() })
    },
  })
}
