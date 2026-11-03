import { useMutation, useQueryClient } from '@tanstack/react-query'
import { ArrowLeft, Bot, FileText, Link2, Lock, Paperclip, Send, StickyNote, User } from 'lucide-react'
import { useEffect, useLayoutEffect, useMemo, useRef, useState, type KeyboardEvent } from 'react'
import { Link } from 'react-router-dom'
import { MessageStatusIcon } from '@/components/MessageStatusIcon'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Textarea } from '@/components/ui/textarea'
import { useToast } from '@/components/ui/toast'
import { useOrders } from '@/hooks/orders'
import { useOrcamentosDoPedido, useReenviarOrcamento } from '@/hooks/orcamentos'
import { useNotes, useQuickReplies } from '@/hooks/crm'
import { useMessages } from '@/hooks/queries'
import { useSetting } from '@/hooks/settings'
import { invokeFunction } from '@/lib/api'
import { contactLabel, formatDay, formatPhone, formatTime } from '@/lib/format'
import { formatBRL } from '@/lib/money'
import { supabase } from '@/lib/supabase'
import type { ConversationWithContact } from '@/lib/types'
import { windowInfo } from '@/lib/window'
import { cn } from '@/lib/utils'
import { LocationLink, MediaView } from './MediaView'
import { TemplatePicker } from './TemplatePicker'

const PAGE = 60

export function ChatPanel({ conversation, onDetails }: { conversation: ConversationWithContact; onDetails?: () => void }) {
  const qc = useQueryClient()
  const toast = useToast()
  const [limit, setLimit] = useState(PAGE)
  const { data: messages, isLoading } = useMessages(conversation.id, limit)
  const { data: notes } = useNotes(conversation.id)
  const { data: quick } = useQuickReplies()
  const { data: labelsList } = useSetting('labels')
  const { data: orders } = useOrders()
  const [text, setText] = useState('')
  const [mode, setMode] = useState<'reply' | 'note'>('reply')
  const [error, setError] = useState<string | null>(null)
  const [now, setNow] = useState(() => Date.now())
  const [forceTemplate, setForceTemplate] = useState(false)
  const scroller = useRef<HTMLDivElement>(null)
  const bottomRef = useRef<HTMLDivElement>(null)
  const prevHeight = useRef(0)

  const win = windowInfo(conversation, now)
  const ai = conversation.ai_handled
  const linked = useMemo(() => (orders ?? []).filter((o) => o.contact_id === conversation.contact_id), [orders, conversation.contact_id])
  const openOrder = linked.find((o) => !['entregue', 'recompra'].includes(o.stage)) ?? linked[0]
  const { data: orcs } = useOrcamentosDoPedido(openOrder?.id ?? '', conversation.contact_id)
  const orcAtivo = (orcs ?? []).find((o) => ['rascunho', 'enviado', 'aceito'].includes(o.status))
  const enviarPdf = useReenviarOrcamento()
  const fileInput = useRef<HTMLInputElement>(null)

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

  const count = (messages?.length ?? 0) + (notes?.length ?? 0)
  // Mensagem nova: desce até o fim. Carregar anteriores: mantém a posição de leitura.
  useLayoutEffect(() => {
    const el = scroller.current
    if (!el) return
    if (prevHeight.current && limit > PAGE) {
      el.scrollTop = el.scrollHeight - prevHeight.current
      prevHeight.current = 0
    } else {
      bottomRef.current?.scrollIntoView({ block: 'end' })
    }
  }, [count, conversation.id, limit])

  const send = useMutation({
    mutationFn: (body: Record<string, unknown>) => invokeFunction('whatsapp-send', { conversation_id: conversation.id, ...body }),
    onSuccess: () => {
      setError(null)
      qc.invalidateQueries({ queryKey: ['messages', conversation.id] })
      qc.invalidateQueries({ queryKey: ['conversations'] })
    },
    onError: (e: Error) => setError(e.message),
  })

  const sendFile = useMutation({
    mutationFn: (arg: { file: File; caption: string }) => {
      const form = new FormData()
      form.append('conversation_id', conversation.id)
      form.append('file', arg.file)
      if (arg.caption) form.append('caption', arg.caption)
      return invokeFunction('whatsapp-send', form)
    },
    onSuccess: () => {
      setError(null)
      setText('')
      qc.invalidateQueries({ queryKey: ['messages', conversation.id] })
      qc.invalidateQueries({ queryKey: ['conversations'] })
    },
    onError: (e: Error) => setError(e.message),
  })

  function enviarOrcamentoPdf() {
    if (!orcAtivo) return setText(quoteText())
    const jaEnviado = !!orcAtivo.pdf_enviado_em
    if (!window.confirm(jaEnviado ? 'Este orçamento já foi enviado. Enviar o PDF de novo ao cliente?' : 'Enviar o PDF do orçamento ao cliente agora?')) return
    enviarPdf.mutate(orcAtivo.id, {
      onSuccess: (r) => toast('ok', `Orçamento ${r.numero} enviado no WhatsApp.`),
      onError: (e) => setError(e.message),
    })
  }

  const addNote = useMutation({
    mutationFn: async (body: string) => {
      const { error } = await supabase.from('conversation_notes').insert({ conversation_id: conversation.id, body })
      if (error) throw new Error(error.message)
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['notes', conversation.id] }),
    onError: (e: Error) => toast('error', e.message),
  })

  const updateConv = useMutation({
    mutationFn: async (patch: Record<string, unknown>) => {
      const { error } = await supabase.from('conversations').update(patch).eq('id', conversation.id)
      if (error) throw new Error(error.message)
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['conversations'] }),
    onError: (e: Error) => toast('error', e.message),
  })

  const logAction = (action: string, reason: string) =>
    supabase.from('agent_logs').insert({ conversation_id: conversation.id, actor: 'humano', action, detail: { reason }, result: 'ok' })

  function takeOver() {
    updateConv.mutate({ ai_handled: false, attendant_changed_at: new Date().toISOString(), attendant_change_reason: 'Assumido pelo dono', needs_human: false })
    void logAction('assumiu_conversa', 'Assumido pelo dono')
  }
  function giveBack() {
    updateConv.mutate({ ai_handled: true, attendant_changed_at: new Date().toISOString(), attendant_change_reason: 'Devolvido para a IA' })
    void logAction('devolveu_para_ia', 'Devolvido para a IA')
  }

  function submit() {
    const t = text.trim()
    if (!t) return
    if (mode === 'note') {
      addNote.mutate(t, { onSuccess: () => setText('') })
      return
    }
    if (send.isPending) return
    send.mutate({ text: t }, { onSuccess: () => setText('') })
  }

  // Atalho "/": sugere respostas rápidas
  const slash = mode === 'reply' && text.startsWith('/') && !text.includes(' ') ? text.slice(1).toLowerCase() : null
  const suggestions = slash === null ? [] : (quick ?? []).filter((q) => q.shortcut.startsWith(slash) || q.title.toLowerCase().includes(slash)).slice(0, 5)

  function onKeyDown(e: KeyboardEvent<HTMLTextAreaElement>) {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault()
      if (suggestions.length === 1 && slash !== null) setText(suggestions[0].body)
      else submit()
    }
  }

  function quoteText() {
    if (!openOrder) return ''
    const lines = openOrder.items.map((i) => `${i.qty}x ${i.description}`)
    return `Orçamento ${openOrder.title}:\n${lines.join('\n')}\nTotal: ${formatBRL(openOrder.fin.total)}\nSe estiver tudo certo, é só confirmar por aqui que eu já envio o link de pagamento.`
  }

  const timeline = useMemo(() => {
    const items = [
      ...(messages ?? []).map((m) => ({ kind: 'msg' as const, at: m.created_at, m })),
      ...(notes ?? []).map((n) => ({ kind: 'note' as const, at: n.created_at, n })),
    ]
    return items.sort((a, b) => a.at.localeCompare(b.at))
  }, [messages, notes])

  let lastDay = ''
  const canReply = !ai && win.open && !forceTemplate

  return (
    <div className="flex h-full flex-col bg-secondary/40">
      <header className="space-y-2 border-b bg-card px-4 py-3">
        <div className="flex items-center gap-3">
          <Link to="/inbox" className="flex h-11 w-11 items-center justify-center md:hidden" aria-label="Voltar para a lista">
            <ArrowLeft className="h-5 w-5" />
          </Link>
          <div className="min-w-0">
            <p className="truncate text-sm font-black">{contactLabel(conversation.contact)}</p>
            <p className="text-xs text-muted-foreground">{formatPhone(conversation.contact.wa_id)}</p>
          </div>
          <div className="ml-auto flex items-center gap-2">
            <span className={cn('flex items-center gap-1 rounded-sm px-2 py-1 text-xs font-bold', ai ? 'bg-brand-blue text-white' : 'bg-ink/10 text-ink')}>
              {ai ? <Bot className="h-3.5 w-3.5" aria-hidden /> : <User className="h-3.5 w-3.5" aria-hidden />}
              {ai ? 'IA atendendo' : 'Humano atendendo'}
            </span>
            {ai ? (
              <Button size="sm" onClick={takeOver} disabled={updateConv.isPending}>Assumir conversa</Button>
            ) : (
              <Button size="sm" variant="outline" onClick={giveBack} disabled={updateConv.isPending}>Devolver para a IA</Button>
            )}
            {onDetails && (
              <Button variant="outline" size="sm" className="xl:hidden" onClick={onDetails}>
                Detalhes
              </Button>
            )}
          </div>
        </div>
        <div className="flex flex-wrap items-center gap-1.5">
          <button
            onClick={() => updateConv.mutate({ needs_human: !conversation.needs_human })}
            aria-pressed={!!conversation.needs_human}
            className={cn(
              'min-h-9 rounded-sm border px-2 text-xs font-semibold',
              conversation.needs_human ? 'border-brand-red bg-brand-red text-white' : 'bg-background text-muted-foreground hover:bg-secondary',
            )}
          >
            {conversation.needs_human ? 'Precisa de atenção humana' : 'Marcar: precisa de atenção'}
          </button>
          {(labelsList ?? []).map((l) => {
            const on = conversation.labels?.includes(l)
            return (
              <button
                key={l}
                aria-pressed={!!on}
                onClick={() => updateConv.mutate({ labels: on ? (conversation.labels ?? []).filter((x) => x !== l) : [...(conversation.labels ?? []), l] })}
                className={cn('min-h-9 rounded-sm border px-2 text-xs font-medium', on ? 'border-brand-cyan bg-brand-cyan/20 font-bold text-ink' : 'bg-background text-muted-foreground hover:bg-secondary')}
              >
                {l}
              </button>
            )
          })}
          {openOrder && (
            <Link to={`/kanban?pedido=${openOrder.id}`} className="ml-auto inline-flex min-h-9 items-center gap-1 rounded-sm border bg-background px-2 text-xs font-semibold text-link underline">
              Pedido #{openOrder.number}
            </Link>
          )}
        </div>
      </header>

      <div ref={scroller} className="min-h-0 flex-1 space-y-1 overflow-y-auto px-4 py-4">
        {(messages?.length ?? 0) >= limit && (
          <div className="text-center">
            <Button
              variant="outline"
              size="sm"
              onClick={() => {
                prevHeight.current = scroller.current?.scrollHeight ?? 0
                setLimit((l) => l + PAGE)
              }}
            >
              Carregar mensagens anteriores
            </Button>
          </div>
        )}
        {isLoading && <p className="text-center text-sm text-muted-foreground">Carregando mensagens…</p>}
        {timeline.map((item) => {
          const day = formatDay(item.at)
          const showDay = day !== lastDay
          lastDay = day
          const dayEl = showDay && (
            <p className="my-3 text-center text-xs text-muted-foreground">
              <span className="rounded-full bg-card px-3 py-1 shadow-sm">{day}</span>
            </p>
          )
          if (item.kind === 'note') {
            return (
              <div key={`n-${item.n.id}`}>
                {dayEl}
                <div className="flex justify-center">
                  <div className="max-w-[85%] rounded-md border border-dashed border-brand-yellow bg-brand-yellow/20 px-3 py-2 text-sm">
                    <p className="mb-0.5 flex items-center gap-1 text-[11px] font-bold uppercase tracking-wide"><Lock className="h-3 w-3" aria-hidden /> Nota interna · o cliente não vê</p>
                    <p className="whitespace-pre-wrap break-words">{item.n.body}</p>
                    <p className="mt-1 text-right text-[11px] text-muted-foreground">{formatTime(item.n.created_at)}</p>
                  </div>
                </div>
              </div>
            )
          }
          const m = item.m
          const out = m.direction === 'out'
          return (
            <div key={m.id}>
              {dayEl}
              <div className={cn('flex', out ? 'justify-end' : 'justify-start')}>
                <div className={cn('max-w-[80%] rounded-lg px-3 py-2 text-sm shadow-sm', out ? 'bg-brand-cyan/20' : 'bg-card', m.status === 'failed' && 'ring-1 ring-destructive')}>
                  {m.type === 'template' && <p className="mb-0.5 text-[11px] font-medium text-muted-foreground">Template: {m.template_name}</p>}
                  <MediaView message={m} />
                  <LocationLink body={m.body ?? ''} />
                  <p className={cn('whitespace-pre-wrap break-words', m.type !== 'text' && m.type !== 'template' && 'italic text-muted-foreground')}>{m.body}</p>
                  <div className="mt-1 flex items-center justify-end gap-1 text-[11px] text-muted-foreground tabular">
                    {formatTime(m.created_at)}
                    {out && <MessageStatusIcon status={m.status} error={m.error} />}
                  </div>
                  {m.status === 'failed' && m.error && <p className="mt-1 text-[11px] text-destructive">Falha no envio: {m.error}</p>}
                </div>
              </div>
            </div>
          )
        })}
        {!isLoading && timeline.length === 0 && <p className="py-10 text-center text-sm text-muted-foreground">Nenhuma mensagem ainda.</p>}
        <div ref={bottomRef} />
      </div>

      <footer className="border-t bg-card p-3">
        {error && (
          <p role="alert" className="mb-2 rounded-md border border-destructive/30 bg-destructive/5 px-3 py-2 text-sm">
            {error}
          </p>
        )}

        <div className="mb-2 flex flex-wrap items-center gap-1.5" role="tablist" aria-label="Tipo de envio">
          <button role="tab" aria-selected={mode === 'reply'} onClick={() => setMode('reply')} className={cn('min-h-9 rounded-sm px-2.5 text-xs font-bold', mode === 'reply' ? 'bg-ink text-white' : 'bg-secondary')}>
            Responder
          </button>
          <button role="tab" aria-selected={mode === 'note'} onClick={() => setMode('note')} className={cn('inline-flex min-h-9 items-center gap-1 rounded-sm px-2.5 text-xs font-bold', mode === 'note' ? 'bg-brand-yellow text-ink' : 'bg-secondary')}>
            <StickyNote className="h-3.5 w-3.5" aria-hidden /> Nota interna
          </button>
          {mode === 'reply' && canReply && (
            <>
              <button
                disabled={(!orcAtivo && (!openOrder || openOrder.items.length === 0)) || enviarPdf.isPending}
                onClick={enviarOrcamentoPdf}
                title={orcAtivo ? 'Envia o PDF do orçamento no WhatsApp' : 'Sem orçamento em PDF: monta o resumo em texto'}
                className="inline-flex min-h-9 items-center gap-1 rounded-sm border px-2.5 text-xs font-semibold disabled:opacity-40"
              >
                <FileText className="h-3.5 w-3.5" aria-hidden /> {enviarPdf.isPending ? 'Enviando…' : orcAtivo ? 'Enviar PDF do orçamento' : 'Enviar orçamento'}
              </button>
              <button
                disabled={!openOrder?.payment_link}
                title={openOrder?.payment_link ? undefined : 'O pedido ainda não tem link de pagamento'}
                onClick={() => openOrder?.payment_link && setText(`Segue o link para pagamento (${formatBRL(openOrder.fin.total)}): ${openOrder.payment_link}`)}
                className="inline-flex min-h-9 items-center gap-1 rounded-sm border px-2.5 text-xs font-semibold disabled:opacity-40"
              >
                <Link2 className="h-3.5 w-3.5" aria-hidden /> Link de pagamento
              </button>
            </>
          )}
        </div>

        {mode === 'note' || canReply ? (
          <div>
            {suggestions.length > 0 && (
              <ul className="mb-2 overflow-hidden rounded-md border bg-background" role="listbox" aria-label="Respostas rápidas">
                {suggestions.map((s) => (
                  <li key={s.id}>
                    <button role="option" aria-selected="false" onClick={() => setText(s.body)} className="flex min-h-11 w-full items-start gap-2 px-3 py-1.5 text-left text-sm hover:bg-secondary md:min-h-9">
                      <code className="rounded-sm bg-secondary px-1 text-xs font-bold">/{s.shortcut}</code>
                      <span className="min-w-0 flex-1"><strong>{s.title}</strong> <span className="text-muted-foreground">{s.body.slice(0, 70)}</span></span>
                    </button>
                  </li>
                ))}
              </ul>
            )}
            <div className="flex items-end gap-2">
              {mode === 'reply' && (
                <>
                  <input
                    ref={fileInput}
                    type="file"
                    className="hidden"
                    accept="application/pdf,image/jpeg,image/png,.doc,.docx,.xls,.xlsx"
                    onChange={(e) => {
                      const f = e.target.files?.[0]
                      e.target.value = ''
                      if (f) sendFile.mutate({ file: f, caption: text.trim() })
                    }}
                  />
                  <Button type="button" variant="outline" size="icon" aria-label="Anexar arquivo" title="Anexar PDF, imagem, Word ou Excel (até 10 MB)" disabled={sendFile.isPending || !win.open} onClick={() => fileInput.current?.click()}>
                    <Paperclip className="h-4 w-4" />
                  </Button>
                </>
              )}
              <Textarea
                value={text}
                onChange={(e) => setText(e.target.value)}
                onKeyDown={onKeyDown}
                rows={mode === 'reply' && text.includes('\n') ? 5 : 2}
                placeholder={mode === 'note' ? 'Nota só para você (o cliente não recebe)' : 'Digite uma mensagem ou / para respostas rápidas'}
                aria-label={mode === 'note' ? 'Nota interna' : 'Mensagem'}
                className={cn('resize-none', mode === 'note' && 'border-brand-yellow bg-brand-yellow/10')}
              />
              <Button onClick={submit} disabled={!text.trim() || send.isPending || addNote.isPending} size="icon" aria-label={mode === 'note' ? 'Salvar nota' : 'Enviar'}>
                <Send className="h-4 w-4" />
              </Button>
            </div>
            {mode === 'reply' && (
              <p className="mt-1.5 text-[11px] text-muted-foreground">
                Janela de {win.kind} aberta{win.kind === '72h' ? ' (conversa veio de anúncio)' : ''}: restam <strong className="tabular">{win.remaining}</strong>.{' '}
                <button className="inline-flex min-h-6 items-center underline" onClick={() => setForceTemplate(true)}>
                  Enviar template
                </button>
              </p>
            )}
          </div>
        ) : ai ? (
          <div className="flex flex-wrap items-center justify-between gap-3 rounded-md border border-brand-blue/30 bg-brand-blue/5 p-3 text-sm">
            <p className="flex items-center gap-2"><Bot className="h-4 w-4 shrink-0" aria-hidden /> A IA está atendendo esta conversa. Assuma para responder você mesmo.</p>
            <Button size="sm" onClick={takeOver}>Assumir conversa</Button>
          </div>
        ) : (
          <div className="space-y-3">
            <p className="flex items-start gap-2 text-sm text-muted-foreground">
              <Lock className="mt-0.5 h-4 w-4 shrink-0" />
              {win.open ? 'Enviando um template.' : 'A janela de atendimento está fechada. Para falar com este contato, envie um template aprovado.'}
              {win.open && (
                <button className="underline" onClick={() => setForceTemplate(false)}>
                  Voltar ao texto
                </button>
              )}
            </p>
            <TemplatePicker sending={send.isPending} onSend={(t) => send.mutate({ template_name: t.name, language: t.language, variables: t.variables })} />
          </div>
        )}
        {badges(conversation)}
      </footer>
    </div>
  )
}

function badges(c: ConversationWithContact) {
  return c.summary ? (
    <p className="mt-2 border-t pt-2 text-xs text-muted-foreground">
      <Badge className="mr-1 bg-brand-blue/10 text-brand-blue">Resumo da IA</Badge>
      {c.summary}
    </p>
  ) : null
}
