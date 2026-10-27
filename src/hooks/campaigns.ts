import { useQuery } from '@tanstack/react-query'
import { groupCampaigns, metrics, type ManualSpend, type Metrics } from '@/lib/campaigns'
import { supabase } from '@/lib/supabase'
import type { AdPerformance } from '@/lib/types'

export const isoDay = (d: Date) => new Date(d.getTime() - d.getTimezoneOffset() * 60_000).toISOString().slice(0, 10)

/** Totais de campanhas no período (últimos `days` dias): usado pelo Painel. */
export function useAdTotals(days: number, enabled = true) {
  const to = new Date()
  const from = new Date(to.getTime() - (days - 1) * 86_400_000)
  const f = isoDay(from)
  const t = isoDay(to)
  return useQuery({
    queryKey: ['ad-totals', f, t],
    enabled,
    queryFn: async (): Promise<Metrics> => {
      const [perf, manual] = await Promise.all([
        supabase.rpc('ad_performance', { p_from: f, p_to: t }),
        supabase.from('ad_manual_spend').select('*').gte('day', f).lte('day', t),
      ])
      if (perf.error) throw new Error(perf.error.message)
      const rows = (perf.data as Record<string, unknown>[]).map((r) => ({
        ...r,
        spend: Number(r.spend),
        impressions: Number(r.impressions),
        clicks: Number(r.clicks),
        meta_conversations: Number(r.meta_conversations),
        conversations: Number(r.conversations),
        quotes: Number(r.quotes),
        paid_orders: Number(r.paid_orders),
        revenue: Number(r.revenue),
        net_profit: Number(r.net_profit),
      })) as AdPerformance[]
      const manualRows = ((manual.data ?? []) as ManualSpend[]).map((m) => ({ ...m, amount: Number(m.amount) }))
      const g = groupCampaigns(rows, manualRows)
      return metrics(
        g.reduce(
          (a, c) => ({
            spend: a.spend + c.m.spend,
            conversations: a.conversations + c.m.conversations,
            quotes: a.quotes + c.m.quotes,
            paid_orders: a.paid_orders + c.m.paid,
            revenue: a.revenue + c.m.revenue,
            net_profit: a.net_profit + c.m.profit,
            impressions: a.impressions + c.m.impressions,
            clicks: a.clicks + c.m.clicks,
          }),
          { spend: 0, conversations: 0, quotes: 0, paid_orders: 0, revenue: 0, net_profit: 0, impressions: 0, clicks: 0 },
        ),
      )
    },
  })
}
