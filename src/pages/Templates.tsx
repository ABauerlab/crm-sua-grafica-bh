import { useMutation, useQueryClient } from '@tanstack/react-query'
import { RefreshCw } from 'lucide-react'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { useTemplates } from '@/hooks/queries'
import { invokeFunction } from '@/lib/api'
import { cn } from '@/lib/utils'

const STATUS: Record<string, { label: string; className: string }> = {
  APPROVED: { label: 'Aprovado', className: 'bg-emerald-100 text-emerald-800' },
  PENDING: { label: 'Em análise', className: 'bg-amber-100 text-amber-800' },
  REJECTED: { label: 'Rejeitado', className: 'bg-rose-100 text-rose-800' },
  PAUSED: { label: 'Pausado', className: 'bg-orange-100 text-orange-800' },
  DISABLED: { label: 'Desativado', className: 'bg-zinc-200 text-zinc-700' },
}

const CATEGORY: Record<string, string> = { MARKETING: 'Marketing', UTILITY: 'Utilidade', AUTHENTICATION: 'Autenticação' }

export default function Templates() {
  const qc = useQueryClient()
  const { data, isLoading, error } = useTemplates()

  const sync = useMutation({
    mutationFn: () => invokeFunction<{ count: number }>('whatsapp-sync-templates'),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['templates'] }),
  })

  const lastSync = data?.reduce<string | null>((acc, t) => (!acc || t.synced_at > acc ? t.synced_at : acc), null)

  return (
    <div className="flex h-full flex-col">
      <header className="flex flex-wrap items-center justify-between gap-3 border-b px-4 py-3">
        <div>
          <h1 className="text-lg font-semibold">Templates</h1>
          <p className="text-xs text-muted-foreground">
            {lastSync ? `Última sincronização: ${new Date(lastSync).toLocaleString('pt-BR')}` : 'Ainda não sincronizado.'}
          </p>
        </div>
        <Button onClick={() => sync.mutate()} disabled={sync.isPending}>
          <RefreshCw className={cn('h-4 w-4', sync.isPending && 'animate-spin')} />
          {sync.isPending ? 'Sincronizando…' : 'Sincronizar'}
        </Button>
      </header>

      <div className="min-h-0 flex-1 overflow-y-auto p-4">
        <p className="mb-3 text-xs text-muted-foreground">
          Dica: crie os templates de marketing na Meta com um botão de resposta rápida &quot;Parar promoções&quot;. Quando o cliente toca nele, o sistema
          registra o descadastro e confirma automaticamente.
        </p>
        {sync.isError && <p role="alert" className="mb-3 rounded-md bg-destructive/10 p-3 text-sm text-destructive">{sync.error.message}</p>}
        {sync.isSuccess && <p className="mb-3 rounded-md bg-accent p-3 text-sm text-accent-foreground">{sync.data.count} template(s) sincronizado(s).</p>}
        {isLoading && <p className="text-sm text-muted-foreground">Carregando…</p>}
        {error && <p className="text-sm text-destructive">Erro ao carregar templates.</p>}
        {!isLoading && !data?.length && <p className="text-sm text-muted-foreground">Nenhum template. Clique em Sincronizar para buscar os da Meta.</p>}
        <div className="grid gap-3 md:grid-cols-2">
          {data?.map((t) => {
            const s = STATUS[t.status ?? ''] ?? { label: t.status ?? '—', className: 'bg-zinc-200 text-zinc-700' }
            return (
              <article key={`${t.name}|${t.language}`} className="rounded-lg border bg-card p-4">
                <div className="flex items-start justify-between gap-2">
                  <div className="min-w-0">
                    <h2 className="truncate text-sm font-semibold">{t.name}</h2>
                    <p className="text-xs text-muted-foreground">
                      {t.language} · {CATEGORY[t.category ?? ''] ?? t.category ?? '—'}
                    </p>
                  </div>
                  <Badge className={s.className}>{s.label}</Badge>
                </div>
                {t.category === 'MARKETING' && (
                  <Badge className={cn('mt-2', t.has_opt_out_button ? 'bg-emerald-100 text-emerald-800' : 'bg-amber-100 text-amber-800')}>
                    {t.has_opt_out_button ? 'Tem botão Parar promoções' : 'Sem botão Parar promoções'}
                  </Badge>
                )}
                <p className="mt-3 whitespace-pre-wrap text-sm text-muted-foreground">{t.body ?? 'Sem corpo de texto.'}</p>
              </article>
            )
          })}
        </div>
      </div>
    </div>
  )
}
