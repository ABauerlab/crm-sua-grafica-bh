import { Bot, PauseCircle, PlayCircle } from 'lucide-react'
import { useState } from 'react'
import { Button } from '@/components/ui/button'
import { Select } from '@/components/ui/select'
import { Skeleton } from '@/components/ui/skeleton'
import { useToast } from '@/components/ui/toast'
import { usePainelAgente } from '@/hooks/etapa7'
import { DEFAULTS, useSaveSetting, useSetting } from '@/hooks/settings'
import { formatBRL } from '@/lib/money'
import { cn } from '@/lib/utils'

function Tile({ label, value, hint, alerta }: { label: string; value: string; hint?: string; alerta?: boolean }) {
  return (
    <div className={cn('rounded-md border bg-card p-3', alerta && 'border-brand-red')}>
      <p className="text-[11px] font-medium uppercase tracking-[0.12em] text-muted-foreground">{label}</p>
      <p className={cn('mt-1 truncate text-2xl font-black leading-none tabular', alerta && 'text-brand-red')}>{value}</p>
      {hint && <p className="mt-1 text-xs text-muted-foreground">{hint}</p>}
    </div>
  )
}
const pct = (a: number, b: number) => (b > 0 ? `${((a / b) * 100).toFixed(0)}%` : '-')
const seg = (s: number) => (s >= 90 ? `${(s / 60).toFixed(1)} min` : `${Math.round(s)} s`)

export default function AgentPanel() {
  const toast = useToast()
  const [dias, setDias] = useState(30)
  const { data, isLoading, error } = usePainelAgente(dias)
  const { data: agentData } = useSetting('agent')
  const salvar = useSaveSetting('agent')
  const agent = agentData ?? DEFAULTS.agent
  const ligada = agent.enabled === true

  function alternar() {
    if (ligada && !window.confirm('Pausar a IA em todas as conversas? Ninguém será respondido automaticamente e os follow-ups ficam parados até você ligar de novo.')) return
    salvar.mutate({ ...agent, enabled: !ligada }, { onSuccess: () => toast('ok', ligada ? 'IA pausada.' : 'IA ligada.'), onError: (e) => toast('error', (e as Error).message) })
  }

  return (
    <div className="space-y-4 p-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex items-center gap-2">
          <Bot className="h-5 w-5" aria-hidden />
          <h2 className="font-black">Agente de IA</h2>
          <Select className="w-44" value={dias} onChange={(e) => setDias(Number(e.target.value))} aria-label="Período">
            <option value={7}>Últimos 7 dias</option><option value={30}>Últimos 30 dias</option><option value={90}>Últimos 90 dias</option>
          </Select>
        </div>
        <Button variant={ligada ? 'outline' : 'default'} onClick={alternar} disabled={salvar.isPending}>
          {ligada ? <PauseCircle className="mr-1 h-4 w-4" aria-hidden /> : <PlayCircle className="mr-1 h-4 w-4" aria-hidden />}
          {ligada ? 'Pausar IA' : 'Ligar IA'}
        </Button>
      </div>
      {error ? <p className="text-sm text-brand-red">Não foi possível carregar o painel do agente.</p> : isLoading || !data ? (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">{[0, 1, 2, 3, 4, 5, 6, 7].map((i) => <Skeleton key={i} className="h-24" />)}</div>
      ) : (
        <>
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <Tile label="Conversas atendidas" value={String(data.conversas_ia)} />
            <Tile label="Orçamentos enviados" value={String(data.orcamentos_enviados)} />
            <Tile label="Pagos vindos do agente" value={String(data.pedidos_pagos_do_agente)} />
            <Tile label="Margem líquida real" value={`${data.margem_liquida_real_pct}%`} hint="média dos pedidos pagos" />
            <Tile label="Custo médio por conversa" value={formatBRL(data.custo_por_conversa)} hint={`${data.tokens_por_conversa.toLocaleString('pt-BR')} tokens (estimativa)`} />
            <Tile label="Custo da IA hoje" value={formatBRL(data.custo_dia)} hint={`teto ${formatBRL(data.teto_custo_dia)}`} alerta={data.custo_dia > data.teto_custo_dia} />
            <Tile label="Templates no mês" value={formatBRL(data.custo_templates_mes)} hint={`${data.templates_enviados_mes} enviados (estimativa)`} />
            <Tile label="Tempo médio de resposta" value={seg(data.tempo_resposta_seg)} />
            <Tile label="Chamadas ao dono" value={String(data.chamadas_ao_dono)} />
            <Tile label="Erros do agente" value={String(data.erros_agente)} alerta={data.erros_agente > 0} />
            <Tile label="Leads frios" value={String(data.leads_frios)} hint="chegaram ao F4 sem fechar" />
            <Tile label="Follow-ups enviados" value={String(Object.values(data.followups).reduce((n, v) => n + v, 0))} hint={Object.entries(data.followups).map(([k, v]) => `${k} ${v}`).join(' · ') || 'nenhum ainda'} />
          </div>

          <section className="rounded-md border p-3">
            <h3 className="font-black">Conversão por etapa</h3>
            <ol className="mt-2 grid gap-2 sm:grid-cols-4">
              {[['Conversas', data.funil.conversas], ['Orçamentos', data.funil.orcamentos], ['Com link de pagamento', data.funil.com_link], ['Pagos', data.funil.pagos]].map(([nome, n], i, arr) => (
                <li key={String(nome)} className="rounded-sm bg-secondary/60 p-2">
                  <p className="text-xs text-muted-foreground">{nome}</p>
                  <p className="text-xl font-black tabular">{n as number}</p>
                  {i > 0 && <p className="text-xs text-muted-foreground">{pct(n as number, arr[i - 1][1] as number)} da etapa anterior</p>}
                </li>
              ))}
            </ol>
          </section>

          <section className="rounded-md border p-3">
            <h3 className="font-black">Condições especiais</h3>
            <div className="mt-2 grid gap-2 sm:grid-cols-4">
              <Tile label="Concedidas" value={String(data.condicoes.concedidas)} />
              <Tile label="Enviadas no follow-up" value={String(data.condicoes.enviadas)} />
              <Tile label="Convertidas" value={String(data.condicoes.convertidas)} hint={pct(data.condicoes.convertidas, data.condicoes.concedidas)} />
              <Tile label="Desconto médio sobre o lucro" value={`${data.condicoes.desconto_medio_sobre_lucro_pct}%`} alerta={data.condicoes.desconto_medio_sobre_lucro_pct > 40} hint="alerta acima de 40%" />
            </div>
          </section>

          <section className="rounded-md border p-3">
            <h3 className="font-black">Erros recentes dos workflows</h3>
            {!data.erros_recentes.length ? <p className="mt-1 text-sm text-muted-foreground">Nenhum erro registrado.</p> : (
              <ul className="mt-2 divide-y text-sm">
                {data.erros_recentes.map((e, i) => (
                  <li key={i} className="py-1.5"><span className="text-xs text-muted-foreground">{new Date(e.quando).toLocaleString('pt-BR')}</span> <b>{e.workflow}</b> · {e.mensagem}</li>
                ))}
              </ul>
            )}
          </section>
        </>
      )}
    </div>
  )
}
