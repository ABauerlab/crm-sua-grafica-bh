import { RefreshCw } from 'lucide-react'
import { useEffect, useState } from 'react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Skeleton } from '@/components/ui/skeleton'
import { Switch } from '@/components/ui/switch'
import { useToast } from '@/components/ui/toast'
import {
  useConfig, useDispararRecompra, useFollowupFila, useFollowupRegras, useRecompraLista, useSalvarConfig, useSalvarRegra,
  type FollowupCfg, type FollowupRegra, type ObservabilidadeCfg,
} from '@/hooks/etapa7'
import { cn } from '@/lib/utils'

const quando = (iso: string | null) => (iso ? new Date(iso).toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' }) : '-')
const STATUS: Record<string, string> = { pendente: 'na fila', reservado: 'enviando', enviado: 'enviado', cancelado: 'cancelado', pulado: 'pulado', erro: 'erro' }
const MOTIVO: Record<string, string> = {
  optout: 'pediu para parar', pago: 'já pagou', modo_humano: 'em atendimento humano', orcamento_encerrado: 'orçamento encerrado', orcamento_vencido: 'orçamento vencido',
  cliente_respondeu: 'cliente respondeu', janela_fechada: 'janela fechada', sem_optin_marketing: 'sem consentimento de promoções', link_inativo: 'link vencido',
  cadencia_encerrada: 'cadência encerrada', adiado: 'adiado (horário ou limite diário)', recomprou: 'já recomprou', disparo_manual: 'disparo manual',
}
const horas = (min: number) => (min % 60 === 0 ? `${min / 60} h` : `${min} min`)

function Regra({ r }: { r: FollowupRegra }) {
  const toast = useToast()
  const salvar = useSalvarRegra()
  const [h, setH] = useState(String(r.atraso_minutos / 60))
  const [min, setMin] = useState(String(r.hora_min))
  const [max, setMax] = useState(String(r.hora_max))
  useEffect(() => { setH(String(r.atraso_minutos / 60)); setMin(String(r.hora_min)); setMax(String(r.hora_max)) }, [r])
  function gravar(ativo = r.ativo) {
    const atraso = Math.round(Number(h.replace(',', '.')) * 60)
    if (!Number.isFinite(atraso) || atraso < 0) return toast('error', 'Informe o prazo em horas, por exemplo 2 ou 0,5.')
    const a = Number(min), b = Number(max)
    if (!(a >= 0 && b <= 24 && a < b)) return toast('error', 'O horário precisa ser algo como 8 e 20.')
    salvar.mutate({ codigo: r.codigo, atraso_minutos: atraso, hora_min: a, hora_max: b, ativo }, { onSuccess: () => toast('ok', `${r.codigo} salvo.`), onError: (e) => toast('error', (e as Error).message) })
  }
  return (
    <tr className="border-b align-middle">
      <td className="px-2 py-2 font-mono text-xs font-bold">{r.codigo}</td>
      <td className="px-2 py-2 text-xs">{r.descricao}{r.gatilho_condicao && <span className="ml-1 rounded-sm bg-brand-yellow/30 px-1 font-bold">condição {r.gatilho_condicao}</span>}</td>
      <td className="px-2 py-2"><Input aria-label={`Prazo de ${r.codigo} em horas`} className="h-9 w-20" value={h} onChange={(e) => setH(e.target.value)} /></td>
      <td className="px-2 py-2"><span className="flex items-center gap-1"><Input aria-label="Hora inicial" className="h-9 w-14" value={min} onChange={(e) => setMin(e.target.value)} />às<Input aria-label="Hora final" className="h-9 w-14" value={max} onChange={(e) => setMax(e.target.value)} /></span></td>
      <td className="px-2 py-2"><Switch checked={r.ativo} onCheckedChange={(v) => gravar(v)} aria-label={`${r.codigo} ligado`} /></td>
      <td className="px-2 py-2"><Button size="sm" variant="outline" disabled={salvar.isPending} onClick={() => gravar()}>Salvar</Button></td>
    </tr>
  )
}

export default function FollowupsTab() {
  const toast = useToast()
  const { data: regras, isLoading } = useFollowupRegras()
  const { data: cfg } = useConfig<FollowupCfg>('followup', { max_por_dia: 1, exigir_optin_marketing: true, tentativas_max: 3 })
  const { data: obs } = useConfig<ObservabilidadeCfg>('observabilidade', { teto_custo_dia_brl: 15, custo_template_marketing_brl: 0.35, custo_template_utilidade_brl: 0.04 })
  const salvarCfg = useSalvarConfig()
  const { data: fila, refetch } = useFollowupFila(40)
  const { data: recompra } = useRecompraLista()
  const disparar = useDispararRecompra()
  const [teto, setTeto] = useState('')
  useEffect(() => { if (obs) setTeto(String(obs.teto_custo_dia_brl)) }, [obs])

  return (
    <div className="space-y-6 p-4">
      <section>
        <h2 className="font-black">Cadência de follow-up</h2>
        <p className="mb-2 text-xs text-muted-foreground">Prazos contados a partir do envio do orçamento (F1 a F4), do link de pagamento (PAG) ou da entrega (pós-venda e recompra). Toda condição especial vem do banco; aqui você só ajusta o ritmo.</p>
        {isLoading ? <Skeleton className="h-40" /> : (
          <div className="overflow-x-auto">
            <table className="w-full min-w-[760px] text-sm">
              <thead className="text-left text-xs uppercase tracking-wide text-muted-foreground"><tr className="border-b"><th className="px-2 py-1">Passo</th><th className="px-2 py-1">O que faz</th><th className="px-2 py-1">Depois de (horas)</th><th className="px-2 py-1">Janela de envio</th><th className="px-2 py-1">Ligado</th><th /></tr></thead>
              <tbody>{(regras ?? []).map((r) => <Regra key={r.codigo} r={r} />)}</tbody>
            </table>
          </div>
        )}
      </section>

      <section className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        <div className="rounded-md border p-3">
          <p className="text-sm font-bold">Mensagens proativas por dia, por contato</p>
          <Input className="mt-2 w-24" aria-label="Máximo por dia" defaultValue={cfg?.max_por_dia ?? 1} key={`m${cfg?.max_por_dia}`}
            onBlur={(e) => { const v = Number(e.target.value); if (v >= 1 && v <= 3) salvarCfg.mutate({ key: 'followup', value: { max_por_dia: v } }, { onSuccess: () => toast('ok', 'Salvo.') }) }} />
          <p className="mt-1 text-xs text-muted-foreground">Padrão 1. Sempre entre as horas da janela de cada passo.</p>
        </div>
        <div className="rounded-md border p-3">
          <p className="text-sm font-bold">Promoções só para quem aceitou</p>
          <div className="mt-2 flex items-center gap-2">
            <Switch checked={cfg?.exigir_optin_marketing !== false} aria-label="Exigir consentimento para templates de promoção"
              onCheckedChange={(v) => salvarCfg.mutate({ key: 'followup', value: { exigir_optin_marketing: v } }, { onSuccess: () => toast('ok', 'Salvo.') })} />
            <span className="text-sm">{cfg?.exigir_optin_marketing !== false ? 'Ligado (recomendado)' : 'Desligado'}</span>
          </div>
          <p className="mt-1 text-xs text-muted-foreground">Fora das 24 h, os templates de F2, F3 e F4 são de marketing. Desligar aumenta as vendas, mas arrisca a qualidade do número na Meta.</p>
        </div>
        <div className="rounded-md border p-3">
          <p className="text-sm font-bold">Teto de custo da IA por dia (R$)</p>
          <div className="mt-2 flex gap-2">
            <Input className="w-24" aria-label="Teto diário" value={teto} onChange={(e) => setTeto(e.target.value)} />
            <Button size="sm" variant="outline" onClick={() => { const v = Number(teto.replace(',', '.')); if (v > 0) salvarCfg.mutate({ key: 'observabilidade', value: { teto_custo_dia_brl: v } }, { onSuccess: () => toast('ok', 'Teto salvo.') }) }}>Salvar</Button>
          </div>
          <p className="mt-1 text-xs text-muted-foreground">Ao passar, você recebe um alerta de gravidade alta.</p>
        </div>
      </section>

      <section>
        <h2 className="font-black">Recompra</h2>
        <p className="mb-2 text-xs text-muted-foreground">Lembretes por produto depois da entrega, um por ciclo. O botão envia agora (dentro do horário permitido).</p>
        {!recompra?.length ? <p className="text-sm text-muted-foreground">Ainda não há pedidos entregues com recompra agendada.</p> : (
          <ul className="divide-y rounded-md border text-sm">
            {recompra.map((l) => (
              <li key={l.fila_id} className="flex flex-wrap items-center gap-2 px-3 py-2">
                <span className="min-w-0 flex-1"><b>{l.contato}</b> · {l.pedido} · {l.produto ?? l.regra}</span>
                <span className="text-xs text-muted-foreground">{l.status === 'enviado' ? `enviado ${quando(l.enviado_em)}` : `previsto ${quando(l.quando)}`}{l.optout && ' · pediu para parar'}</span>
                <Button size="sm" variant="outline" disabled={!l.pode_disparar || disparar.isPending}
                  onClick={() => disparar.mutate(l.fila_id, { onSuccess: () => toast('ok', 'Recompra agendada para o próximo horário permitido.'), onError: (e) => toast('error', (e as Error).message) })}>Disparar agora</Button>
              </li>
            ))}
          </ul>
        )}
      </section>

      <section>
        <div className="flex items-center justify-between"><h2 className="font-black">Fila e histórico</h2><Button size="sm" variant="ghost" onClick={() => refetch()}><RefreshCw className="mr-1 h-3.5 w-3.5" aria-hidden /> Atualizar</Button></div>
        {!fila?.length ? <p className="mt-2 text-sm text-muted-foreground">Nada na fila ainda.</p> : (
          <div className="mt-2 overflow-x-auto">
            <table className="w-full min-w-[640px] text-sm">
              <thead className="text-left text-xs uppercase tracking-wide text-muted-foreground"><tr className="border-b"><th className="px-2 py-1">Passo</th><th className="px-2 py-1">Cliente</th><th className="px-2 py-1">Quando</th><th className="px-2 py-1">Situação</th></tr></thead>
              <tbody>
                {fila.map((f) => (
                  <tr key={f.id} className="border-b">
                    <td className="px-2 py-1.5 font-mono text-xs font-bold">{f.regra_codigo}</td>
                    <td className="px-2 py-1.5">{f.contact?.name ?? f.contact?.wa_id ?? '-'}</td>
                    <td className="px-2 py-1.5 tabular">{quando(f.enviado_em ?? f.agendado_para)}</td>
                    <td className="px-2 py-1.5"><span className={cn('rounded-sm px-1.5 py-0.5 text-[11px] font-bold', f.status === 'enviado' ? 'bg-brand-green/15 text-brand-green' : f.status === 'erro' ? 'bg-brand-red/10 text-brand-red' : 'bg-secondary')}>{STATUS[f.status] ?? f.status}</span>{f.motivo && <span className="ml-1 text-xs text-muted-foreground">{MOTIVO[f.motivo] ?? f.motivo}</span>}{f.via && <span className="ml-1 text-xs text-muted-foreground">({f.via === 'template' ? 'template' : f.via === 'simulado' ? 'teste' : 'mensagem livre'})</span>}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>
      <p className="text-xs text-muted-foreground">Lead frio: contatos que chegaram ao F4 sem responder ({horas(7200)} depois do orçamento) ficam marcados e a cadência para.</p>
    </div>
  )
}
