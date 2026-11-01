import { BellRing, Share, SquarePlus, Smartphone } from 'lucide-react'
import { useEffect, useState } from 'react'
import { useAuth } from '@/auth/AuthProvider'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Skeleton } from '@/components/ui/skeleton'
import { Switch } from '@/components/ui/switch'
import { useToast } from '@/components/ui/toast'
import { useAlertas, useAparelhos, useMarcarLidos } from '@/hooks/alertas'
import { DEFAULTS, useSaveSetting, useSetting, type NotificacoesSettings } from '@/hooks/settings'
import { invokeFunction } from '@/lib/api'
import { ativarPush, desativarPush, ehIOS, estadoPush, instalado, type EstadoPush } from '@/lib/push'

const TIPOS: { id: string; nome: string; ajuda: string }[] = [
  { id: 'pedido_pago', nome: 'Pedido pago', ajuda: 'Cliente, valor, lucro líquido e previsão. Sempre na hora.' },
  { id: 'atencao_agente', nome: 'Atenção do agente', ajuda: 'O agente chamou você: reclamação, fora do catálogo, cliente pediu uma pessoa, erro.' },
  { id: 'pagamento_problema', nome: 'Problema no pagamento', ajuda: 'Estorno, contestação ou pagamento fora das regras. O pedido não é alterado.' },
  { id: 'nova_mensagem_humano', nome: 'Nova mensagem em atendimento humano', ajuda: 'Cliente escreveu e ninguém da IA vai responder. Só uma vez a cada 30 minutos por conversa.' },
  { id: 'pagamento_pendente', nome: 'Pagamento pendente há muito tempo', ajuda: 'Link criado e ainda não pago.' },
  { id: 'pedido_sem_arte', nome: 'Pedido pago sem arte', ajuda: 'Pago, mas o cliente ainda não mandou a arte.' },
  { id: 'politica_desconto', nome: 'Desconto fora do padrão', ajuda: 'Cliente que só compra com condição especial ou acumula ofertas sem comprar.' },
  { id: 'resumo', nome: 'Resumo dos avisos de baixa gravidade', ajuda: 'Um aviso só, a cada 2 horas, com tudo que não era urgente.' },
]

const STATUS: Record<string, string> = {
  enviado: 'enviado',
  pendente: 'enviando',
  agrupado: 'no resumo',
  resumido: 'no resumo',
  desligado: 'desligado',
  falhou: 'falhou',
  aguardando_template: 'aguardando aprovação do template',
  indisponivel: 'indisponível',
  sem_aparelho: 'sem aparelho',
}

function Passo({ n, children }: { n: number; children: React.ReactNode }) {
  return (
    <li className="flex gap-3">
      <span className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-ink text-xs font-black text-white">{n}</span>
      <span className="text-sm">{children}</span>
    </li>
  )
}

function Instalacao({ estado }: { estado: EstadoPush }) {
  const ios = ehIOS()
  return (
    <section className="space-y-3 rounded-md border p-4">
      <h3 className="flex items-center gap-2 text-base font-black"><Smartphone className="h-4 w-4" aria-hidden /> Instalar o CRM no celular</h3>
      {instalado() ? (
        <p className="text-sm text-muted-foreground">Você já está usando o CRM instalado. Está tudo certo.</p>
      ) : ios ? (
        <ol className="space-y-2">
          <Passo n={1}>Abra <b>crm.suagraficabh.com.br</b> no <b>Safari</b> (não funciona em outros navegadores para instalar).</Passo>
          <Passo n={2}>Toque em <Share className="inline h-4 w-4" aria-hidden /> <b>Compartilhar</b>, na barra de baixo.</Passo>
          <Passo n={3}>Role e toque em <SquarePlus className="inline h-4 w-4" aria-hidden /> <b>Adicionar à Tela de Início</b> e depois em <b>Adicionar</b>.</Passo>
          <Passo n={4}>Feche o Safari e abra o CRM <b>pelo ícone novo</b> na Tela de Início. Entre com "Continuar conectado" marcado.</Passo>
          <Passo n={5}>Volte aqui (Configurações &gt; Notificações) e toque em <b>Ativar notificações</b>.</Passo>
        </ol>
      ) : (
        <ol className="space-y-2">
          <Passo n={1}>No Chrome ou Edge, abra o menu do navegador e escolha <b>Instalar app</b> (ou <b>Adicionar à tela inicial</b> no Android).</Passo>
          <Passo n={2}>Abra o CRM pelo ícone instalado e toque em <b>Ativar notificações</b> abaixo.</Passo>
        </ol>
      )}
      {estado === 'ios_fora_da_tela_inicio' && (
        <p className="rounded-sm bg-brand-yellow/30 p-2 text-sm font-medium">No iPhone, as notificações só funcionam com o app aberto pelo ícone da Tela de Início (iOS 16.4 ou superior).</p>
      )}
    </section>
  )
}

export default function NotificationsTab() {
  const toast = useToast()
  const { session } = useAuth()
  const { data } = useSetting('notificacoes')
  const save = useSaveSetting('notificacoes')
  const [v, setV] = useState<NotificacoesSettings | null>(null)
  const [estado, setEstado] = useState<EstadoPush>('pedir')
  const [ocupado, setOcupado] = useState(false)
  const [testando, setTestando] = useState(false)
  const aparelhos = useAparelhos()
  const alertas = useAlertas(20)
  const lidos = useMarcarLidos()

  useEffect(() => { if (data && !v) setV({ ...DEFAULTS.notificacoes, ...data, tipos: { ...DEFAULTS.notificacoes.tipos, ...data.tipos } }) }, [data, v])
  useEffect(() => { void estadoPush().then(setEstado) }, [])

  async function ativar() {
    if (!session) return
    setOcupado(true)
    try {
      await ativarPush(session.user.id)
      setEstado(await estadoPush())
      void aparelhos.refetch()
      toast('ok', 'Notificações ativadas neste aparelho. Envie um teste para conferir.')
    } catch (e) {
      toast('error', (e as Error).message)
      setEstado(await estadoPush())
    } finally {
      setOcupado(false)
    }
  }

  async function desativar() {
    setOcupado(true)
    try {
      await desativarPush()
      setEstado(await estadoPush())
      void aparelhos.refetch()
      toast('ok', 'Notificações desativadas neste aparelho.')
    } finally {
      setOcupado(false)
    }
  }

  async function testar() {
    setTestando(true)
    try {
      const r = await invokeFunction<{ push: { aparelhos: number; enviados: number }; whatsapp: { status: string; erro?: string } }>('alertas-enviar', { acao: 'teste' })
      const p = r.push.aparelhos === 0 ? 'nenhum aparelho ativo' : r.push.enviados > 0 ? 'popup enviado' : 'popup recusado pelo aparelho'
      const w = r.whatsapp.status === 'enviado' ? 'WhatsApp enviado' : r.whatsapp.status === 'aguardando_template' ? 'WhatsApp aguardando aprovação do template' : `WhatsApp falhou (${r.whatsapp.erro ?? 'erro'})`
      toast(r.push.enviados > 0 && r.whatsapp.status === 'enviado' ? 'ok' : 'error', `${p}; ${w}.`)
    } catch (e) {
      toast('error', (e as Error).message)
    } finally {
      setTestando(false)
    }
  }

  if (!v) return <Skeleton className="h-64 w-full max-w-3xl" />
  const setTipo = (id: string, campo: 'push' | 'whatsapp', on: boolean) => setV({ ...v, tipos: { ...v.tipos, [id]: { ...v.tipos[id], [campo]: on } } })

  return (
    <div className="max-w-3xl space-y-6">
      <Instalacao estado={estado} />

      <section className="space-y-3 rounded-md border p-4">
        <h3 className="flex items-center gap-2 text-base font-black"><BellRing className="h-4 w-4" aria-hidden /> Este aparelho</h3>
        {estado === 'ativo' ? (
          <p className="text-sm font-medium text-brand-green">Notificações ativas neste aparelho.</p>
        ) : estado === 'negado' ? (
          <p className="text-sm">Bloqueadas no aparelho. No iPhone: <b>Ajustes &gt; Notificações &gt; Sua Gráfica</b> e permita. Depois volte aqui.</p>
        ) : estado === 'sem_suporte' ? (
          <p className="text-sm">Este navegador não suporta notificações. Use o Chrome, o Edge ou o app instalado no iPhone.</p>
        ) : null}
        <div className="flex flex-wrap gap-2">
          {estado !== 'ativo' && (
            <Button onClick={ativar} disabled={ocupado || estado === 'ios_fora_da_tela_inicio' || estado === 'sem_suporte'}>Ativar notificações</Button>
          )}
          {estado === 'ativo' && <Button variant="outline" onClick={desativar} disabled={ocupado}>Desativar neste aparelho</Button>}
          <Button variant="outline" onClick={testar} disabled={testando}>{testando ? 'Enviando...' : 'Enviar notificação de teste'}</Button>
        </div>
        <p className="text-xs text-muted-foreground">O teste vai para os seus aparelhos e para o WhatsApp do dono. Aparelhos ativos: {aparelhos.data?.length ?? 0}{aparelhos.data?.length ? ` (${aparelhos.data.map((a) => a.dispositivo ?? 'aparelho').join(', ')})` : ''}.</p>
      </section>

      <form
        className="space-y-5"
        onSubmit={(e) => { e.preventDefault(); save.mutate(v, { onSuccess: () => toast('ok', 'Preferências de notificação salvas.'), onError: (er) => toast('error', er.message) }) }}
      >
        <section>
          <h3 className="mb-2 text-base font-black">O que avisar</h3>
          <div className="divide-y rounded-md border">
            <div className="hidden grid-cols-[1fr_72px_88px] gap-2 bg-secondary px-3 py-2 text-xs font-bold sm:grid"><span>Tipo</span><span>Popup</span><span>WhatsApp</span></div>
            {TIPOS.map((t) => (
              <div key={t.id} className="grid grid-cols-[1fr_auto_auto] items-center gap-3 px-3 py-3 sm:grid-cols-[1fr_72px_88px]">
                <div><p className="text-sm font-bold">{t.nome}</p><p className="text-xs text-muted-foreground">{t.ajuda}</p></div>
                <label className="flex items-center gap-2 text-xs sm:block"><span className="sm:hidden">Popup</span><Switch checked={v.tipos[t.id]?.push ?? true} onCheckedChange={(on) => setTipo(t.id, 'push', on)} aria-label={`${t.nome}: popup`} /></label>
                <label className="flex items-center gap-2 text-xs sm:block"><span className="sm:hidden">WhatsApp</span><Switch checked={v.tipos[t.id]?.whatsapp ?? true} onCheckedChange={(on) => setTipo(t.id, 'whatsapp', on)} aria-label={`${t.nome}: WhatsApp`} /></label>
              </div>
            ))}
          </div>
        </section>

        <section className="space-y-3">
          <h3 className="text-base font-black">Horário de silêncio</h3>
          <label className="flex items-center gap-2 text-sm"><Switch checked={v.silencio.ativo} onCheckedChange={(on) => setV({ ...v, silencio: { ...v.silencio, ativo: on } })} aria-label="Silêncio ligado" /> Silenciar popups de avisos não urgentes</label>
          <div className="grid max-w-sm gap-4 sm:grid-cols-2">
            <div className="space-y-1.5"><Label htmlFor="sil-i">Começa às</Label><Input id="sil-i" type="time" value={v.silencio.inicio} onChange={(e) => setV({ ...v, silencio: { ...v.silencio, inicio: e.target.value } })} /></div>
            <div className="space-y-1.5"><Label htmlFor="sil-f">Termina às</Label><Input id="sil-f" type="time" value={v.silencio.fim} onChange={(e) => setV({ ...v, silencio: { ...v.silencio, fim: e.target.value } })} /></div>
          </div>
          <p className="text-xs text-muted-foreground">Pedido pago, atenção do agente e problema de pagamento furam o silêncio. O resto vai para o resumo da manhã.</p>
        </section>

        <section className="space-y-3">
          <h3 className="text-base font-black">Quando avisar de atraso</h3>
          <div className="grid max-w-sm gap-4 sm:grid-cols-2">
            <div className="space-y-1.5"><Label htmlFor="lim-p">Pagamento pendente há (horas)</Label><Input id="lim-p" type="number" min="1" value={v.limites.horas_pagamento_pendente} onChange={(e) => setV({ ...v, limites: { ...v.limites, horas_pagamento_pendente: Math.max(1, Number(e.target.value)) } })} className="tabular" /></div>
            <div className="space-y-1.5"><Label htmlFor="lim-a">Pago sem arte há (horas)</Label><Input id="lim-a" type="number" min="1" value={v.limites.horas_sem_arte} onChange={(e) => setV({ ...v, limites: { ...v.limites, horas_sem_arte: Math.max(1, Number(e.target.value)) } })} className="tabular" /></div>
          </div>
        </section>
        <Button type="submit" disabled={save.isPending}>Salvar preferências</Button>
      </form>

      <section>
        <div className="mb-2 flex items-center justify-between gap-2">
          <h3 className="text-base font-black">Últimos avisos</h3>
          <Button size="sm" variant="outline" onClick={() => lidos.mutate(undefined)} disabled={lidos.isPending}>Marcar tudo como lido</Button>
        </div>
        {alertas.isLoading ? <Skeleton className="h-24 w-full" /> : (alertas.data ?? []).length === 0 ? (
          <p className="rounded-md border border-dashed p-4 text-sm text-muted-foreground">Nenhum aviso ainda. Quando um pedido for pago ou o agente precisar de você, aparece aqui com o status de cada canal.</p>
        ) : (
          <ul className="divide-y rounded-md border">
            {(alertas.data ?? []).map((a) => (
              <li key={a.id} className={`px-3 py-2 text-sm ${a.lido_em ? 'text-muted-foreground' : ''}`}>
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <span className="font-bold">{a.gravidade === 'alta' ? 'Alta' : 'Baixa'} · {a.dados?.cliente ?? '-'}</span>
                  <time className="text-xs text-muted-foreground">{new Date(a.criado_em).toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' })}</time>
                </div>
                <p>{a.motivo}</p>
                <p className="text-xs text-muted-foreground">Popup: {STATUS[a.status_push ?? ''] ?? '-'} · WhatsApp: {STATUS[a.status_whatsapp ?? ''] ?? '-'}</p>
              </li>
            ))}
          </ul>
        )}
      </section>
    </div>
  )
}
