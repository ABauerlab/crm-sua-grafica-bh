import { corsHeaders, json, requireEnv, requireStaff, serviceClient } from '../_shared/http.ts'

const GRAPH = 'https://graph.facebook.com/v21.0'
const CONVERSATION_ACTION = 'onsite_conversion.messaging_conversation_started_7d'

interface MetaAd {
  id: string
  name?: string
  effective_status?: string
  adset?: { id: string; name?: string }
  campaign?: { id: string; name?: string }
}

interface MetaInsight {
  ad_id: string
  date_start: string
  spend?: string
  impressions?: string
  clicks?: string
  actions?: { action_type: string; value: string }[]
}

async function pageAll<T>(url: string, token: string): Promise<T[]> {
  const out: T[] = []
  let next: string | null = url
  while (next) {
    const res: Response = await fetch(next, { headers: { Authorization: `Bearer ${token}` } })
    const body = await res.json().catch(() => ({}))
    if (!res.ok) throw new Error(body?.error?.message ?? `HTTP ${res.status}`)
    out.push(...(body.data ?? []))
    next = body.paging?.next ?? null
  }
  return out
}

const isoDay = (d: Date) => d.toISOString().slice(0, 10)

// Traz estrutura (campanha, conjunto, anúncio) e gasto diário por anúncio da conta de anúncios da Meta.
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)

  const db = serviceClient()
  if (!(await requireStaff(req, db))) return json({ error: 'Não autorizado.' }, 401)

  const env = requireEnv('META_ADS_TOKEN', 'META_AD_ACCOUNT_ID')
  if (!env) {
    return json({ error: 'A conexão com a conta de anúncios ainda não foi configurada. Cadastre META_ADS_TOKEN e META_AD_ACCOUNT_ID nos segredos das Edge Functions.' }, 500)
  }

  let days = 30
  try {
    const body = await req.json()
    if (Number.isFinite(body?.days)) days = Math.min(365, Math.max(1, Math.floor(body.days)))
  } catch {
    /* sem corpo: usa o padrão */
  }

  const account = `act_${env.META_AD_ACCOUNT_ID.replace(/^act_/, '')}`
  const until = new Date()
  const since = new Date(until.getTime() - days * 86_400_000)

  try {
    const ads = await pageAll<MetaAd>(
      `${GRAPH}/${account}/ads?fields=id,name,effective_status,adset{id,name},campaign{id,name}&limit=500`,
      env.META_ADS_TOKEN,
    )
    const now = new Date().toISOString()
    if (ads.length) {
      const { error } = await db.from('ad_entities').upsert(
        ads.map((a) => ({
          ad_id: a.id,
          ad_name: a.name ?? null,
          adset_id: a.adset?.id ?? null,
          adset_name: a.adset?.name ?? null,
          campaign_id: a.campaign?.id ?? null,
          campaign_name: a.campaign?.name ?? null,
          status: a.effective_status ?? null,
          updated_at: now,
        })),
        { onConflict: 'ad_id' },
      )
      if (error) throw new Error(error.message)
    }

    const range = encodeURIComponent(JSON.stringify({ since: isoDay(since), until: isoDay(until) }))
    const insights = await pageAll<MetaInsight>(
      `${GRAPH}/${account}/insights?level=ad&fields=ad_id,spend,impressions,clicks,actions&time_increment=1&time_range=${range}&limit=500`,
      env.META_ADS_TOKEN,
    )
    if (insights.length) {
      const rows = insights.map((i) => ({
        ad_id: i.ad_id,
        day: i.date_start,
        spend: Number(i.spend ?? 0),
        impressions: Number(i.impressions ?? 0),
        clicks: Number(i.clicks ?? 0),
        meta_conversations: Number(i.actions?.find((a) => a.action_type === CONVERSATION_ACTION)?.value ?? 0),
      }))
      for (let n = 0; n < rows.length; n += 500) {
        const { error } = await db.from('ad_daily').upsert(rows.slice(n, n + 500), { onConflict: 'ad_id,day' })
        if (error) throw new Error(error.message)
      }
    }

    return json({ ok: true, ads: ads.length, days_with_data: insights.length })
  } catch (err) {
    console.error('Falha ao sincronizar anúncios:', err instanceof Error ? err.message : 'erro desconhecido')
    return json({ error: `A Meta recusou a consulta: ${err instanceof Error ? err.message : 'erro desconhecido'}` }, 502)
  }
})
