import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Check, MessageSquare, Palette } from 'lucide-react'
import { useState } from 'react'
import { Link } from 'react-router-dom'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { EmptyState } from '@/components/ui/empty-state'
import { Modal } from '@/components/ui/sheet'
import { Skeleton } from '@/components/ui/skeleton'
import { useToast } from '@/components/ui/toast'
import { invokeFunction } from '@/lib/api'
import { supabase } from '@/lib/supabase'
import { cn } from '@/lib/utils'

interface Linha {
  order_id: string
  numero: number
  pedido: string
  cliente: string
  itens: { produto: string; quantidade: number }[]
  prazo_prometido: string | null
  entrega: string | null
  qualidade: 'ok' | 'baixa' | 'indefinida' | 'briefing'
  baixa_ok: boolean
  urgente: boolean
  art_status: string
  stage: string
  na_fila_desde: string
  horas_na_fila: number
  conversation_id: string | null
  observacoes: string | null
}

const QUALIDADE: Record<Linha['qualidade'], { label: string; chip: string }> = {
  ok: { label: 'Arquivo bom', chip: 'bg-brand-green/10 text-brand-green' },
  baixa: { label: 'Baixa qualidade', chip: 'bg-brand-red/10 text-brand-red' },
  indefinida: { label: 'Qualidade a conferir', chip: 'bg-brand-yellow/30' },
  briefing: { label: 'Briefing (criar arte)', chip: 'bg-brand-cyan/20' },
}

function Aprovar({ l, onClose }: { l: Linha; onClose: () => void }) {
  const qc = useQueryClient()
  const toast = useToast()
  const [confirmou, setConfirmou] = useState(false)
  const [refeita, setRefeita] = useState(false)
  const m = useMutation({
    mutationFn: async () => {
      const { data, error } = await supabase.rpc('arte_aprovar', { p_order: l.order_id, p_cliente_confirmou: confirmou, p_arte_refeita: refeita })
      if (error) throw new Error(error.message)
      const r = data as { ok: boolean; orientacao?: string; aviso?: string; conversation_id?: string; mensagem_cliente?: string }
      if (!r.ok) throw new Error(r.orientacao ?? 'Não foi possível aprovar.')
      // avisa o cliente (texto livre na janela de 24 h; se a janela fechou o envio falha e o dono é avisado na tela)
      if (r.conversation_id && r.mensagem_cliente) {
        try { await invokeFunction('whatsapp-send', { conversation_id: r.conversation_id, text: r.mensagem_cliente }) } catch { r.aviso = `${r.aviso ?? 'Arte aprovada.'} Não consegui avisar o cliente (janela de 24 h fechada?). Mande uma mensagem pela conversa.` }
      }
      return r
    },
    onSuccess: (r) => {
      toast('ok', r.aviso ?? 'Arte aprovada. O prazo começou a contar e a automação voltou.')
      qc.invalidateQueries({ queryKey: ['arte-fila'] })
      qc.invalidateQueries({ queryKey: ['orders'] })
      onClose()
    },
    onError: (e: Error) => toast('error', e.message),
  })
  return (
    <Modal open onOpenChange={(o) => !o && onClose()} title={`Arte aprovada pelo cliente: ${l.pedido}`} description="Fica registrado com data e hora. O prazo passa a contar de agora e o pedido segue sozinho: produção, status, pronto, entrega e pós-venda.">
      <div className="space-y-3 p-4 pt-0">
        <label className="flex items-start gap-2 text-sm"><input type="checkbox" className="mt-1" checked={confirmou} onChange={(e) => setConfirmou(e.target.checked)} /> O cliente confirmou o texto, as cores e as imagens da arte.</label>
        {l.qualidade === 'baixa' && !l.baixa_ok && (
          <label className="flex items-start gap-2 text-sm"><input type="checkbox" className="mt-1" checked={refeita} onChange={(e) => setRefeita(e.target.checked)} /> O arquivo era de baixa qualidade e a arte foi refeita (sem isso, preciso do ok do cliente para seguir assim mesmo).</label>
        )}
        <div className="flex justify-end gap-2"><Button variant="outline" onClick={onClose}>Cancelar</Button><Button disabled={!confirmou || m.isPending} onClick={() => m.mutate()}><Check className="h-4 w-4" /> Marcar arte aprovada</Button></div>
      </div>
    </Modal>
  )
}

/** Fila da arte: pedidos pagos esperando a sua ação (criar, ajustar ou conferir a arte). Urgência no topo. */
export default function ArteQueue() {
  const [aprovar, setAprovar] = useState<Linha | null>(null)
  const { data, isLoading } = useQuery({
    queryKey: ['arte-fila'],
    refetchInterval: 60_000,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('arte_fila')
      if (error) throw error
      return (data ?? []) as Linha[]
    },
  })
  return (
    <div className="mx-auto max-w-4xl space-y-4 p-4">
      <header><h1 className="text-xl font-bold">Fila da arte</h1><p className="text-sm text-muted-foreground">Pedidos pagos com arquivo ou briefing recebido. O assistente aguarda você; ao marcar a arte aprovada, a automação continua.</p></header>
      {isLoading ? <Skeleton className="h-40 w-full" /> : !data?.length ? (
        <EmptyState icon={Palette} title="Nenhuma arte esperando você">Quando um cliente enviar a arte ou o briefing depois de pagar, o pedido aparece aqui e você recebe o alerta.</EmptyState>
      ) : (
        <ul className="space-y-3">
          {data.map((l) => (
            <li key={l.order_id} className={cn('space-y-2 rounded-md border p-3', l.urgente && 'border-brand-red')}>
              <div className="flex flex-wrap items-center gap-2">
                <span className="font-bold">{l.pedido}</span><span className="text-sm">{l.cliente}</span>
                {l.urgente && <Badge className="bg-brand-red text-white">URGENTE</Badge>}
                <Badge className={QUALIDADE[l.qualidade].chip}>{QUALIDADE[l.qualidade].label}{l.qualidade === 'baixa' && l.baixa_ok ? ' (cliente topou seguir)' : ''}</Badge>
                <span className="ml-auto text-xs text-muted-foreground tabular">na fila há {l.horas_na_fila < 1 ? 'menos de 1 h' : `${Math.floor(l.horas_na_fila)} h`}</span>
              </div>
              <p className="text-sm">{l.itens.map((i) => `${i.produto} x${i.quantidade}`).join(', ') || 'Itens do pedido'}</p>
              <p className="text-xs text-muted-foreground">Prazo prometido: {l.prazo_prometido ? new Date(`${l.prazo_prometido}T12:00:00`).toLocaleDateString('pt-BR') : 'a confirmar'} · {l.entrega === 'uber' ? 'Entrega por Uber' : l.entrega === 'retirada' ? 'Retirada' : 'Entrega a combinar'}{l.observacoes ? ` · ${l.observacoes}` : ''}</p>
              <div className="flex flex-wrap justify-end gap-2">
                {l.conversation_id && <Button asChild size="sm" variant="outline"><Link to={`/inbox/${l.conversation_id}`}><MessageSquare className="h-4 w-4" /> Abrir conversa</Link></Button>}
                <Button size="sm" onClick={() => setAprovar(l)}><Check className="h-4 w-4" /> Arte aprovada pelo cliente</Button>
              </div>
            </li>
          ))}
        </ul>
      )}
      {aprovar && <Aprovar l={aprovar} onClose={() => setAprovar(null)} />}
    </div>
  )
}
