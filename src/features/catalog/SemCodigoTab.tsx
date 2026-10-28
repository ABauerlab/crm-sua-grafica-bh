import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Download, Tag } from 'lucide-react'
import { useState } from 'react'
import { Button } from '@/components/ui/button'
import { EmptyState, ErrorState } from '@/components/ui/empty-state'
import { Input } from '@/components/ui/input'
import { Skeleton } from '@/components/ui/skeleton'
import { useToast } from '@/components/ui/toast'
import { downloadCsv } from '@/lib/csv'
import { formatNumber } from '@/lib/money'
import { supabase } from '@/lib/supabase'

interface Linha { id: string; categoria: string | null; descricao: string; cores: string | null; quantidade: number | null; tamanho_mm: string | null; prazo_dias_uteis: number | null; peso_g: number | null }

/** Linhas da tabela do fornecedor que vieram SEM código (PDV, balcão, totens…). Não são vendáveis até o dono informar o código. */
export function useSemCodigo() {
  return useQuery({
    queryKey: ['catalogo-sem-sku'],
    queryFn: async () => {
      const { data, error } = await supabase.from('catalogo_sem_sku').select('*').order('categoria').order('descricao').limit(2000)
      if (error) throw error
      return data as Linha[]
    },
  })
}

export function SemCodigoTab() {
  const qc = useQueryClient()
  const toast = useToast()
  const { data, isLoading, error, refetch } = useSemCodigo()
  const [codes, setCodes] = useState<Record<string, string>>({})

  const definir = useMutation({
    mutationFn: async ({ id, sku }: { id: string; sku: string }) => {
      const { error } = await supabase.rpc('catalogo_definir_sku', { p_id: id, p_sku: sku })
      if (error) throw new Error(error.message)
    },
    onSuccess: () => {
      toast('ok', 'Código salvo. O item já pode ser vendido.')
      qc.invalidateQueries({ queryKey: ['catalogo-sem-sku'] })
      qc.invalidateQueries({ queryKey: ['products'] })
    },
    onError: (e: Error) => toast('error', e.message),
  })

  if (error) return <ErrorState message="Não foi possível carregar as linhas sem código." onRetry={() => refetch()} />
  if (isLoading) return <div className="space-y-2 p-4">{[0, 1, 2].map((i) => <Skeleton key={i} className="h-10 w-full" />)}</div>
  if (!data?.length) return <EmptyState icon={Tag} title="Nenhuma linha sem código">Tudo o que está no catálogo tem SKU.</EmptyState>

  return (
    <div className="min-h-0 flex-1 overflow-auto p-4">
      <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
        <p className="max-w-2xl text-sm text-muted-foreground">
          Estas {formatNumber(data.length)} linhas vieram da tabela do fornecedor sem código. Não são vendáveis e o agente não as oferece. Quando você informar o código, a linha passa a valer como as demais.
        </p>
        <Button size="sm" variant="outline" onClick={() => downloadCsv('linhas-sem-codigo.csv', ['Categoria', 'Descrição', 'Cores', 'Qtde', 'Tam', 'Prazo'], data.map((r) => [r.categoria, r.descricao, r.cores, r.quantidade, r.tamanho_mm, r.prazo_dias_uteis]))}>
          <Download className="h-4 w-4" /> Baixar lista (CSV)
        </Button>
      </div>
      <table className="w-full min-w-[900px] text-sm">
        <thead><tr className="border-b text-left text-[11px] uppercase text-muted-foreground"><th className="py-2">Categoria</th><th>Descrição</th><th>Cores</th><th className="text-right">Qtde</th><th className="pl-3">Tam (mm)</th><th className="text-right">Prazo</th><th className="pl-4">Código</th></tr></thead>
        <tbody>
          {data.map((r) => (
            <tr key={r.id} className="border-b">
              <td className="py-2 text-xs text-muted-foreground">{r.categoria ?? '—'}</td><td className="max-w-sm font-semibold">{r.descricao}</td><td>{r.cores ?? '—'}</td><td className="text-right tabular">{r.quantidade ?? '—'}</td><td className="pl-3">{r.tamanho_mm ?? '—'}</td><td className="text-right tabular">{r.prazo_dias_uteis ?? '—'}</td>
              <td className="py-1.5 pl-4">
                <form className="flex gap-1" onSubmit={(e) => { e.preventDefault(); const sku = (codes[r.id] ?? '').trim(); if (sku) definir.mutate({ id: r.id, sku }) }}>
                  <Input aria-label={`Código de ${r.descricao}`} className="h-9 w-36 font-mono" value={codes[r.id] ?? ''} onChange={(e) => setCodes({ ...codes, [r.id]: e.target.value })} />
                  <Button size="sm" type="submit" disabled={definir.isPending || !(codes[r.id] ?? '').trim()}>Salvar</Button>
                </form>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
