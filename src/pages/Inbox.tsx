import { MessageSquare } from 'lucide-react'
import { useState } from "react"
import { useParams } from 'react-router-dom'
import { ChatPanel } from '@/features/inbox/ChatPanel'
import { ContactPanel } from '@/features/inbox/ContactPanel'
import { ConversationList } from '@/features/inbox/ConversationList'
import { useConversations } from '@/hooks/queries'
import { formatPhone } from '@/lib/format'
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
        <>
          {/* Celular e tablet: gaveta inferior (bottom sheet) com rolagem por toque. Sem precisar de zoom. */}
          {details && (
            <div className="fixed inset-0 z-30 xl:hidden" role="dialog" aria-modal="true" aria-label="Detalhes do cliente">
              <button className="absolute inset-0 bg-ink/50" aria-label="Fechar detalhes" onClick={() => setDetailsFor(undefined)} />
              <div className="absolute inset-x-0 bottom-0 flex max-h-[88dvh] flex-col rounded-t-2xl bg-card shadow-2xl">
                <div className="flex shrink-0 flex-col items-center border-b px-4 pb-2 pt-2">
                  <span className="h-1.5 w-12 rounded-full bg-border" aria-hidden />
                  <div className="mt-2 flex w-full items-center gap-3">
                    <span className="flex h-12 w-12 shrink-0 items-center justify-center rounded-full bg-brand-cyan/20 text-lg font-black" aria-hidden>
                      {(conversation.contact.name ?? '#').trim().charAt(0).toUpperCase()}
                    </span>
                    <div className="min-w-0 flex-1">
                      <p className="truncate font-black">{conversation.contact.name || formatPhone(conversation.contact.wa_id)}</p>
                      <p className="text-xs text-muted-foreground">{formatPhone(conversation.contact.wa_id)}</p>
                    </div>
                    <button className="flex h-11 min-w-11 items-center justify-center rounded-md px-3 text-sm font-semibold hover:bg-secondary" onClick={() => setDetailsFor(undefined)}>Fechar</button>
                  </div>
                </div>
                <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain [-webkit-overflow-scrolling:touch]">
                  <ContactPanel key={conversation.id} conversation={conversation} />
                </div>
              </div>
            </div>
          )}
          <aside className="hidden w-72 shrink-0 border-l bg-card xl:block">
            <ContactPanel key={conversation.id} conversation={conversation} />
          </aside>
        </>
      )}
    </div>
  )
}
