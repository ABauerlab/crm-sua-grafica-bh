import { useEffect, useState } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { Button } from '@/components/ui/button'
import { Modal } from '@/components/ui/sheet'
import { Textarea } from '@/components/ui/textarea'
import { useToast } from '@/components/ui/toast'
import { invokeFunction } from '@/lib/api'
import { montarAviso } from '@/lib/aviso-operacional'
import type { OrderCard } from '@/lib/orders'

/** Pedido foi para "Pronto": sugere o aviso ao cliente (texto livre na janela de 24 h, senão o template aprovado). Um clique para enviar. */
export function AvisoCliente({ order, textoInicial, titulo, onClose }: { order: OrderCard | null; textoInicial: string; titulo: string; onClose: () => void }) {
  const toast = useToast()
  const qc = useQueryClient()
  const [texto, setTexto] = useState(textoInicial)
  useEffect(() => setTexto(textoInicial), [textoInicial, order?.id])
  const conv = order?.conversation ?? null
  const plano = montarAviso(conv, order?.contact.name, texto)
  const enviar = useMutation({
    mutationFn: () => invokeFunction('whatsapp-send', { conversation_id: order!.conversation_id, ...plano.body }),
    onSuccess: () => { toast('ok', 'Aviso enviado ao cliente.'); void qc.invalidateQueries({ queryKey: ['messages'] }); onClose() },
    onError: (e: Error) => toast('error', e.message),
  })
  return (
    <Modal open={!!order} onOpenChange={(o) => !o && onClose()} title={titulo}
      description={plano.aberta ? 'A janela de 24 h está aberta: vai como mensagem normal.' : 'A janela de 24 h está fechada: vai pelo template aprovado "aviso_operacional_pedido", que reabre a conversa.'}>
      <Textarea aria-label="Mensagem ao cliente" rows={5} value={texto} onChange={(e) => setTexto(e.target.value)} />
      {!plano.aberta && <p className="mt-2 text-xs text-muted-foreground">Chega assim: "Olá, {plano.body.variables?.[0]}! Aqui é da equipe de atendimento da Sua Gráfica BH sobre o seu pedido. {plano.body.variables?.[1]} Qualquer dúvida, é só nos responder por aqui!"</p>}
      <div className="mt-3 flex justify-end gap-2">
        <Button variant="outline" onClick={onClose}>Agora não</Button>
        <Button onClick={() => enviar.mutate()} disabled={!texto.trim() || !order?.conversation_id || enviar.isPending}>Enviar aviso</Button>
      </div>
    </Modal>
  )
}
