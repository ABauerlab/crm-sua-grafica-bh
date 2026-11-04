import { useMutation, useQueryClient } from '@tanstack/react-query'
import { ArrowLeft, Bot, FileText, Link2, Lock, Mic, Paperclip, Send, Square, StickyNote, User, X } from 'lucide-react'
import { useEffect, useLayoutEffect, useMemo, useRef, useState, type KeyboardEvent } from 'react'
import { Link } from 'react-router-dom'
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
import { reacoesPorMensagem, resumo } from '@/lib/messages'
import type { ConversationWithContact, Message } from '@/lib/types'
import { windowInfo } from '@/lib/window'
import { cn } from '@/lib/utils'
import { MessageBubble } from './MessageBubble'
import { MessageInfo } from './MessageInfo'
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
    const eraIA = conversation.ai_handled
    updateConv.mutate({ ai_handled: false, attendant_changed_at: new Date().toISOString(), attendant_change_reason: 'Assumido pelo dono', needs_human: false })
    void logAction('assumiu_conversa', 'Assumido pelo dono')
    // aviso ao cliente só na passagem IA -> humano; sai por whatsapp-send (a API da Meta só é chamada nas Edge Functions)
    if (eraIA) send.mutate({ text: 'Olá! Aqui é a equipe da Sua Gráfica BH. Um atendente assumiu sua conversa e vai continuar o atendimento por aqui.' })
  }
  function giveBack() {
    updateConv.mutate({ ai_handled: true, attendant_changed_at: new Date().toISOString(), attendant_change_reason: 'Devolvido para a IA' })
    void logAction('devolveu_para_ia', 'Devolvido para a IA')
  }

  function submit() {
    const t = text.trim()
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

  function quoteText() {
    if (!openOrder) return ''
    const lines = openOrder.items.map((i) => `${i.qty}x ${i.description}`)
    return `Orçamento ${openOrder.title}:\n${lines.join('\n')}\nTotal: ${formatBRL(openOrder.fin.total)}\nSe estiver tudo certo, é só confirmar por aqui que eu já envio o link de pagamento.`
  }

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
                rows={mode === 'reply' && text.includes('\n') ? 5 : 2}
                placeholder={mode === 'note' ? 'Nota só para você (o cliente não recebe)' : 'Digite uma mensagem ou / para respostas rápidas'}
                aria-label={mode === 'note' ? 'Nota interna' : 'Mensagem'}
                className={cn('resize-none', mode === 'note' && 'border-brand-yellow bg-brand-yellow/10')}
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
