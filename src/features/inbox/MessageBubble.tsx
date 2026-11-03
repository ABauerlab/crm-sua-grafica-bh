import { ChevronDown, Copy, CornerUpLeft, Forward, Info, Pencil, RotateCcw, SmilePlus, Trash2 } from 'lucide-react'
import { MessageStatusIcon } from '@/components/MessageStatusIcon'
import { Menu, MenuContent, MenuItem, MenuSeparator, MenuTrigger } from '@/components/ui/menu'
import { formatTime } from '@/lib/format'
import { ehNaoSuportada, REACOES, resumo, textoVisivel } from '@/lib/messages'
import type { Message } from '@/lib/types'
import { cn } from '@/lib/utils'
import { ContactsView, LocationLink, MediaView } from './MediaView'

interface Props {
  m: Message
  /** todas as mensagens carregadas (para achar a mensagem respondida) */
  todas: Message[]
  reacoes?: { in?: string; out?: string }
  podeReagir: boolean
  onResponder: (m: Message) => void
  onReagir: (m: Message, emoji: string) => void
  onApagar: (m: Message) => void
  onRestaurar: (m: Message) => void
  onDados: (m: Message) => void
  onIrPara: (waId: string) => void
}

/** Uma mensagem da conversa: citação da resposta, conteúdo por tipo, reações e o menu de ações (como no WhatsApp). */
export function MessageBubble({ m, todas, reacoes, podeReagir, onResponder, onReagir, onApagar, onRestaurar, onDados, onIrPara }: Props) {
  const out = m.direction === 'out'
  const apagada = !!m.deleted_at
  const alvo = m.reply_to_wa_id ? todas.find((x) => x.wa_message_id === m.reply_to_wa_id) : undefined
  const texto = textoVisivel(m)
  const naoSuportada = ehNaoSuportada(m)

  const copiar = () => {
    void navigator.clipboard?.writeText(texto || resumo(m))
  }

  return (
    <div id={m.wa_message_id ? `msg-${m.wa_message_id}` : undefined} className={cn('group flex', out ? 'justify-end' : 'justify-start')}>
      <div className={cn('relative max-w-[80%] rounded-lg px-3 py-2 text-sm shadow-sm', out ? 'bg-brand-cyan/20' : 'bg-card', m.status === 'failed' && 'ring-1 ring-destructive', apagada && 'opacity-60', reacoes && (reacoes.in || reacoes.out) && 'mb-3')}>
        {!apagada && (
          <Menu>
            <MenuTrigger
              aria-label="Ações da mensagem"
              className="absolute right-1 top-1 hidden h-6 w-6 items-center justify-center rounded-full bg-background/80 text-muted-foreground shadow-sm hover:text-foreground group-hover:flex focus-visible:flex data-[state=open]:flex"
            >
              <ChevronDown className="h-4 w-4" />
            </MenuTrigger>
            <MenuContent align={out ? 'end' : 'start'}>
              {podeReagir && !out && (
                <div className="flex gap-1 px-2 py-1" role="group" aria-label="Reagir">
                  {REACOES.map((e) => (
                    <button key={e} className="flex h-8 w-8 items-center justify-center rounded-full text-lg hover:bg-secondary" onClick={() => onReagir(m, e)} aria-label={`Reagir com ${e}`}>
                      {e}
                    </button>
                  ))}
                </div>
              )}
              {podeReagir && !out && <MenuSeparator />}
              <MenuItem disabled={!m.wa_message_id} onSelect={() => onResponder(m)}><CornerUpLeft className="h-4 w-4" aria-hidden /> Responder</MenuItem>
              <MenuItem disabled={!podeReagir || !m.wa_message_id || m.direction === 'out'} onSelect={() => onReagir(m, reacoes?.out ? '' : '👍')}><SmilePlus className="h-4 w-4" aria-hidden /> {reacoes?.out ? 'Remover minha reação' : 'Reagir com 👍'}</MenuItem>
              {out && <MenuItem disabled title="A API oficial do WhatsApp não permite editar uma mensagem já enviada. Responda a ela com a correção."><Pencil className="h-4 w-4" aria-hidden /> Editar (indisponível no WhatsApp Business)</MenuItem>}
              <MenuItem onSelect={copiar}><Copy className="h-4 w-4" aria-hidden /> Copiar</MenuItem>
              <MenuItem onSelect={() => onDados(m)}><Info className="h-4 w-4" aria-hidden /> Dados da mensagem</MenuItem>
              <MenuSeparator />
              <MenuItem className="text-destructive" onSelect={() => onApagar(m)}><Trash2 className="h-4 w-4" aria-hidden /> Apagar no CRM</MenuItem>
            </MenuContent>
          </Menu>
        )}

        {apagada ? (
          <p className="flex items-center gap-2 italic text-muted-foreground">
            <Trash2 className="h-3.5 w-3.5" aria-hidden /> Mensagem apagada no CRM (o cliente ainda vê)
            <button className="inline-flex items-center gap-1 not-italic underline" onClick={() => onRestaurar(m)}><RotateCcw className="h-3 w-3" aria-hidden /> Restaurar</button>
          </p>
        ) : (
          <>
            {m.forwarded && <p className="mb-0.5 flex items-center gap-1 text-[11px] italic text-muted-foreground"><Forward className="h-3 w-3" aria-hidden /> Encaminhada</p>}
            {m.reply_to_wa_id && (
              <button
                type="button"
                onClick={() => alvo?.wa_message_id && onIrPara(alvo.wa_message_id)}
                className="mb-1 block w-full rounded-md border-l-4 border-brand-blue bg-background/70 px-2 py-1 text-left text-xs"
              >
                <span className="block font-bold text-brand-blue">{alvo ? (alvo.direction === 'out' ? 'Você' : 'Cliente') : 'Mensagem anterior'}</span>
                <span className="line-clamp-2 text-muted-foreground">{alvo ? resumo(alvo) : 'Mensagem fora do trecho carregado'}</span>
              </button>
            )}
            {m.type === 'template' && <p className="mb-0.5 text-[11px] font-medium text-muted-foreground">Template: {m.template_name}</p>}
            <MediaView message={m} />
            {m.type === 'contacts' && <ContactsView message={m} />}
            {m.type === 'location' && <LocationLink body={m.body ?? ''} />}
            {naoSuportada ? (
              <div className="rounded-md border border-dashed border-brand-yellow bg-brand-yellow/20 px-2 py-1.5 text-xs">
                <p className="font-bold">Mensagem não suportada pelo WhatsApp Business</p>
                <p className="text-muted-foreground">A API oficial não repassa alguns tipos (como mídia de visualização única, enquete ou evento). Peça para o cliente reenviar de outra forma, por exemplo como arquivo ou foto normal.</p>
              </div>
            ) : (
              texto && <p className={cn('whitespace-pre-wrap break-words', !['text', 'template', 'image', 'video', 'audio', 'sticker', 'document'].includes(m.type) && m.type !== 'location' && 'italic text-muted-foreground')}>{m.type === 'location' ? texto.replace(/https?:\/\/\S+/, '').trim() : texto}</p>
            )}
          </>
        )}
        <div className="mt-1 flex items-center justify-end gap-1 text-[11px] text-muted-foreground tabular">
          {formatTime(m.created_at)}
          {out && <MessageStatusIcon status={m.status} error={m.error} />}
        </div>
        {m.status === 'failed' && m.error && <p className="mt-1 text-[11px] text-destructive">Falha no envio: {m.error}</p>}
        {reacoes && (reacoes.in || reacoes.out) && (
          <span className={cn('absolute -bottom-3 flex gap-0.5 rounded-full border bg-background px-1.5 py-0.5 text-sm shadow-sm', out ? 'right-2' : 'left-2')} aria-label="Reações">
            {reacoes.in}
            {reacoes.out}
          </span>
        )}
      </div>
    </div>
  )
}
