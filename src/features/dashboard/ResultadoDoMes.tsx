import { useQuery } from '@tanstack/react-query'
import { Link } from 'react-router-dom'
import { useAuth } from '@/auth/AuthProvider'
import { formatBRL } from '@/lib/money'
import { supabase } from '@/lib/supabase'
import { cn } from '@/lib/utils'

/** Painel: resultado do mês (lucro dos pedidos + outras receitas - despesas). Só aparece para o dono; os números vêm da tela Financeiro. */
export function ResultadoDoMes() {
  const { profile } = useAuth()
  const admin = profile?.role === 'admin'
  const { data } = useQuery({
    enabled: admin,
    queryKey: ['financeiro', 'painel'],
    retry: false,
    queryFn: async () => {
      const hoje = new Date()
      const de = new Date(hoje.getFullYear(), hoje.getMonth(), 1).toISOString().slice(0, 10)
      const { data, error } = await supabase.rpc('financeiro_resumo', { p_de: de, p_ate: hoje.toISOString().slice(0, 10) })
      if (error) throw new Error(error.message)
      return data as { pedidos: { lucro: number }; manual: { receitas: number; despesas: number }; resultado: number }
    },
  })
  if (!admin || !data) return null
  return (
    <section aria-label="Resultado do mês" className="rounded-md border bg-card p-4">
      <div className="mb-2 flex items-baseline justify-between gap-2">
        <h2 className="text-base font-black">Resultado do mês</h2>
        <Link to="/financeiro" className="text-sm font-semibold text-link underline">Abrir financeiro</Link>
      </div>
      <dl className="grid grid-cols-2 gap-3 text-sm md:grid-cols-4">
        <div><dt className="text-[11px] uppercase text-muted-foreground">Lucro dos pedidos</dt><dd className="font-bold tabular">{formatBRL(data.pedidos.lucro)}</dd></div>
        <div><dt className="text-[11px] uppercase text-muted-foreground">Outras receitas</dt><dd className="font-bold tabular">{formatBRL(data.manual.receitas)}</dd></div>
        <div><dt className="text-[11px] uppercase text-muted-foreground">Despesas</dt><dd className="font-bold tabular text-brand-red">{formatBRL(data.manual.despesas)}</dd></div>
        <div><dt className="text-[11px] uppercase text-muted-foreground">Resultado</dt><dd className={cn('font-black tabular', data.resultado >= 0 ? 'text-brand-green' : 'text-brand-red')}>{formatBRL(data.resultado)}</dd></div>
      </dl>
    </section>
  )
}
