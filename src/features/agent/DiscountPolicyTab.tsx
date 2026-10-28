import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Skeleton } from '@/components/ui/skeleton'
import { useToast } from '@/components/ui/toast'
import { supabase } from '@/lib/supabase'

type Rule = { degrau: number; nome: string; tipo: 'vantagem' | 'desconto'; percentual: number; desconto_max_reais: number; fracao_gordura_max: number; validade_horas: number; intervalo_dias_contato: number; ativo: boolean }

/** A política só altera limites; o banco calcula cada condição e trava qualquer prejuízo. */
export default function DiscountPolicyTab() {
  const toast = useToast(); const qc = useQueryClient()
  const q = useQuery({ queryKey: ['politica-desconto'], queryFn: async () => { const { data, error } = await supabase.from('politica_desconto').select('*').order('degrau'); if (error) throw error; return data as Rule[] } })
  const [rules, setRules] = useState<Rule[]>([])
  useEffect(() => { if (q.data) setRules(q.data) }, [q.data])
  const save = useMutation({ mutationFn: async (r: Rule) => { const { error } = await supabase.from('politica_desconto').update({ percentual: Math.max(0, r.percentual), desconto_max_reais: Math.max(0, r.desconto_max_reais), fracao_gordura_max: Math.max(0, Math.min(1, r.fracao_gordura_max)), validade_horas: Math.max(1, Math.round(r.validade_horas)), intervalo_dias_contato: Math.max(0, Math.round(r.intervalo_dias_contato)), ativo: r.ativo }).eq('degrau', r.degrau); if (error) throw new Error(error.message) }, onSuccess: () => { qc.invalidateQueries({ queryKey: ['politica-desconto'] }); toast('ok', 'Política salva. A trava de lucro continua ativa.') }, onError: (e: Error) => toast('error', e.message) })
  if (q.isLoading) return <Skeleton className="h-48 w-full" />
  const patch = (id: number, next: Partial<Rule>) => setRules((old) => old.map((x) => x.degrau === id ? { ...x, ...next } : x))
  return <div className="max-w-3xl space-y-4"><p className="text-sm text-muted-foreground">A condição especial é calculada pelo banco. O desconto sai apenas da margem acima do piso; se o pior caso der prejuízo, o sistema recusa a oferta.</p>{rules.map((r) => <section key={r.degrau} className="rounded-md border p-3"><div className="mb-3 flex items-center justify-between gap-3"><div><strong>Degrau {r.degrau}</strong><p className="text-xs text-muted-foreground">{r.nome}</p></div><label className="text-sm"><input type="checkbox" checked={r.ativo} onChange={(e) => patch(r.degrau, { ativo: e.target.checked })} /> Ativo</label></div>{r.tipo === 'desconto' ? <div className="grid gap-3 sm:grid-cols-3"><label className="text-sm">Desconto máximo (%)<Input type="number" min="0" max="10" value={r.percentual} onChange={(e) => patch(r.degrau, { percentual: Number(e.target.value) })} /></label><label className="text-sm">Teto (R$)<Input type="number" min="0" value={r.desconto_max_reais} onChange={(e) => patch(r.degrau, { desconto_max_reais: Number(e.target.value) })} /></label><label className="text-sm">Parte da gordura<Input type="number" min="0" max="1" step="0.05" value={r.fracao_gordura_max} onChange={(e) => patch(r.degrau, { fracao_gordura_max: Number(e.target.value) })} /></label></div> : <p className="text-sm text-muted-foreground">Oferece arte ou frete grátis quando a regra de margem permitir.</p>}<p className="mt-3 text-xs text-muted-foreground">Validade: {r.validade_horas} h · Intervalo por contato: {r.intervalo_dias_contato} dias.</p><Button className="mt-3" size="sm" disabled={save.isPending} onClick={() => save.mutate(r)}>Salvar degrau</Button></section>)}</div>
}
