import { useMutation, useQueryClient } from '@tanstack/react-query'
import { ArrowLeft, Lock, Send } from 'lucide-react'
import { useEffect, useRef, useState, type KeyboardEvent } from 'react'
import { Link } from 'react-router-dom'
import { MessageStatusIcon } from '@/components/MessageStatusIcon'
import { Button } from '@/components/ui/button'
import { Textarea } from '@/components/ui/textarea'
import { useMessages } from '@/hooks/queries'
import { invokeFunction } from '@/lib/api'
import { contactLabel, formatDay, formatPhone, formatTime, windowOpen, windowRemaining } from '@/lib/format'
import { supabase } from '@/lib/supabase'
import type { ConversationWithContact } from '@/lib/types'
import { cn } from '@/lib/utils'
import { TemplatePicker } from './TemplatePicker'

export function ChatPanel({ conversation, onDetails }: { conversation: ConversationWithContact; onDetails?: () => void }) {
  const qc = useQueryClient()
  const { data: messages, isLoading } = useMessages(conversation.id)
  const [text, setText] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [now, setNow] = useState(() => Date.now())
  const [forceTemplate, setForceTemplate] = useState(false)
  const bottomRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 30_000)
    return () => clearInterval(id)
  }, [])

  // Abrir a conversa zera as não lidas
  useEffect(() => {
    if (conversation.unread_count > 0) {
      supabase
        .from('conversations')
        .update({ unread_count: 0 })
        .eq('id', conversation.id)
        .then(() => qc.invalidateQueries({ queryKey: ['conversations'] }))
    }
  }, [conversation.id, conversation.unread_count, qc])

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ block: 'end' })
  }, [messages?.length, conversation.id])

  const open = windowOpen(conversation.last_inbound_at, now)

  const send = useMutation({
    mutationFn: (body: Record<string, unknown>) => invokeFunction('whatsapp-send', { conversation_id: conversation.id, ...body }),
    onSuccess: () => {
      setError(null)
      qc.invalidateQueries({ queryKey: ['messages', conversation.id] })
      qc.invalidateQueries({ queryKey: ['conversations'] })
    },
    onError: (e: Error) => setError(e.message),
  })

  function submitText() {
    const t = text.trim()
    if (!t || send.isPending) return
    send.mutate({ text: t }, { onSuccess: () => setText('') })
  }

  function onKeyDown(e: KeyboardEvent<HTMLTextAreaElement>) {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault()
      submitText()
    }
  }

  let lastDay = ''

  return (
    <div className="flex h-full flex-col bg-muted/40">
      <header className="flex items-center gap-3 border-b bg-card px-4 py-3">
        <Link to="/inbox" className="md:hidden" aria-label="Voltar para a lista">
          <ArrowLeft className="h-5 w-5" />
        </Link>
        <div className="min-w-0">
          <p className="truncate text-sm font-semibold">{contactLabel(conversation.contact)}</p>
          <p className="text-xs text-muted-foreground">{formatPhone(conversation.contact.wa_id)}</p>
        </div>
        {onDetails && (
          <Button variant="outline" size="sm" className="ml-auto xl:hidden" onClick={onDetails}>
            Detalhes
          </Button>
        )}
      </header>

      <div className="min-h-0 flex-1 space-y-1 overflow-y-auto px-4 py-4">
        {isLoading && <p className="text-center text-sm text-muted-foreground">Carregando mensagens…</p>}
        {messages?.map((m) => {
          const day = formatDay(m.created_at)
          const showDay = day !== lastDay
          lastDay = day
          const out = m.direction === 'out'
          return (
            <div key={m.id}>
              {showDay && (
                <p className="my-3 text-center text-xs text-muted-foreground">
                  <span className="rounded-full bg-card px-3 py-1 shadow-sm">{day}</span>
                </p>
              )}
              <div className={cn('flex', out ? 'justify-end' : 'justify-start')}>
                <div
                  className={cn(
                    'max-w-[80%] rounded-lg px-3 py-2 text-sm shadow-sm',
                    out ? 'bg-emerald-100' : 'bg-card',
                    m.status === 'failed' && 'ring-1 ring-destructive',
                  )}
                >
                  {m.type === 'template' && <p className="mb-0.5 text-[11px] font-medium text-muted-foreground">Template: {m.template_name}</p>}
                  <p className={cn('whitespace-pre-wrap break-words', m.type !== 'text' && m.type !== 'template' && 'italic text-muted-foreground')}>
                    {m.body}
                  </p>
                  <div className="mt-1 flex items-center justify-end gap-1 text-[11px] text-muted-foreground">
                    {formatTime(m.created_at)}
                    {out && <MessageStatusIcon status={m.status} error={m.error} />}
                  </div>
                  {m.status === 'failed' && m.error && <p className="mt-1 text-[11px] text-destructive">Falha no envio: {m.error}</p>}
                </div>
              </div>
            </div>
          )
        })}
        <div ref={bottomRef} />
      </div>

      <footer className="border-t bg-card p-3">
        {error && (
          <p role="alert" className="mb-2 rounded-md bg-destructive/10 px-3 py-2 text-sm text-destructive">
            {error}
          </p>
        )}
        {open && !forceTemplate ? (
          <div>
            <div className="flex items-end gap-2">
              <Textarea
                value={text}
                onChange={(e) => setText(e.target.value)}
                onKeyDown={onKeyDown}
                rows={2}
                placeholder="Digite uma mensagem"
                aria-label="Mensagem"
                className="resize-none"
              />
              <Button onClick={submitText} disabled={!text.trim() || send.isPending} size="icon" aria-label="Enviar">
                <Send className="h-4 w-4" />
              </Button>
            </div>
            <p className="mt-1.5 text-[11px] text-muted-foreground">
              Janela de 24h aberta — restam {windowRemaining(conversation.last_inbound_at, now)}.{' '}
              <button className="underline" onClick={() => setForceTemplate(true)}>
                Enviar template
              </button>
            </p>
          </div>
        ) : (
          <div className="space-y-3">
            <p className="flex items-start gap-2 text-sm text-muted-foreground">
              <Lock className="mt-0.5 h-4 w-4 shrink-0" />
              {open
                ? 'Enviando um template.'
                : 'A janela de 24h está fechada. Para falar com este contato, envie um template aprovado.'}
              {open && (
                <button className="underline" onClick={() => setForceTemplate(false)}>
                  Voltar ao texto
                </button>
              )}
            </p>
            <TemplatePicker sending={send.isPending} onSend={(t) => send.mutate({ template_name: t.name, language: t.language, variables: t.variables })} />
          </div>
        )}
      </footer>
    </div>
  )
}
