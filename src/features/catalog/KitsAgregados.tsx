import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Link2 } from 'lucide-react'
import { Badge } from '@/components/ui/badge'
import { Switch } from '@/components/ui/switch'
import { useToast } from '@/components/ui/toast'
import { useAuth } from '@/auth/AuthProvider'
import { supabase } from '@/lib/supabase'

interface KitAgregado {
  id: string
  nome: string
  descricao: string | null
  ativo: boolean
  componentes: { papel: string; recebe_abatimento: boolean }[]
}

const PAPEL: Record<string, string> = { cracha: 'Crachá', cordao: 'Cordão' }

/** Kits agregados: produtos compostos por SKUs reais; o preço sai de calcular_preco e das travas de lucro (montar_orcamento aplica sozinho). */
export function KitsAgregados() {
  const { profile } = useAuth()
  const toast = useToast()
  const qc = useQueryClient()
  const { data } = useQuery({
    queryKey: ['kits-agregados'],
    queryFn: async () => {
      const [k, c] = await Promise.all([
        supabase.from('kits_agregados').select('id,nome,descricao,ativo').order('criado_em'),
        supabase.from('kits_agregados_componentes').select('kit_id,papel,recebe_abatimento'),
      ])
      if (k.error) throw k.error
      if (c.error) throw c.error
      return (k.data as Omit<KitAgregado, 'componentes'>[]).map((x) => ({ ...x, componentes: (c.data as { kit_id: string; papel: string; recebe_abatimento: boolean }[]).filter((i) => i.kit_id === x.id) })) as KitAgregado[]
    },
  })
  const alternar = useMutation({
    mutationFn: async ({ id, ativo }: { id: string; ativo: boolean }) => {
      const { error } = await supabase.from('kits_agregados').update({ ativo }).eq('id', id)
      if (error) throw new Error(error.message)
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['kits-agregados'] }),
    onError: (e: Error) => toast('error', e.message),
  })
  if (!data?.length) return null
  return (
    <section className="mb-4 space-y-2" aria-label="Kits agregados">
      <h3 className="text-xs font-bold uppercase tracking-wide">Kits agregados (calculados pelos SKUs reais)</h3>
      <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
        {data.map((k) => (
          <div key={k.id} className="space-y-2 rounded-lg border bg-card p-3">
            <div className="flex items-start justify-between gap-2">
              <p className="flex items-center gap-1.5 font-semibold"><Link2 className="h-4 w-4 text-primary" aria-hidden /> {k.nome}</p>
              <Switch checked={k.ativo} disabled={profile?.role !== 'admin' || alternar.isPending} onCheckedChange={(v) => alternar.mutate({ id: k.id, ativo: v })} aria-label={`Kit ${k.nome} ativo`} />
            </div>
            <div className="flex flex-wrap gap-1.5">{k.componentes.map((c) => <Badge key={c.papel} className="bg-secondary">{PAPEL[c.papel] ?? c.papel}{c.recebe_abatimento ? ' (ajustado no kit)' : ''}</Badge>)}</div>
            <p className="text-xs text-muted-foreground">{k.descricao}</p>
          </div>
        ))}
      </div>
    </section>
  )
}
