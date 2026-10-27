import { useEffect, useMemo, useState } from 'react'
import { contactLabel } from '@/lib/format'
import { isStalled, type KanbanSettings, type OrderCard } from '@/lib/orders'

export interface OrderFilters {
  q: string
  period: 'all' | '7d' | '30d' | 'month'
  origin: string
  product: string
  minValue: string
  maxValue: string
  attendant: '' | 'ia' | 'humano'
  unread: boolean
  stalledHours: string
}

export const EMPTY_FILTERS: OrderFilters = {
  q: '',
  period: 'all',
  origin: '',
  product: '',
  minValue: '',
  maxValue: '',
  attendant: '',
  unread: false,
  stalledHours: '',
}

export interface SavedView {
  name: string
  filters: OrderFilters
}

export const PRESET_VIEWS: SavedView[] = [
  { name: 'Todos', filters: EMPTY_FILTERS },
  { name: 'Mensagens não lidas', filters: { ...EMPTY_FILTERS, unread: true } },
  { name: 'Parados há mais de 24h', filters: { ...EMPTY_FILTERS, stalledHours: '24' } },
  { name: 'Últimos 7 dias', filters: { ...EMPTY_FILTERS, period: '7d' } },
]

const STORAGE_KEY = 'sgbh.kanban.views'

export function useSavedViews() {
  const [views, setViews] = useState<SavedView[]>(() => {
    try {
      return JSON.parse(localStorage.getItem(STORAGE_KEY) ?? '[]') as SavedView[]
    } catch {
      return []
    }
  })
  useEffect(() => {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(views))
    } catch {
      /* sem armazenamento */
    }
  }, [views])
  return {
    views,
    save: (name: string, filters: OrderFilters) => setViews((v) => [...v.filter((x) => x.name !== name), { name, filters }]),
    remove: (name: string) => setViews((v) => v.filter((x) => x.name !== name)),
  }
}

function periodStart(p: OrderFilters['period'], now = new Date()): number {
  if (p === '7d') return now.getTime() - 7 * 86_400_000
  if (p === '30d') return now.getTime() - 30 * 86_400_000
  if (p === 'month') return new Date(now.getFullYear(), now.getMonth(), 1).getTime()
  return 0
}

export function filterOrders(orders: OrderCard[], f: OrderFilters, now = Date.now()): OrderCard[] {
  const q = f.q.trim().toLowerCase()
  const digits = q.replace(/\D/g, '')
  const start = periodStart(f.period)
  const min = f.minValue ? Number(f.minValue) : null
  const max = f.maxValue ? Number(f.maxValue) : null
  const product = f.product.trim().toLowerCase()
  return orders.filter((o) => {
    if (start && new Date(o.created_at).getTime() < start) return false
    if (q) {
      const hit =
        contactLabel(o.contact).toLowerCase().includes(q) ||
        o.title.toLowerCase().includes(q) ||
        String(o.number) === q.replace('#', '') ||
        (!!digits && o.contact.wa_id.includes(digits)) ||
        o.items.some((i) => i.description.toLowerCase().includes(q))
      if (!hit) return false
    }
    if (f.origin === '__organico' ? !!o.origin_label || !!o.origin_ad_id : f.origin ? o.origin_label !== f.origin : false) return false
    if (product && !o.items.some((i) => i.description.toLowerCase().includes(product)) && !o.title.toLowerCase().includes(product)) return false
    if (min !== null && o.fin.total < min) return false
    if (max !== null && o.fin.total > max) return false
    if (f.attendant === 'ia' && !o.conversation?.ai_handled) return false
    if (f.attendant === 'humano' && o.conversation?.ai_handled) return false
    if (f.unread && !(o.conversation && o.conversation.unread_count > 0)) return false
    if (f.stalledHours) {
      const h = (now - new Date(o.stage_entered_at).getTime()) / 3_600_000
      if (h < Number(f.stalledHours)) return false
    }
    return true
  })
}

export function useFilteredOrders(orders: OrderCard[] | undefined, f: OrderFilters) {
  return useMemo(() => filterOrders(orders ?? [], f), [orders, f])
}

export const countStalled = (orders: OrderCard[], settings: KanbanSettings) => orders.filter((o) => isStalled(o, settings)).length
