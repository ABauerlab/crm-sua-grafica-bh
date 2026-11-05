import { Bot } from 'lucide-react'
import { useMemo, useState, type ReactNode } from 'react'
import { CartesianGrid, Legend, Line, LineChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from 'recharts'
import { Button } from '@/components/ui/button'
import { EmptyState, ErrorState } from '@/components/ui/empty-state'
import { Skeleton } from '@/components/ui/skeleton'
import { useFunilIA, useOrcamentosIA } from '@/hooks/laura'
import { formatBRL, formatBRLCompact, formatNumber } from '@/lib/money'
import type { FunilIA } from '@/lib/types'
import { cn } from '@/lib/utils'

const PERIODOS = [
  { dias: 1, label: 'Hoje' },
  { dias: 7, label: '7 dias' },
  { dias: 15, label: '15 dias' },
  { dias: 30, label: '30 dias' },
] as const

const soma = (linhas: FunilIA[], k: keyof FunilIA) => linhas.reduce((s, r) => s + Number(r[k] ?? 0), 0)

/** Média diária dos dias que tiveram rodadas (evita puxar a média para zero em dias sem atividade). */
const mediaDiaria = (linhas: FunilIA[], k: keyof FunilIA) => {
  const comDado = linhas.filter((r) => Number(r[k]) > 0)
  return comDado.length ? comDado.reduce((s, r) => s + Number(r[k]), 0) / comDado.length : 0
}

const segundos = (ms: number) => `${(ms / 1000).toLocaleString('pt-BR', { maximumFractionDigits: 1 })} s`
const porcento = (v: number) => `${v.toLocaleString('pt-BR', { maximumFractionDigits: 1 })}%`
const diaCurto = (iso: string) => {
  const [, m, d] = iso.split('-')
  return `${d}/${m}`
}

function Tile({ label, value, hint, destaque }: { label: string; value: string; hint?: string; destaque?: boolean }) {
  return (
    <div className={cn('rounded-lg border bg-card p-4', destaque && 'border-brand-cyan/50 bg-brand-cyan/5')}>
      <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">{label}</p>
      <p className="mt-1 text-2xl font-black tabular-nums">{value}</p>
      {hint && <p className="mt-1 text-xs text-muted-foreground">{hint}</p>}
    </div>
  )
}

function Secao({ titulo, children }: { titulo: string; children: ReactNode }) {
  return (
    <section className="space-y-3">
      <h2 className="text-sm font-semibold uppercase tracking-wide text-muted-foreground">{titulo}</h2>
      {children}
    </section>
  )
}

export default function Laura() {
  const [dias, setDias] = useState<number>(7)
  const funil = useFunilIA(dias)
  const orcamentos = useOrcamentosIA(dias)

  const linhas = useMemo(() => funil.data ?? [], [funil.data])
  const conversas = soma(linhas, 'conversas_ativas')
  const pagos = soma(linhas, 'pedidos_pagos')
  const faturamento = soma(linhas, 'faturamento_reais')
  const rodadas = soma(linhas, 'total_rodadas_ia')
  const ocupadas = soma(linhas, 'rodadas_ocupadas')
  const erros = soma(linhas, 'rodadas_com_erro')
  const taxaConversao = conversas ? (pagos / conversas) * 100 : 0
  const pct = (n: number) => (rodadas ? (n / rodadas) * 100 : 0)

  const grafico = linhas.map((r) => ({ dia: diaCurto(r.data), recebidas: r.msgs_recebidas, pagos: r.pedidos_pagos }))
  const tabela = [...linhas].reverse()

  return (
    <div className="space-y-6 p-4 md:p-6">
      <header className="flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
        <div>
          <h1 className="flex items-center gap-2 text-2xl font-black tracking-tight">
            <Bot className="h-6 w-6 text-brand-blue" aria-hidden /> Performance da Laura / IA
          </h1>
          <p className="text-sm text-muted-foreground">Conversas, orçamentos, vendas e tempo de resposta do atendimento automático.</p>
        </div>
        <div role="group" aria-label="Período" className="flex flex-wrap gap-2">
          {PERIODOS.map((p) => (
            <Button key={p.dias} size="sm" variant={dias === p.dias ? 'default' : 'outline'} aria-pressed={dias === p.dias} onClick={() => setDias(p.dias)}>
              {p.label}
            </Button>
          ))}
        </div>
      </header>

      {funil.isError ? (
        <ErrorState message="Não foi possível carregar a performance da Laura." onRetry={() => funil.refetch()} />
      ) : funil.isLoading ? (
        <div className="grid grid-cols-2 gap-3 lg:grid-cols-5">
          {Array.from({ length: 5 }).map((_, i) => (
            <Skeleton key={i} className="h-24" />
          ))}
        </div>
      ) : linhas.length === 0 ? (
        <EmptyState icon={Bot} title="Sem atividade no período">Escolha outro período ou aguarde novas conversas.</EmptyState>
      ) : (
        <>
          <Secao titulo="Resultado">
            <div className="grid grid-cols-2 gap-3 lg:grid-cols-5">
              <Tile label="Conversas ativas" value={formatNumber(conversas)} hint="Soma diária de conversas com atividade" />
              <Tile label="Orçamentos gerados" value={formatNumber(orcamentos.data ?? 0)} hint="Criados no período" />
              <Tile label="Pedidos pagos" value={formatNumber(pagos)} hint="Pedidos em pago, produção, pronto ou entregue" />
              <Tile label="Faturamento gerado" value={formatBRL(faturamento)} hint={formatBRLCompact(faturamento)} destaque />
              <Tile label="Taxa de conversão" value={porcento(taxaConversao)} hint="Pedidos pagos sobre conversas ativas" destaque />
            </div>
          </Secao>

          <Secao titulo="Latência e saúde das rodadas">
            <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
              <Tile label="Resposta P50" value={segundos(mediaDiaria(linhas, 'tempo_p50_ms'))} hint="Mediana, média dos dias com atividade" />
              <Tile label="Resposta P95" value={segundos(mediaDiaria(linhas, 'tempo_p95_ms'))} hint="95% das respostas saem antes disso" />
              <Tile label="Rodadas ocupadas" value={porcento(pct(ocupadas))} hint={`${formatNumber(ocupadas)} de ${formatNumber(rodadas)} rodadas`} />
              <Tile label="Rodadas com erro" value={porcento(pct(erros))} hint={`${formatNumber(erros)} de ${formatNumber(rodadas)} rodadas`} />
            </div>
          </Secao>

          <Secao titulo="Mensagens recebidas x vendas pagas">
            <div className="h-72 rounded-lg border bg-card p-3">
              <ResponsiveContainer width="100%" height="100%">
                <LineChart data={grafico} margin={{ top: 8, right: 16, bottom: 0, left: 0 }}>
                  <CartesianGrid strokeDasharray="3 3" stroke="hsl(var(--border))" />
                  <XAxis dataKey="dia" tick={{ fontSize: 12 }} />
                  <YAxis tick={{ fontSize: 12 }} allowDecimals={false} />
                  <Tooltip />
                  <Legend />
                  <Line type="monotone" dataKey="recebidas" name="Mensagens recebidas" stroke="#00A6D6" strokeWidth={2} dot={false} />
                  <Line type="monotone" dataKey="pagos" name="Pedidos pagos" stroke="#E6007E" strokeWidth={2} dot={false} />
                </LineChart>
              </ResponsiveContainer>
            </div>
          </Secao>

          <Secao titulo="Dia a dia">
            <div className="overflow-x-auto rounded-lg border">
              <table className="w-full text-sm">
                <thead className="bg-secondary/60 text-left text-xs uppercase tracking-wide text-muted-foreground">
                  <tr>
                    <th className="px-3 py-2">Dia</th>
                    <th className="px-3 py-2 text-right">Recebidas</th>
                    <th className="px-3 py-2 text-right">Pedidos pagos</th>
                    <th className="px-3 py-2 text-right">Faturamento</th>
                    <th className="px-3 py-2 text-right">Conversão</th>
                    <th className="px-3 py-2 text-right">P50</th>
                    <th className="px-3 py-2 text-right">P95</th>
                    <th className="px-3 py-2 text-right">Erros</th>
                  </tr>
                </thead>
                <tbody>
                  {tabela.map((r) => (
                    <tr key={r.data} className="border-t">
                      <td className="px-3 py-2 font-medium">{diaCurto(r.data)}</td>
                      <td className="px-3 py-2 text-right tabular-nums">{formatNumber(r.msgs_recebidas)}</td>
                      <td className="px-3 py-2 text-right tabular-nums">{formatNumber(r.pedidos_pagos)}</td>
                      <td className="px-3 py-2 text-right tabular-nums">{formatBRL(r.faturamento_reais)}</td>
                      <td className="px-3 py-2 text-right tabular-nums">{porcento(r.taxa_conversao_pct)}</td>
                      <td className="px-3 py-2 text-right tabular-nums">{segundos(r.tempo_p50_ms)}</td>
                      <td className="px-3 py-2 text-right tabular-nums">{segundos(r.tempo_p95_ms)}</td>
                      <td className="px-3 py-2 text-right tabular-nums">{formatNumber(r.rodadas_com_erro)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </Secao>
        </>
      )}
    </div>
  )
}
