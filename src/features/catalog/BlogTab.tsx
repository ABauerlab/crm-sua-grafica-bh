import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Eye, EyeOff, ExternalLink, Newspaper, RefreshCw } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { EmptyState, ErrorState } from '@/components/ui/empty-state'
import { Skeleton } from '@/components/ui/skeleton'
import { useToast } from '@/components/ui/toast'
import { invokeFunction } from '@/lib/api'
import { supabase } from '@/lib/supabase'

interface Post { id: number; slug: string; titulo: string; resumo: string; fonte_nome: string; fonte_url: string; status: 'publicado' | 'oculto'; publicado_em: string }
interface Pauta { status: string; n: number }
interface Rodada { lidas: number; novas: number; publicadas: number; recusadas: number; erros_fonte: number; limite_do_dia?: boolean; aviso?: string }

const SITE = 'https://suagraficabh.com.br'

/** Blog do site (Fase 8): os posts saem sozinhos; aqui o dono confere, tira do ar ou volta a mostrar. */
export function BlogTab() {
  const toast = useToast()
  const qc = useQueryClient()
  const posts = useQuery({
    queryKey: ['blog-posts'],
    queryFn: async () => {
      const { data, error } = await supabase.from('blog_posts').select('id, slug, titulo, resumo, fonte_nome, fonte_url, status, publicado_em').order('publicado_em', { ascending: false }).limit(100)
      if (error) throw error
      return data as Post[]
    },
  })
  const pautas = useQuery({
    queryKey: ['blog-pautas'],
    queryFn: async () => {
      const { data, error } = await supabase.from('blog_pautas').select('status').gte('criado_em', new Date(Date.now() - 7 * 86400000).toISOString())
      if (error) throw error
      const c = new Map<string, number>()
      for (const r of data ?? []) c.set(r.status, (c.get(r.status) ?? 0) + 1)
      return [...c].map(([status, n]) => ({ status, n })) as Pauta[]
    },
  })
  const alternar = useMutation({
    mutationFn: async (p: Post) => {
      const { error } = await supabase.from('blog_posts').update({ status: p.status === 'publicado' ? 'oculto' : 'publicado', atualizado_em: new Date().toISOString() }).eq('id', p.id)
      if (error) throw error
    },
    onSuccess: () => { toast('ok', 'Post atualizado. O site atualiza em até 30 minutos.'); qc.invalidateQueries({ queryKey: ['blog-posts'] }) },
    onError: (e: Error) => toast('error', e.message),
  })
  const rodar = useMutation({
    mutationFn: () => invokeFunction<Rodada>('blog-pautas', {}),
    onSuccess: (r) => {
      toast('ok', r.aviso ?? (r.limite_do_dia ? `Limite de posts de hoje atingido. ${r.novas} pautas novas guardadas.` : `${r.novas} pautas novas, ${r.publicadas} post(s) publicados, ${r.recusadas} recusada(s).`))
      qc.invalidateQueries({ queryKey: ['blog-posts'] }); qc.invalidateQueries({ queryKey: ['blog-pautas'] })
    },
    onError: (e: Error) => toast('error', e.message),
  })

  if (posts.error) return <ErrorState message="Não foi possível carregar o blog." onRetry={() => posts.refetch()} />
  if (posts.isLoading) return <div className="space-y-2 p-4">{[0, 1, 2].map((i) => <Skeleton key={i} className="h-12 w-full" />)}</div>
  const NOMES: Record<string, string> = { nova: 'na fila', publicada: 'publicadas', descartada: 'descartadas', erro: 'com erro' }

  return (
    <div className="min-h-0 flex-1 space-y-3 overflow-auto p-4">
      <div className="flex flex-wrap items-center gap-3">
        <p className="text-sm text-muted-foreground">
          Posts gerados a partir de notícias do setor, com texto próprio e crédito à fonte. Até 3 por dia, publicados sozinhos.
          {pautas.data?.length ? ` Pautas dos últimos 7 dias: ${pautas.data.map((p) => `${p.n} ${NOMES[p.status] ?? p.status}`).join(', ')}.` : ''}
        </p>
        <Button size="sm" variant="outline" className="ml-auto" disabled={rodar.isPending} onClick={() => rodar.mutate()}>
          <RefreshCw className={`h-4 w-4 ${rodar.isPending ? 'animate-spin' : ''}`} />Buscar pautas agora
        </Button>
      </div>
      {!posts.data?.length ? <EmptyState icon={Newspaper} title="Nenhum post ainda">A primeira rodada sai no próximo horário agendado (7h, 12h e 17h).</EmptyState> : (
        <ul className="divide-y rounded-lg border bg-card">
          {posts.data.map((p) => (
            <li key={p.id} className="flex items-start gap-3 px-3 py-2">
              <div className="min-w-0 flex-1">
                <p className={`font-medium ${p.status === 'oculto' ? 'text-muted-foreground line-through' : ''}`}>{p.titulo}</p>
                <p className="truncate text-xs text-muted-foreground">{new Date(p.publicado_em).toLocaleString('pt-BR')} · fonte: {p.fonte_nome} · {p.resumo}</p>
              </div>
              <a className="shrink-0 text-muted-foreground hover:text-foreground" href={`${SITE}/blog/${p.slug}`} target="_blank" rel="noopener" title="Abrir no site"><ExternalLink className="h-4 w-4" /></a>
              <Button size="sm" variant="outline" disabled={alternar.isPending} onClick={() => alternar.mutate(p)}>
                {p.status === 'publicado' ? <><EyeOff className="h-4 w-4" />Ocultar</> : <><Eye className="h-4 w-4" />Mostrar</>}
              </Button>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
