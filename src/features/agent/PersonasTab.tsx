import { useEffect, useState } from 'react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Skeleton } from '@/components/ui/skeleton'
import { Switch } from '@/components/ui/switch'
import { Textarea } from '@/components/ui/textarea'
import { useToast } from '@/components/ui/toast'
import { useConfig, useSalvarConfig } from '@/hooks/etapa7'

interface Personas { vendas: string; pos_pagamento: string; artigo_vendas: string; artigo_pos_pagamento: string; pos_pagamento_automatico: boolean }
interface Politica { troca_prazo_dias_uteis: number; resumo_pdf: string; descricao_link: string; aceite_arte: string }
interface Parcelamento { sem_juros_ate: number; maximo_link: number }
interface Arte { formato_ideal: string; horas_novo_alerta: number }
interface Cupom { ativo: boolean; percentual: number; teto_reais: number; validade_dias: number }

const P0: Personas = { vendas: 'Laura', pos_pagamento: 'João Victor', artigo_vendas: 'a', artigo_pos_pagamento: 'o', pos_pagamento_automatico: true }
const POL0: Politica = { troca_prazo_dias_uteis: 2, resumo_pdf: '', descricao_link: '', aceite_arte: '' }
const PAR0: Parcelamento = { sem_juros_ate: 2, maximo_link: 12 }
const A0: Arte = { formato_ideal: 'PDF em alta qualidade', horas_novo_alerta: 4 }
const C0: Cupom = { ativo: false, percentual: 5, teto_reais: 25, validade_dias: 30 }

/** Configurações > Personas e política: nomes do assistente virtual, política de troca e cancelamento, parcelamento, fila da arte e cupom de recompra. */
export default function PersonasTab() {
  const toast = useToast()
  const salvar = useSalvarConfig()
  const per = useConfig<Personas>('personas', P0)
  const pol = useConfig<Politica>('politica', POL0)
  const par = useConfig<Parcelamento>('parcelamento', PAR0)
  const arte = useConfig<Arte>('arte', A0)
  const cup = useConfig<Cupom>('cupom_recompra', C0)
  const [p, setP] = useState(P0)
  const [o, setO] = useState(POL0)
  const [q, setQ] = useState(PAR0)
  const [a, setA] = useState(A0)
  const [c, setC] = useState(C0)
  useEffect(() => { if (per.data) setP(per.data) }, [per.data])
  useEffect(() => { if (pol.data) setO(pol.data) }, [pol.data])
  useEffect(() => { if (par.data) setQ(par.data) }, [par.data])
  useEffect(() => { if (arte.data) setA(arte.data) }, [arte.data])
  useEffect(() => { if (cup.data) setC(cup.data) }, [cup.data])
  if (!per.data || !pol.data || !par.data || !arte.data || !cup.data) return <Skeleton className="h-64 w-full" />

  const gravar = (key: Parameters<typeof salvar.mutate>[0]['key'], value: Record<string, unknown>, ok: string) =>
    salvar.mutate({ key, value }, { onSuccess: () => toast('ok', ok), onError: (e) => toast('error', (e as Error).message) })
  const num = (v: string) => Number(v.replace(',', '.'))

  return (
    <div className="space-y-8">
      <section className="space-y-3">
        <h2 className="text-base font-semibold">Personas do assistente virtual</h2>
        <p className="text-sm text-muted-foreground">Laura e João Victor são só nomes do mesmo assistente virtual. Antes do pagamento a conversa usa o nome de vendas; depois que o pagamento é confirmado, o nome do pós-pagamento. Quem decide a fase é o pedido, nunca o modelo. O agente nunca nega que é virtual.</p>
        <div className="grid gap-3 sm:grid-cols-2">
          <div className="space-y-1.5"><Label htmlFor="p-v">Nome de vendas (antes do pagamento)</Label><Input id="p-v" value={p.vendas} onChange={(e) => setP({ ...p, vendas: e.target.value })} /></div>
          <div className="space-y-1.5"><Label htmlFor="p-p">Nome do pós-pagamento</Label><Input id="p-p" value={p.pos_pagamento} onChange={(e) => setP({ ...p, pos_pagamento: e.target.value })} /></div>
        </div>
        <label className="flex items-start gap-2 text-sm"><Switch checked={p.pos_pagamento_automatico} onCheckedChange={(v) => setP({ ...p, pos_pagamento_automatico: v })} />
          <span>Depois do pagamento, o assistente continua sozinho (arte, prazo, andamento, retirada e pós-venda). Você só assume quando o pedido chega ao setor de arte. Desligado: o assistente para de responder quando o pagamento é confirmado.</span></label>
        <Button size="sm" disabled={!p.vendas.trim() || !p.pos_pagamento.trim() || salvar.isPending} onClick={() => gravar('personas', { ...p, vendas: p.vendas.trim(), pos_pagamento: p.pos_pagamento.trim() }, 'Personas salvas.')}>Salvar personas</Button>
      </section>

      <section className="space-y-3">
        <h2 className="text-base font-semibold">Política de troca e cancelamento</h2>
        <p className="text-sm text-muted-foreground">O resumo vai no rodapé do PDF do orçamento e o texto curto na descrição do link de pagamento. Use {'{{troca_prazo}}'} para o prazo da foto. Reembolso e estorno são sempre do dono.</p>
        <div className="space-y-1.5"><Label htmlFor="o-d">Prazo para enviar a foto do defeito (dias úteis)</Label><Input id="o-d" className="w-28" inputMode="numeric" value={String(o.troca_prazo_dias_uteis)} onChange={(e) => setO({ ...o, troca_prazo_dias_uteis: Math.max(1, Math.trunc(num(e.target.value) || 1)) })} /></div>
        <div className="space-y-1.5"><Label htmlFor="o-r">Resumo no rodapé do PDF</Label><Textarea id="o-r" rows={3} value={o.resumo_pdf} onChange={(e) => setO({ ...o, resumo_pdf: e.target.value })} /></div>
        <div className="space-y-1.5"><Label htmlFor="o-l">Descrição curta no link de pagamento</Label><Textarea id="o-l" rows={2} value={o.descricao_link} onChange={(e) => setO({ ...o, descricao_link: e.target.value })} /></div>
        <div className="space-y-1.5"><Label htmlFor="o-a">Texto de aceite ao aprovar a arte</Label><Textarea id="o-a" rows={2} value={o.aceite_arte} onChange={(e) => setO({ ...o, aceite_arte: e.target.value })} /></div>
        <Button size="sm" disabled={salvar.isPending} onClick={() => gravar('politica', { ...o }, 'Política salva.')}>Salvar política</Button>
      </section>

      <section className="space-y-3">
        <h2 className="text-base font-semibold">Parcelamento</h2>
        <p className="text-sm text-muted-foreground">Até {q.sem_juros_ate}x sem juros: a taxa é absorvida e já está no cálculo do preço. Acima disso os juros ficam por conta do cliente e aparecem no link do Mercado Pago. O &ldquo;sem juros&rdquo; em si é configurado na conta do Mercado Pago.</p>
        <div className="space-y-1.5"><Label htmlFor="q-m">Máximo de parcelas mostrado no link (1 a 12)</Label><Input id="q-m" className="w-28" inputMode="numeric" value={String(q.maximo_link)} onChange={(e) => setQ({ ...q, maximo_link: Math.min(12, Math.max(1, Math.trunc(num(e.target.value) || 1))) })} /></div>
        <Button size="sm" disabled={salvar.isPending} onClick={() => gravar('parcelamento', { maximo_link: q.maximo_link }, 'Parcelamento salvo. Vale para os próximos links.')}>Salvar parcelamento</Button>
      </section>

      <section className="space-y-3">
        <h2 className="text-base font-semibold">Setor de arte</h2>
        <div className="grid gap-3 sm:grid-cols-2">
          <div className="space-y-1.5"><Label htmlFor="a-f">Formato ideal da arte</Label><Input id="a-f" value={a.formato_ideal} onChange={(e) => setA({ ...a, formato_ideal: e.target.value })} /></div>
          <div className="space-y-1.5"><Label htmlFor="a-h">Novo alerta se você não agir em (horas)</Label><Input id="a-h" className="w-28" inputMode="numeric" value={String(a.horas_novo_alerta)} onChange={(e) => setA({ ...a, horas_novo_alerta: Math.max(1, Math.trunc(num(e.target.value) || 1)) })} /></div>
        </div>
        <Button size="sm" disabled={salvar.isPending} onClick={() => gravar('arte', { formato_ideal: a.formato_ideal.trim(), horas_novo_alerta: a.horas_novo_alerta }, 'Setor de arte salvo.')}>Salvar setor de arte</Button>
      </section>

      <section className="space-y-3">
        <h2 className="text-base font-semibold">Cupom de recompra</h2>
        <p className="text-sm text-muted-foreground">Gerado quando o pedido vira Entregue. Uso único, não acumula com condição especial, não depende de avaliação e respeita o limite interno do preço. Se não couber, vira arte básica grátis. {c.ativo ? 'Está LIGADO.' : 'Está desligado: rode a simulação antes de ligar.'}</p>
        <div className="grid gap-3 sm:grid-cols-3">
          <div className="space-y-1.5"><Label htmlFor="c-p">Percentual (%)</Label><Input id="c-p" inputMode="decimal" value={String(c.percentual)} onChange={(e) => setC({ ...c, percentual: Math.min(10, Math.max(0, num(e.target.value) || 0)) })} /></div>
          <div className="space-y-1.5"><Label htmlFor="c-t">Teto (R$)</Label><Input id="c-t" inputMode="decimal" value={String(c.teto_reais)} onChange={(e) => setC({ ...c, teto_reais: Math.max(0, num(e.target.value) || 0) })} /></div>
          <div className="space-y-1.5"><Label htmlFor="c-v">Validade (dias)</Label><Input id="c-v" inputMode="numeric" value={String(c.validade_dias)} onChange={(e) => setC({ ...c, validade_dias: Math.max(1, Math.trunc(num(e.target.value) || 1)) })} /></div>
        </div>
        <Button size="sm" disabled={salvar.isPending} onClick={() => gravar('cupom_recompra', { percentual: c.percentual, teto_reais: c.teto_reais, validade_dias: c.validade_dias }, 'Cupom salvo.')}>Salvar cupom</Button>
      </section>
    </div>
  )
}
