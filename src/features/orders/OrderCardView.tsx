import { useDraggable } from '@dnd-kit/core'
import { CSS } from '@dnd-kit/utilities'
import { AlertTriangle, Bot, Clock, MessageSquare, MoreHorizontal, User } from 'lucide-react'
import { Link } from 'react-router-dom'
import { SkuBadge } from '@/components/SkuBadge'
import { StatusPedido } from './StatusPedido'
import { Menu, MenuContent, MenuItem, MenuSeparator, MenuTrigger } from '@/components/ui/menu'
import { formatBRL, formatPct } from '@/lib/money'
import { ORCAMENTO_STATUS } from '@/lib/orcamentos'
import { contactLabel } from '@/lib/format'
import { formatDuration, hoursInStage, ORDER_STAGES, type KanbanSettings, type OrderCard, type OrderStage } from '@/lib/orders'
import { cn } from '@/lib/utils'

export interface CardActions {
  open: (o: OrderCard) => void
  move: (o: OrderCard, to: OrderStage) => void
  markPaid: (o: OrderCard) => void
  addNote: (o: OrderCard) => void
  copyPaymentLink: (o: OrderCard) => void
}

function summary(o: OrderCard): string {
  if (!o.items.length) return o.title
  const first = `${o.items[0].qty}x ${o.items[0].description}`
  return o.items.length > 1 ? `${first} +${o.items.length - 1}` : first
}

export function OrderCardView({
  order,
  settings,
  actions,
  stalled,
  dragging = false,
  draggable = true,
}: {
  order: OrderCard
  settings: KanbanSettings
  actions: CardActions
  stalled: boolean
  dragging?: boolean
  draggable?: boolean
}) {
  const { attributes, listeners, setNodeRef, transform, isDragging } = useDraggable({ id: order.id, disabled: !draggable })
  const ai = order.conversation?.ai_handled
  const unread = order.conversation?.unread_count ?? 0
  const hours = hoursInStage(order)
  const limit = settings.stage_limit_hours[order.stage]
  const margin = order.fin.margin_pct
  const profitBad = order.fin.total > 0 && order.fin.net_profit < 0

  return (
    <article
      ref={setNodeRef}
      style={{ transform: CSS.Translate.toString(transform) }}
      className={cn(
        'group relative rounded-md border bg-card p-3 text-sm shadow-[0_1px_0_rgba(0,0,0,0.04)] transition-shadow',
        (isDragging || dragging) && 'z-30 border-primary shadow-lg',
        isDragging && 'opacity-40',
        stalled && 'border-l-4 border-l-brand-red',
      )}
    >
      <div className="flex items-start justify-between gap-2">
        <button
          type="button"
          {...(draggable ? listeners : {})}
          {...(draggable ? attributes : {})}
          onClick={() => actions.open(order)}
          aria-label={`Pedido ${order.number}, ${contactLabel(order.contact)}. Enter para abrir, Espaço para mover.`}
          className="min-w-0 flex-1 cursor-grab touch-none text-left active:cursor-grabbing"
        >
          <p className="truncate font-bold leading-tight">{contactLabel(order.contact)}</p>
          <p className="mt-0.5 truncate text-xs text-muted-foreground">{summary(order)}</p>
        </button>
        <Menu>
          <MenuTrigger aria-label="Ações do pedido" className="-mr-1 flex h-10 w-10 shrink-0 items-center justify-center rounded-md text-muted-foreground hover:bg-secondary md:h-8 md:w-8">
            <MoreHorizontal className="h-4 w-4" />
          </MenuTrigger>
          <MenuContent align="end">
            <MenuItem onSelect={() => actions.open(order)}>Abrir pedido</MenuItem>
            {order.conversation && (
              <MenuItem asChild>
                <Link to={`/inbox/${order.conversation.id}`}>Abrir conversa</Link>
              </MenuItem>
            )}
            <MenuItem onSelect={() => actions.copyPaymentLink(order)}>Copiar link de pagamento</MenuItem>
            {order.payment_status !== 'aprovado' && <MenuItem onSelect={() => actions.markPaid(order)}>Marcar como pago…</MenuItem>}
            <MenuItem onSelect={() => actions.addNote(order)}>Adicionar nota</MenuItem>
            <MenuItem disabled>Criar tarefa (em breve)</MenuItem>
            <MenuSeparator />
            {ORDER_STAGES.filter((s) => s.value !== order.stage).map((s) => (
              <MenuItem key={s.value} onSelect={() => actions.move(order, s.value)}>
                Mover para {s.label}
              </MenuItem>
            ))}
          </MenuContent>
        </Menu>
      </div>

      {order.items.length > 0 && (
        <div className="mt-1.5 flex flex-wrap gap-1" aria-label="SKUs do pedido">
          {order.items.slice(0, 3).map((i, n) => <SkuBadge key={`${i.code}-${n}`} sku={i.code} />)}
          {order.items.length > 3 && <span className="text-[11px] text-muted-foreground">+{order.items.length - 3}</span>}
        </div>
      )}

      <div className="mt-2 flex items-end justify-between gap-2">
        <div>
          <p className="text-base font-black leading-none tabular">{formatBRL(order.fin.total)}</p>
          <p className={cn('mt-1 text-xs tabular', profitBad ? 'font-semibold text-brand-red' : 'text-muted-foreground')} title="Lucro líquido (depois de custo, impostos e taxa)">
            Lucro {formatBRL(order.fin.net_profit)} · {formatPct(margin)}
          </p>
        </div>
        <div className="flex items-center gap-1">
          {order.orcamento_status && (
            <span className={cn('rounded-sm px-1.5 py-0.5 text-[11px] font-bold', ORCAMENTO_STATUS[order.orcamento_status].chip)} title="Status do orçamento">
              Orç. {ORCAMENTO_STATUS[order.orcamento_status].label.toLowerCase()}
            </span>
          )}
          {unread > 0 && (
            <span className="flex items-center gap-1 rounded-sm bg-brand-magenta px-1.5 py-0.5 text-[11px] font-bold text-white tabular" title={`${unread} mensagem(ns) não lida(s)`}>
              <MessageSquare className="h-3 w-3" aria-hidden /> {unread}
            </span>
          )}
          {order.conversation && (
            <span
              className={cn('flex items-center gap-1 rounded-sm px-1.5 py-0.5 text-[11px] font-bold', ai ? 'bg-brand-blue text-white' : 'bg-ink/10 text-ink')}
              title={ai ? 'Atendimento por IA' : 'Atendimento humano'}
            >
              {ai ? <Bot className="h-3 w-3" aria-hidden /> : <User className="h-3 w-3" aria-hidden />}
              {ai ? 'IA' : 'Humano'}
            </span>
          )}
        </div>
      </div>

      {order.stage === 'producao' && draggable && <StatusPedido order={order} compact />}

      <div className="mt-2 flex items-center justify-between gap-2 border-t pt-2 text-[11px] text-muted-foreground">
        <span className="truncate" title={order.origin_label ?? 'Sem anúncio de origem'}>
          {order.origin_label ? `Anúncio: ${order.origin_label}` : 'Orgânico'}
        </span>
        <span className={cn('flex shrink-0 items-center gap-1 tabular', stalled && 'font-bold text-brand-red')} title={limit > 0 ? `Limite da etapa: ${limit} h` : 'Sem limite'}>
          {stalled ? <AlertTriangle className="h-3 w-3" aria-hidden /> : <Clock className="h-3 w-3" aria-hidden />}
          {formatDuration(hours)}
        </span>
      </div>
    </article>
  )
}
