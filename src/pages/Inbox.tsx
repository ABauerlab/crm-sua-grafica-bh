import { MessageSquare } from 'lucide-react'
import { useState } from "react"
import { useParams } from 'react-router-dom'
import { ChatPanel } from '@/features/inbox/ChatPanel'
import { ContactPanel } from '@/features/inbox/ContactPanel'
import { ConversationList } from '@/features/inbox/ConversationList'
import { useConversations } from '@/hooks/queries'
import { cn } from '@/lib/utils'

export default function Inbox() {
  const { conversationId } = useParams()
  const { data } = useConversations()
  const conversation = data?.find((c) => c.id === conversationId)
  const [detailsFor, setDetailsFor] = useState<string>()
  const details = detailsFor === conversationId

  return (
    <div className="flex h-full">
      <aside className={cn('w-full shrink-0 border-r bg-card md:block md:w-80', conversationId && 'hidden')}>
        <ConversationList />
      </aside>

      <section className={cn('min-w-0 flex-1', !conversationId && 'hidden md:block')}>
        {conversation ? (
          <ChatPanel key={conversation.id} conversation={conversation} onDetails={() => setDetailsFor(conversationId)} />
        ) : (
          <div className="flex h-full flex-col items-center justify-center gap-2 text-muted-foreground">
            <MessageSquare className="h-10 w-10" />
            <p className="text-sm">{conversationId ? 'Conversa não encontrada.' : 'Selecione uma conversa para começar.'}</p>
          </div>
        )}
      </section>

      {conversation && (
        <aside className={cn("w-72 shrink-0 border-l bg-card xl:block", details ? "fixed inset-0 z-20 w-full xl:static xl:z-auto xl:w-72" : "hidden")}>
          {details && (
            <button className="m-3 text-sm underline xl:hidden" onClick={() => setDetailsFor(undefined)}>
              Fechar detalhes
            </button>
          )}
          <ContactPanel key={conversation.id} conversation={conversation} />
        </aside>
      )}
    </div>
  )
}
