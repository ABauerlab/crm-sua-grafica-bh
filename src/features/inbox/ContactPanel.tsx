import { useMutation, useQueryClient } from '@tanstack/react-query'
import { Plus } from 'lucide-react'
import { useNavigate } from 'react-router-dom'
import { useAuth } from '@/auth/AuthProvider'
import { ContactProfile } from '@/features/contacts/ContactProfile'
import { Button } from '@/components/ui/button'
import { useToast } from '@/components/ui/toast'
import { useCreateOrder } from '@/hooks/orders'
import { formatPhone } from '@/lib/format'
import { supabase } from '@/lib/supabase'
import type { ConversationWithContact } from '@/lib/types'

export function ContactPanel({ conversation }: { conversation: ConversationWithContact }) {
  const qc = useQueryClient()
  const navigate = useNavigate()
  const toast = useToast()
  const { profile } = useAuth()
  const create = useCreateOrder()
  const { contact } = conversation

  const deleteContact = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.from('contacts').delete().eq('id', contact.id)
      if (error) throw new Error(error.message)
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['conversations'] })
      qc.invalidateQueries({ queryKey: ['contacts'] })
      navigate('/inbox')
    },
    onError: (e: Error) => toast('error', e.message),
  })

  function onDelete() {
    const who = contact.name || formatPhone(contact.wa_id)
    if (window.confirm(`Excluir ${who} e todas as conversas dele? Isso não pode ser desfeito.`)) deleteContact.mutate()
  }

  return (
    <div className="h-full space-y-5 overflow-y-auto p-4">
      <Button
        className="w-full"
        disabled={create.isPending}
        onClick={() =>
          create.mutate(
            { contactId: contact.id, title: '' },
            { onSuccess: (id) => navigate(`/kanban?pedido=${id}`), onError: (e) => toast('error', e.message) },
          )
        }
      >
        <Plus className="h-4 w-4" /> Criar pedido
      </Button>

      <ContactProfile contact={contact} lastContactAt={conversation.last_message_at} />

      {profile?.role === 'admin' && (
        <section className="space-y-1.5 border-t pt-4">
          <p className="text-xs text-muted-foreground">
            Pedido de exclusão de dados (LGPD): apaga o contato, as conversas e as mensagens. Se ele tinha pedido para parar as promoções, só o telefone fica guardado para respeitar esse pedido.
          </p>
          <Button size="sm" variant="outline" className="text-destructive" onClick={onDelete} disabled={deleteContact.isPending}>
            {deleteContact.isPending ? 'Excluindo…' : 'Excluir contato e dados'}
          </Button>
        </section>
      )}
    </div>
  )
}
