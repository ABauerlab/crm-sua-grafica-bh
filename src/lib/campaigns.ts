import type { AdPerformance } from './types'

export interface ManualSpend {
  id: string
  day: string
  campaign_name: string
  amount: number
  note: string | null
}

export interface Metrics {
  spend: number
  conversations: number
  quotes: number
  paid: number
  revenue: number
  profit: number
  impressions: number
  clicks: number
  /** custo por conversa (null quando não há conversas) */
  cpc: number | null
  /** custo por venda */
  cps: number | null
  /** lucro líquido depois de descontar o investimento */
  profitAfterAds: number
  roas: number | null
  quoteRate: number | null
  paidRate: number | null
}

export function metrics(r: { spend: number; conversations: number; quotes: number; paid_orders: number; revenue: number; net_profit: number; impressions?: number; clicks?: number }): Metrics {
  const div = (a: number, b: number) => (b > 0 ? a / b : null)
  return {
    spend: r.spend,
    conversations: r.conversations,
    quotes: r.quotes,
    paid: r.paid_orders,
    revenue: r.revenue,
    profit: r.net_profit,
    impressions: r.impressions ?? 0,
    clicks: r.clicks ?? 0,
    cpc: div(r.spend, r.conversations),
    cps: div(r.spend, r.paid_orders),
    profitAfterAds: Math.round((r.net_profit - r.spend) * 100) / 100,
    roas: div(r.revenue, r.spend),
    quoteRate: div(r.quotes * 100, r.conversations),
    paidRate: div(r.paid_orders * 100, r.conversations),
  }
}

export interface CampaignRow {
  key: string
  name: string
  ads: AdPerformance[]
  manual: number
  m: Metrics
}

/** Agrupa anúncios por campanha e soma o investimento manual de mesmo nome. */
export function groupCampaigns(rows: AdPerformance[], manual: ManualSpend[]): CampaignRow[] {
  const byCampaign = new Map<string, AdPerformance[]>()
  for (const r of rows) {
    const k = r.campaign_id ?? r.campaign_name ?? 'sem-campanha'
    byCampaign.set(k, [...(byCampaign.get(k) ?? []), r])
  }
  const manualBy = new Map<string, number>()
  for (const s of manual) manualBy.set(s.campaign_name.trim().toLowerCase(), (manualBy.get(s.campaign_name.trim().toLowerCase()) ?? 0) + s.amount)

  const out: CampaignRow[] = []
  const used = new Set<string>()
  for (const [key, ads] of byCampaign) {
    const name = ads[0].campaign_name ?? 'Anúncios sem campanha'
    const manualSpend = manualBy.get(name.trim().toLowerCase()) ?? 0
    used.add(name.trim().toLowerCase())
    const sum = ads.reduce(
      (a, r) => ({
        spend: a.spend + r.spend,
        conversations: a.conversations + r.conversations,
        quotes: a.quotes + r.quotes,
        paid_orders: a.paid_orders + r.paid_orders,
        revenue: a.revenue + r.revenue,
        net_profit: a.net_profit + r.net_profit,
        impressions: a.impressions + r.impressions,
        clicks: a.clicks + r.clicks,
      }),
      { spend: 0, conversations: 0, quotes: 0, paid_orders: 0, revenue: 0, net_profit: 0, impressions: 0, clicks: 0 },
    )
    out.push({ key, name, ads, manual: manualSpend, m: metrics({ ...sum, spend: sum.spend + manualSpend }) })
  }
  for (const [name, amount] of manualBy) {
    if (used.has(name)) continue
    out.push({ key: `manual-${name}`, name: manual.find((s) => s.campaign_name.trim().toLowerCase() === name)!.campaign_name, ads: [], manual: amount, m: metrics({ spend: amount, conversations: 0, quotes: 0, paid_orders: 0, revenue: 0, net_profit: 0 }) })
  }
  return out.sort((a, b) => b.m.spend - a.m.spend)
}

export type GoalState = 'good' | 'bad' | 'none'

/** Compara uma métrica com a meta. Para custos, menor é melhor; para ROAS, maior é melhor. */
export function goalState(kind: 'cost' | 'roas', value: number | null, goal: number): GoalState {
  if (value === null || !(goal > 0)) return 'none'
  return kind === 'cost' ? (value <= goal ? 'good' : 'bad') : value >= goal ? 'good' : 'bad'
}
