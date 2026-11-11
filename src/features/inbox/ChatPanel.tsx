import { useMutation, useQueryClient } from '@tanstack/react-query'
import { ArrowLeft, Bot, FileText, Info, Link2, Lock, Mic, MoreVertical, Paperclip, Send, Square, StickyNote, User, X } from 'lucide-react'
import { useEffect, useLayoutEffect, useMemo, useRef, useState, type KeyboardEvent } from 'react'
import { Link } from 'react-router-dom'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Menu, MenuContent, MenuItem, MenuSeparator, MenuTrigger } from '@/components/ui/menu'
import { Textarea } from '@/components/ui/textarea'
import { useToast } from '@/components/ui/toast'
import { useOrders } from '@/hooks/orders'
import { useOrcamentosDoPedido } from '@/hooks/orcamentos'
import { EnviarPdfDialog } from '@/features/orders/EnviarPdfDialog'
import { useNotes, useQuickReplies } from '@/hooks/crm'
import { useMessages } from '@/hooks/queries'
import { useSetting } from '@/hooks/settings'
import { invokeFunction } from '@/lib/api'
import { contactLabel, formatDay, formatPhone, formatTime } from '@/lib/format'
import { formatBRL } from '@/lib/money'
import { supabase } from '@/lib/supabase'
import { reacoesPorMensagem, resumo } from '@/lib/messages'
import type { ConversationWithContact, Message } from '@/lib/types'
import { windowInfo } from '@/lib/window'
import { cn } from '@/lib/utils'
import { MessageBubble } from './MessageBubble'
import { MessageInfo } from './MessageInfo'
import { limparVariavel, primeiroNome, TEMPLATE_AVISO } from '@/lib/aviso-operacional'
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
  const [pdfDialog, setPdfDialog] = useState(false)
  const fileInput = useRef<HTMLInputElement>(null)
  const [replyTo, setReplyTo] = useState<Message | null>(null)
  const [arquivos, setArquivos] = useState<File[]>([])
  const [arrastando, setArrastando] = useState(false)
  const [info, setInfo] = useState<Message | null>(null)
  const [gravando, setGravando] = useState<{ rec: MediaRecorder; inicio: number } | null>(null)
  const [segundos, setSegundos] = useState(0)

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

  // /resetchat: zera o contexto do agente nesta conversa (só o que vem depois) e manda a saudação inicial, para novos testes com o mesmo número
  const resetChat = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc('resetar_contexto_conversa', { p_conversation: conversation.id })
      if (error) throw new Error(error.message)
      await invokeFunction('whatsapp-send', { conversation_id: conversation.id, text: 'Oi! Tudo bem? Aqui é da Sua Gráfica BH. Como posso te ajudar hoje?' })
    },
    onSuccess: () => {
      setText('')
      setError(null)
      qc.invalidateQueries({ queryKey: ['messages', conversation.id] })
      qc.invalidateQueries({ queryKey: ['conversations'] })
    },
    onError: (e: Error) => setError(e.message),
  })

  const sendFile = useMutation({
    mutationFn: (arg: { file: File; caption: string; replyTo?: string | null }) => {
      const form = new FormData()
      form.append('conversation_id', conversation.id)
      form.append('file', arg.file)
      if (arg.caption) form.append('caption', arg.caption)
      if (arg.replyTo) form.append('reply_to', arg.replyTo)
      return invokeFunction('whatsapp-send', form)
    },
    onError: (e: Error) => setError(e.message),
  })

  /** apagar no CRM, restaurar e reagir (ações sobre uma mensagem) */
  const acaoMsg = useMutation({
    mutationFn: (body: Record<string, unknown>) => invokeFunction('whatsapp-send', { conversation_id: conversation.id, ...body }),
    onSuccess: () => {
      setError(null)
      qc.invalidateQueries({ queryKey: ['messages', conversation.id] })
    },
    onError: (e: Error) => setError(e.message),
  })

  /** Envia os arquivos escolhidos (a legenda e a resposta vão no primeiro que aceita legenda) e depois o texto que sobrar. */
  async function enviarComArquivos() {
    const t = text.trim()
    const naoAceitaLegenda = (f: File) => f.type.startsWith('audio/') || f.type === 'image/webp'
    const idxLegenda = t ? arquivos.findIndex((f) => !naoAceitaLegenda(f)) : -1
    let primeiro = true
    try {
      for (let i = 0; i < arquivos.length; i++) {
        await sendFile.mutateAsync({ file: arquivos[i], caption: i === idxLegenda ? t : '', replyTo: primeiro ? replyTo?.wa_message_id : null })
        primeiro = false
      }
      if (t && idxLegenda === -1) await send.mutateAsync({ text: t, ...(primeiro && replyTo?.wa_message_id ? { reply_to: replyTo.wa_message_id } : {}) })
      setArquivos([])
      setText('')
      setReplyTo(null)
      setError(null)
      qc.invalidateQueries({ queryKey: ['messages', conversation.id] })
      qc.invalidateQueries({ queryKey: ['conversations'] })
    } catch {
      /* o erro já aparece no aviso acima */
    }
  }

  function adicionarArquivos(lista: FileList | File[] | null) {
    const novos = Array.from(lista ?? []).filter((f) => f.size > 0)
    if (!novos.length) return
    setError(null)
    setArquivos((a) => [...a, ...novos].slice(0, 10))
  }

  function formatoGravacao(): string | null {
    const candidatos = ['audio/ogg;codecs=opus', 'audio/mp4;codecs=mp4a.40.2', 'audio/mp4']
    return typeof MediaRecorder === 'undefined' ? null : (candidatos.find((c) => MediaRecorder.isTypeSupported(c)) ?? null)
  }

  async function alternarGravacao() {
    if (gravando) {
      gravando.rec.stop()
      return
    }
    const formato = formatoGravacao()
    if (!formato) {
      setError('Este navegador grava áudio em um formato que o WhatsApp não aceita. Grave pelo celular ou anexe um arquivo de áudio (MP3, OGG, M4A).')
      return
    }
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true })
      const rec = new MediaRecorder(stream, { mimeType: formato })
      const partes: BlobPart[] = []
      rec.ondataavailable = (e) => e.data.size && partes.push(e.data)
      rec.onstop = () => {
        stream.getTracks().forEach((t) => t.stop())
        setGravando(null)
        const ext = formato.startsWith('audio/ogg') ? 'ogg' : 'm4a'
        const tipo = formato.split(';')[0]
        const arq = new File(partes, `audio-${Date.now()}.${ext}`, { type: tipo })
        if (arq.size > 0) setArquivos((a) => [...a, arq])
      }
      rec.start()
      setSegundos(0)
      setGravando({ rec, inicio: Date.now() })
    } catch {
      setError('Não consegui usar o microfone. Libere a permissão do navegador e tente de novo.')
    }
  }

  useEffect(() => {
    if (!gravando) return
    const id = setInterval(() => setSegundos(Math.floor((Date.now() - gravando.inicio) / 1000)), 500)
    return () => clearInterval(id)
  }, [gravando])

  function enviarOrcamentoPdf() {
    if (!orcAtivo) return setError('Este pedido não tem orçamento ativo para enviar em PDF.')
    setPdfDialog(true)
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

  // trava contra clique repetido: o estado do mutation só atualiza no próximo render, então a ref barra o segundo clique do mesmo instante
  const assumindoRef = useRef(false)
  function takeOver() {
    if (assumindoRef.current || updateConv.isPending || !conversation.ai_handled) return
    assumindoRef.current = true
    updateConv.mutate(
      { ai_handled: false, attendant_changed_at: new Date().toISOString(), attendant_change_reason: 'Assumido pelo dono', needs_human: false },
      {
        onSuccess: () => {
          void logAction('assumiu_conversa', 'Assumido pelo dono')
          // aviso ao cliente uma única vez, só na passagem IA -> humano; sai por whatsapp-send (a API da Meta só é chamada nas Edge Functions)
          send.mutate({ text: 'Um de nossos consultores humanos acabou de assumir este atendimento para cuidar dos detalhes finais do seu pedido. Só um instante que já daremos continuidade!' })
        },
        onSettled: () => { assumindoRef.current = false },
      },
    )
  }
  function giveBack() {
    updateConv.mutate({ ai_handled: true, attendant_changed_at: new Date().toISOString(), attendant_change_reason: 'Devolvido para a IA' })
    void logAction('devolveu_para_ia', 'Devolvido para a IA')
  }

  function submit() {
    const t = text.trim()
    if (mode === 'reply' && t.toLowerCase() === '/resetchat') return void (resetChat.isPending || resetChat.mutate())
    if (mode === 'reply' && arquivos.length) return void enviarComArquivos()
    if (!t) return
    if (mode === 'note') {
      addNote.mutate(t, { onSuccess: () => setText('') })
      return
    }
    if (send.isPending) return
    send.mutate({ text: t, ...(replyTo?.wa_message_id ? { reply_to: replyTo.wa_message_id } : {}) }, { onSuccess: () => { setText(''); setReplyTo(null) } })
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

  // campo de mensagem cresce com o texto (até 140 px) e volta ao normal depois de enviar
  const taRef = useRef<HTMLTextAreaElement>(null)
  useLayoutEffect(() => {
    const t = taRef.current
    if (!t) return
    t.style.height = 'auto'
    t.style.height = `${Math.min(t.scrollHeight, 140)}px`
  }, [text, mode])

  const timeline = useMemo(() => {
    const items = [
      ...(messages ?? []).filter((m) => m.type !== 'reaction').map((m) => ({ kind: 'msg' as const, at: m.created_at, m })),
      ...(notes ?? []).map((n) => ({ kind: 'note' as const, at: n.created_at, n })),
    ]
    return items.sort((a, b) => a.at.localeCompare(b.at))
  }, [messages, notes])

  const reacoes = useMemo(() => reacoesPorMensagem(messages ?? []), [messages])
  const irPara = (waId: string) => document.getElementById(`msg-${waId}`)?.scrollIntoView({ behavior: 'smooth', block: 'center' })
  let lastDay = ''
  const canReply = !ai && win.open && !forceTemplate

  return (
    <div
      className="relative flex h-full flex-col bg-secondary/40"
      onDragOver={(e) => {
        if (mode !== 'reply' || !canReply || !e.dataTransfer.types.includes('Files')) return
        e.preventDefault()
        setArrastando(true)
      }}
      onDragLeave={(e) => {
        if (e.currentTarget === e.target) setArrastando(false)
      }}
      onDrop={(e) => {
        if (mode !== 'reply' || !canReply) return
        e.preventDefault()
        setArrastando(false)
        adicionarArquivos(e.dataTransfer.files)
      }}
    >
      {arrastando && (
        <div className="pointer-events-none absolute inset-0 z-30 flex items-center justify-center border-4 border-dashed border-brand-cyan bg-brand-cyan/10 text-lg font-black">
          Solte para anexar (foto, vídeo, áudio ou documento)
        </div>
      )}
      <MessageInfo m={info} onClose={() => setInfo(null)} />
      <EnviarPdfDialog
        open={pdfDialog}
        onOpenChange={setPdfDialog}
        orcamento={orcAtivo ? { id: orcAtivo.id, numero: orcAtivo.numero, pdf_enviado_em: orcAtivo.pdf_enviado_em ?? null } : null}
        janelaAberta={win.open}
      />
      <header className="border-b bg-card">
        <div className="flex items-center gap-1 px-2 py-1.5 md:gap-3 md:px-4 md:py-3">
          <Link to="/inbox" className="flex h-11 w-11 shrink-0 items-center justify-center rounded-md hover:bg-secondary md:hidden" aria-label="Voltar para a lista">
            <ArrowLeft className="h-5 w-5" />
          </Link>
          <div className="min-w-0 flex-1 md:flex-none">
            <p className="truncate text-base font-black leading-tight md:text-sm">{contactLabel(conversation.contact)}</p>
            <p className="truncate text-xs text-muted-foreground">{formatPhone(conversation.contact.wa_id)}</p>
          </div>
          {/* Desktop: todas as ações à vista */}
          <div className="ml-auto hidden items-center gap-2 md:flex">
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
          {/* Celular: só o essencial; o resto vai no menu (divulgação progressiva) */}
          <div className="flex shrink-0 items-center md:hidden">
            <span
              className={cn('mr-1 flex h-8 items-center gap-1 rounded-full px-2.5 text-xs font-bold', ai ? 'bg-brand-blue text-white' : 'bg-ink/10 text-ink')}
              role="status"
            >
              {ai ? <Bot className="h-3.5 w-3.5" aria-hidden /> : <User className="h-3.5 w-3.5" aria-hidden />}
              {ai ? 'IA' : 'Você'}
            </span>
            {onDetails && (
              <button onClick={onDetails} aria-label="Detalhes do cliente" className="flex h-11 w-11 items-center justify-center rounded-md hover:bg-secondary">
                <Info className="h-5 w-5" />
              </button>
            )}
            <Menu>
              <MenuTrigger aria-label="Mais ações" className="flex h-11 w-11 items-center justify-center rounded-md hover:bg-secondary">
                <MoreVertical className="h-5 w-5" />
              </MenuTrigger>
              <MenuContent align="end">
                <MenuItem onSelect={ai ? takeOver : giveBack} disabled={updateConv.isPending}>
                  {ai ? <User className="h-4 w-4" /> : <Bot className="h-4 w-4" />} {ai ? 'Assumir conversa' : 'Devolver para a IA'}
                </MenuItem>
                <MenuItem onSelect={() => updateConv.mutate({ needs_human: !conversation.needs_human })}>
                  {conversation.needs_human ? 'Tirar marca de atenção' : 'Marcar: precisa de atenção'}
                </MenuItem>
                {openOrder && (
                  <>
                    <MenuSeparator />
                    <MenuItem asChild>
                      <Link to={`/kanban?pedido=${openOrder.id}`}>Abrir pedido #{openOrder.number}</Link>
                    </MenuItem>
                  </>
                )}
              </MenuContent>
            </Menu>
          </div>
        </div>
        {/* Etiquetas: uma linha só, com rolagem lateral no celular (nada de 3 linhas de botões) */}
        <div className="flex items-center gap-1.5 overflow-x-auto px-3 pb-2 [scrollbar-width:none] md:flex-wrap md:px-4 md:pb-3 [&>*]:shrink-0 md:[&>*]:shrink">
          {openOrder && (
            <Link to={`/kanban?pedido=${openOrder.id}`} className="order-first inline-flex min-h-9 items-center gap-1 rounded-full border bg-background px-3 text-xs font-semibold text-link underline md:order-last md:ml-auto md:rounded-sm md:px-2">
              Pedido #{openOrder.number}
            </Link>
          )}
          <button
            onClick={() => updateConv.mutate({ needs_human: !conversation.needs_human })}
            aria-pressed={!!conversation.needs_human}
            className={cn(
              'min-h-9 whitespace-nowrap rounded-full border px-3 text-xs font-semibold md:rounded-sm md:px-2',
              conversation.needs_human ? 'border-brand-red bg-brand-red text-white' : 'hidden bg-background text-muted-foreground hover:bg-secondary md:block',
            )}
          >
            {conversation.needs_human ? 'Precisa de atenção' : 'Marcar: precisa de atenção'}
          </button>
          {(labelsList ?? []).map((l) => {
            const on = conversation.labels?.includes(l)
            return (
              <button
                key={l}
                aria-pressed={!!on}
                onClick={() => updateConv.mutate({ labels: on ? (conversation.labels ?? []).filter((x) => x !== l) : [...(conversation.labels ?? []), l] })}
                className={cn('min-h-9 whitespace-nowrap rounded-full border px-3 text-xs font-medium md:rounded-sm md:px-2', on ? 'border-brand-cyan bg-brand-cyan/20 font-bold text-ink' : 'bg-background text-muted-foreground hover:bg-secondary')}
              >
                {l}
              </button>
            )
          })}
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
          return (
            <div key={m.id}>
              {dayEl}
              <MessageBubble
                m={m}
                todas={messages ?? []}
                reacoes={m.wa_message_id ? reacoes[m.wa_message_id] : undefined}
                podeReagir={canReply && !!m.wa_message_id}
                onResponder={(x) => setReplyTo(x)}
                onReagir={(x, emoji) => acaoMsg.mutate({ action: 'react', message_id: x.id, emoji })}
                onApagar={(x) => {
                  if (window.confirm('Apagar esta mensagem no CRM? O cliente continua vendo a dele (a API oficial do WhatsApp não apaga no celular do cliente). Dá para restaurar depois.')) acaoMsg.mutate({ action: 'delete', message_id: x.id })
                }}
                onRestaurar={(x) => acaoMsg.mutate({ action: 'restore', message_id: x.id })}
                onDados={setInfo}
                onIrPara={irPara}
              />
            </div>
          )
        })}
        {!isLoading && timeline.length === 0 && <p className="py-10 text-center text-sm text-muted-foreground">Nenhuma mensagem ainda.</p>}
        <div ref={bottomRef} />
      </div>

      <footer className="border-t bg-card px-3 pt-2 pb-[max(0.75rem,env(safe-area-inset-bottom))] md:p-3">
        {error && (
          <p role="alert" className="mb-2 rounded-md border border-destructive/30 bg-destructive/5 px-3 py-2 text-sm">
            {error}
          </p>
        )}

        <div className="mb-2 flex items-center gap-1.5 overflow-x-auto [scrollbar-width:none] md:flex-wrap [&>*]:shrink-0" role="tablist" aria-label="Tipo de envio">
          <button role="tab" aria-selected={mode === 'reply'} onClick={() => setMode('reply')} className={cn('min-h-11 rounded-full px-3.5 text-sm font-bold md:min-h-9 md:rounded-sm md:px-2.5 md:text-xs', mode === 'reply' ? 'bg-ink text-white' : 'bg-secondary')}>
            Responder
          </button>
          <button role="tab" aria-selected={mode === 'note'} onClick={() => setMode('note')} className={cn('inline-flex min-h-11 items-center gap-1 rounded-full px-4 text-sm font-bold md:min-h-9 md:rounded-sm md:px-2.5 md:text-xs', mode === 'note' ? 'bg-brand-yellow text-ink' : 'bg-secondary')}>
            <StickyNote className="h-3.5 w-3.5" aria-hidden /> <span className="md:hidden">Nota</span><span className="hidden md:inline">Nota interna</span>
          </button>
          {mode === 'reply' && canReply && (
            <>
              <button
                disabled={!orcAtivo}
                onClick={enviarOrcamentoPdf}
                title={orcAtivo ? 'Envia o PDF do orçamento no WhatsApp' : 'Este pedido não tem orçamento ativo. Crie ou abra o orçamento no pedido.'}
                className="inline-flex min-h-11 items-center gap-1 whitespace-nowrap rounded-full border px-3 text-sm font-semibold disabled:opacity-40 md:min-h-9 md:rounded-sm md:px-2.5 md:text-xs"
              >
                <FileText className="h-4 w-4 md:h-3.5 md:w-3.5" aria-hidden /> <span className="md:hidden">PDF</span><span className="hidden md:inline">Enviar PDF do orçamento</span>
              </button>
              <button
                disabled={!openOrder?.payment_link}
                title={openOrder?.payment_link ? undefined : 'O pedido ainda não tem link de pagamento'}
                onClick={() => openOrder?.payment_link && setText(`Segue o link para pagamento (${formatBRL(openOrder.fin.total)}): ${openOrder.payment_link}`)}
                className="inline-flex min-h-11 items-center gap-1 whitespace-nowrap rounded-full border px-3 text-sm font-semibold disabled:opacity-40 md:min-h-9 md:rounded-sm md:px-2.5 md:text-xs"
              >
                <Link2 className="h-4 w-4 md:h-3.5 md:w-3.5" aria-hidden /> <span className="md:hidden">Link</span><span className="hidden md:inline">Link de pagamento</span>
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
            {mode === 'reply' && replyTo && (
              <div className="mb-2 flex items-start gap-2 rounded-md border-l-4 border-brand-blue bg-background px-3 py-2 text-xs">
                <div className="min-w-0 flex-1">
                  <p className="font-bold text-brand-blue">Respondendo {replyTo.direction === 'out' ? 'a você' : 'ao cliente'}</p>
                  <p className="line-clamp-2 text-muted-foreground">{resumo(replyTo)}</p>
                </div>
                <button aria-label="Cancelar resposta" onClick={() => setReplyTo(null)} className="flex h-6 w-6 items-center justify-center rounded-full hover:bg-secondary"><X className="h-4 w-4" /></button>
              </div>
            )}
            {mode === 'reply' && arquivos.length > 0 && (
              <ul className="mb-2 flex flex-wrap gap-1.5" aria-label="Arquivos para enviar">
                {arquivos.map((f, i) => (
                  <li key={`${f.name}-${i}`} className="flex max-w-full items-center gap-1.5 rounded-md border bg-background px-2 py-1 text-xs">
                    {f.type.startsWith('image/') ? <img src={URL.createObjectURL(f)} alt="" className="h-8 w-8 rounded object-cover" /> : f.type.startsWith('audio/') ? <Mic className="h-4 w-4" aria-hidden /> : <FileText className="h-4 w-4" aria-hidden />}
                    <span className="max-w-40 truncate">{f.name}</span>
                    <button aria-label={`Remover ${f.name}`} onClick={() => setArquivos((a) => a.filter((_, j) => j !== i))} className="flex h-5 w-5 items-center justify-center rounded-full hover:bg-secondary"><X className="h-3.5 w-3.5" /></button>
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
                    multiple
                    className="hidden"
                    accept="image/jpeg,image/png,image/webp,video/mp4,video/3gpp,audio/*,application/pdf,.doc,.docx,.xls,.xlsx,.ppt,.pptx,.txt"
                    onChange={(e) => {
                      adicionarArquivos(e.target.files)
                      e.target.value = ''
                    }}
                  />
                  <Button type="button" variant="outline" size="icon" aria-label="Anexar arquivo" title="Anexar foto, vídeo, áudio ou documento (até 16 MB). Também dá para arrastar e soltar ou colar uma imagem." disabled={sendFile.isPending || !win.open} onClick={() => fileInput.current?.click()}>
                    <Paperclip className="h-4 w-4" />
                  </Button>
                  <Button type="button" variant={gravando ? 'destructive' : 'outline'} size="icon" aria-label={gravando ? 'Parar gravação' : 'Gravar áudio'} title={gravando ? `Gravando ${segundos}s. Clique para parar.` : 'Gravar áudio'} disabled={sendFile.isPending || !win.open} onClick={() => void alternarGravacao()}>
                    {gravando ? <Square className="h-4 w-4" /> : <Mic className="h-4 w-4" />}
                  </Button>
                </>
              )}
              <Textarea
                ref={taRef}
                value={text}
                onChange={(e) => setText(e.target.value)}
                onKeyDown={onKeyDown}
                onPaste={(e) => {
                  const imgs = Array.from(e.clipboardData.files)
                  if (imgs.length && mode === 'reply' && win.open) {
                    e.preventDefault()
                    adicionarArquivos(imgs)
                  }
                }}
                rows={text.includes('\n') ? 5 : 1}
                className={cn('min-h-11 resize-none py-2.5 md:min-h-[60px] md:py-2', mode === 'note' && 'border-brand-yellow bg-brand-yellow/10')}
                placeholder={mode === 'note' ? 'Nota só para você (o cliente não recebe)' : 'Digite uma mensagem ou / para respostas rápidas'}
                aria-label={mode === 'note' ? 'Nota interna' : 'Mensagem'}
              />
              <Button onClick={submit} disabled={(!text.trim() && !(mode === 'reply' && arquivos.length)) || send.isPending || sendFile.isPending || addNote.isPending} size="icon" aria-label={mode === 'note' ? 'Salvar nota' : 'Enviar'}>
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
            <Button size="sm" onClick={takeOver} disabled={updateConv.isPending}>Assumir conversa</Button>
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
            {!win.open && <ReabrirJanela nome={conversation.contact.name} sending={send.isPending} onSend={(body) => send.mutate(body)} />}
            <TemplatePicker sending={send.isPending} onSend={(t) => send.mutate({ template_name: t.name, language: t.language, variables: t.variables })} />
          </div>
        )}
        {badges(conversation)}
      </footer>
    </div>
  )
}

/** Janela de 24 h fechada: um botão dispara o template oficial "aviso_operacional_pedido" com o nome do cliente e a mensagem digitada. */
function ReabrirJanela({ nome, sending, onSend }: { nome: string | null; sending: boolean; onSend: (body: Record<string, unknown>) => void }) {
  const [detalhe, setDetalhe] = useState('')
  const variaveis = [primeiroNome(nome), limparVariavel(detalhe)]
  return (
    <div className="space-y-2 rounded-md border border-brand-yellow/60 bg-brand-yellow/10 p-3">
      <p className="text-sm font-semibold">Reabrir a janela de 24 h</p>
      <Textarea aria-label="Mensagem sobre o pedido" rows={2} value={detalhe} onChange={(e) => setDetalhe(e.target.value)} placeholder="Ex.: Seu pedido está pronto para retirada. Qual o melhor horário?" />
      <p className="text-[11px] text-muted-foreground">Sai como: "Olá, {variaveis[0]}! Aqui é da equipe de atendimento da Sua Gráfica BH sobre o seu pedido. {variaveis[1] || '(sua mensagem)'} Qualquer dúvida, é só nos responder por aqui!"</p>
      <Button size="sm" disabled={!variaveis[1] || sending} onClick={() => onSend({ template_name: TEMPLATE_AVISO.name, language: TEMPLATE_AVISO.language, variables: variaveis })}>
        Enviar aviso e reabrir a conversa
      </Button>
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
