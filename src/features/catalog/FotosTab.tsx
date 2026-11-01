import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Ban, Camera, CheckCircle2, RefreshCw } from 'lucide-react'
import { useState } from 'react'
import { Button } from '@/components/ui/button'
import { EmptyState, ErrorState } from '@/components/ui/empty-state'
import { Input } from '@/components/ui/input'
import { Skeleton } from '@/components/ui/skeleton'
import { useToast } from '@/components/ui/toast'
import { invokeFunction } from '@/lib/api'
import { formatNumber } from '@/lib/money'
import { supabase } from '@/lib/supabase'

interface Grupo { grupo_produto: string; itens: number; situacao: string; aprovadas: number; pendentes: number; bloqueadas: number; revisar: number; pedidos: number; buscado_em: string | null; expira_em: string | null }
interface Foto { id: string; arquivo_storage: string | null; status: string; revisar: boolean; motivo: string | null; aproximada: boolean; bytes: number | null; largura: number | null; altura: number | null; baixa_qualidade: boolean; fonte: string; sku: string | null }
interface Cobertura { grupo_produto: string; skus: number; skus_com_imagem: number; pct_com_imagem: number; fotos_aprovadas: number; baixa_qualidade: number }

const SITUACAO: Record<string, string> = { ok: 'Com fotos', sem_foto: 'Sem foto', erro: 'Erro na busca', nao_buscado: 'Ainda não buscado' }

/** Fotos de produto que o agente envia no WhatsApp. Tela só do dono: aprovar, bloquear, trocar e ver os grupos sem foto. A origem nunca aparece aqui. */
export function FotosTab() {
  const toast = useToast()
  const qc = useQueryClient()
  const [aberto, setAberto] = useState<string | null>(null)
  const [filtro, setFiltro] = useState<'todos' | 'revisar' | 'sem_foto'>('todos')
  const grupos = useQuery({
    queryKey: ['fotos-painel'],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('fotos_painel')
      if (error) throw error
      return data as Grupo[]
    },
  })
  const invalidar = () => { qc.invalidateQueries({ queryKey: ['fotos-painel'] }); qc.invalidateQueries({ queryKey: ['fotos-grupo'] }) }
  const buscar = useMutation({
    mutationFn: (grupo: string) => invokeFunction<{ situacao: string; novas: number }>('produto-fotos', { acao: 'rebuscar', grupo }),
    onSuccess: (r) => { toast(r.novas ? 'ok' : 'error', r.novas ? `${r.novas} foto(s) novas para conferir.` : 'Nenhuma foto aproveitável encontrada para este grupo.'); invalidar() },
    onError: (e: Error) => toast('error', e.message),
  })

  if (grupos.error) return <ErrorState message="Não foi possível carregar as fotos." onRetry={() => grupos.refetch()} />
  if (grupos.isLoading) return <div className="space-y-2 p-4">{[0, 1, 2].map((i) => <Skeleton key={i} className="h-10 w-full" />)}</div>
  const lista = (grupos.data ?? []).filter((g) => filtro === 'todos' || (filtro === 'revisar' ? g.revisar > 0 || g.pendentes > 0 : g.situacao === 'sem_foto'))
  const nRev = (grupos.data ?? []).filter((g) => g.revisar > 0 || g.pendentes > 0).length
  const nSem = (grupos.data ?? []).filter((g) => g.situacao === 'sem_foto').length

  return (
    <div className="min-h-0 flex-1 space-y-3 overflow-auto p-4">
      <OrigemConfig />
      <CoberturaPainel />
      <div className="flex flex-wrap gap-2 text-sm">
        {([['todos', 'Todos os grupos'], ['revisar', `Para revisar (${nRev})`], ['sem_foto', `Sem foto (${nSem})`]] as const).map(([k, rotulo]) => (
          <Button key={k} size="sm" variant={filtro === k ? 'default' : 'outline'} onClick={() => setFiltro(k)}>{rotulo}</Button>
        ))}
      </div>
      {!lista.length ? <EmptyState icon={Camera} title="Nada por aqui">Nenhum grupo neste filtro.</EmptyState> : (
        <ul className="divide-y rounded-lg border bg-card">
          {lista.map((g) => (
            <li key={g.grupo_produto}>
              <button type="button" className="flex w-full items-center gap-3 px-3 py-2 text-left hover:bg-muted/50" onClick={() => setAberto(aberto === g.grupo_produto ? null : g.grupo_produto)}>
                <span className="min-w-0 flex-1 truncate font-medium">{g.grupo_produto}</span>
                <span className="text-xs text-muted-foreground">{formatNumber(g.itens)} itens · {g.pedidos} pedido(s) de foto</span>
                <span className={`rounded px-2 py-0.5 text-xs ${g.situacao === 'ok' ? 'bg-emerald-100 text-emerald-800' : g.situacao === 'nao_buscado' ? 'bg-muted' : 'bg-amber-100 text-amber-800'}`}>{SITUACAO[g.situacao] ?? g.situacao}</span>
                <span className="w-40 text-right text-xs">{g.aprovadas} aprovada(s){g.revisar + g.pendentes > 0 ? ` · ${g.revisar + g.pendentes} p/ revisar` : ''}{g.bloqueadas ? ` · ${g.bloqueadas} bloq.` : ''}</span>
              </button>
              {aberto === g.grupo_produto && <GrupoFotos grupo={g.grupo_produto} onBuscar={() => buscar.mutate(g.grupo_produto)} buscando={buscar.isPending} onChange={invalidar} />}
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}

function GrupoFotos({ grupo, onBuscar, buscando, onChange }: { grupo: string; onBuscar: () => void; buscando: boolean; onChange: () => void }) {
  const toast = useToast()
  const [url, setUrl] = useState('')
  const fotos = useQuery({
    queryKey: ['fotos-grupo', grupo],
    queryFn: async () => {
      const { data, error } = await supabase.from('produto_fotos').select('id, arquivo_storage, status, revisar, motivo, aproximada, bytes, largura, altura, baixa_qualidade, fonte, sku').eq('grupo_produto', grupo).order('ordem')
      if (error) throw error
      const itens = data as Foto[]
      const urls = await Promise.all(itens.map(async (f) => (f.arquivo_storage ? (await supabase.storage.from('produto-fotos').createSignedUrl(f.arquivo_storage, 600)).data?.signedUrl ?? null : null)))
      return itens.map((f, i) => ({ ...f, url: urls[i] }))
    },
  })
  const decidir = useMutation({
    mutationFn: async ({ id, status }: { id: string; status: 'aprovada' | 'bloqueada' }) => {
      const { error } = await supabase.rpc('foto_decidir', { p_id: id, p_status: status, p_motivo: status === 'bloqueada' ? 'bloqueada pelo dono' : 'aprovada pelo dono' })
      if (error) throw new Error(error.message)
    },
    onSuccess: () => { fotos.refetch(); onChange() },
    onError: (e: Error) => toast('error', e.message),
  })
  const trocar = useMutation({
    mutationFn: () => invokeFunction('produto-fotos', { acao: 'trocar', grupo, url_imagem: url.trim() }),
    onSuccess: () => { toast('ok', 'Imagem processada e aprovada.'); setUrl(''); fotos.refetch(); onChange() },
    onError: (e: Error) => toast('error', e.message),
  })
  return (
    <div className="space-y-3 border-t bg-muted/30 p-3">
      <div className="flex flex-wrap items-center gap-2">
        <Button size="sm" variant="outline" disabled={buscando} onClick={onBuscar}><RefreshCw className="mr-1 h-4 w-4" />Buscar de novo</Button>
        <Input className="h-8 max-w-sm" placeholder="Trocar: endereço (https) de uma imagem escolhida" value={url} onChange={(e) => setUrl(e.target.value)} />
        <Button size="sm" disabled={!url.trim() || trocar.isPending} onClick={() => trocar.mutate()}>Usar esta imagem</Button>
      </div>
      {fotos.isLoading ? <Skeleton className="h-24 w-full" /> : !fotos.data?.length ? <p className="text-sm text-muted-foreground">Sem imagens guardadas para este grupo.</p> : (
        <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
          {fotos.data.map((f) => (
            <figure key={f.id} className="space-y-1 rounded-lg border bg-card p-2 text-xs">
              {f.url ? <img src={f.url} alt="" className="aspect-square w-full rounded object-cover" /> : <div className="aspect-square rounded bg-muted" />}
              <figcaption>
                <div className="font-medium">{f.status === 'aprovada' ? 'Aprovada' : f.status === 'bloqueada' ? 'Bloqueada' : 'Pendente'}{f.aproximada ? ' · ilustrativa' : f.sku ? ` · ${f.sku}` : ''}</div>
                {f.baixa_qualidade && <div className="text-amber-700">Baixa qualidade: troque quando tiver foto melhor</div>}
                <div className="text-muted-foreground">{f.largura}×{f.altura} · {f.bytes ? Math.round(f.bytes / 1024) : '?'} KB</div>
                {f.motivo && <div className="text-muted-foreground">{f.motivo}</div>}
              </figcaption>
              <div className="flex gap-1">
                <Button size="sm" variant="outline" disabled={f.status === 'aprovada' || decidir.isPending} onClick={() => decidir.mutate({ id: f.id, status: 'aprovada' })}><CheckCircle2 className="mr-1 h-3 w-3" />Aprovar</Button>
                <Button size="sm" variant="outline" disabled={f.status === 'bloqueada' || decidir.isPending} onClick={() => decidir.mutate({ id: f.id, status: 'bloqueada' })}><Ban className="mr-1 h-3 w-3" />Bloquear</Button>
              </div>
            </figure>
          ))}
        </div>
      )}
    </div>
  )
}

/** Endereço da origem das imagens: dado interno, gravado só no banco (nunca no repositório) e nunca mostrado ao cliente. */
function OrigemConfig() {
  const toast = useToast()
  const cfg = useQuery({
    queryKey: ['fotos-config'],
    queryFn: async () => {
      const { data, error } = await supabase.from('app_settings').select('value').eq('key', 'fotos').maybeSingle()
      if (error) throw error
      return (data?.value ?? {}) as { origem_base?: string; aquecer_ligado?: boolean }
    },
  })
  const [base, setBase] = useState<string | null>(null)
  const salvar = useMutation({
    mutationFn: async (patch: Record<string, unknown>) => {
      const { error } = await supabase.from('app_settings').update({ value: { ...(cfg.data ?? {}), ...patch } }).eq('key', 'fotos')
      if (error) throw new Error(error.message)
    },
    onSuccess: () => { toast('ok', 'Configuração salva.'); cfg.refetch() },
    onError: (e: Error) => toast('error', e.message),
  })
  const atual = base ?? cfg.data?.origem_base ?? ''
  return (
    <div className="flex flex-wrap items-center gap-2 rounded-lg border bg-card p-3 text-sm">
      <span className="font-medium">Origem das fotos (interna)</span>
      <Input className="h-8 max-w-sm" type="url" placeholder="https://..." value={atual} onChange={(e) => setBase(e.target.value)} />
      <Button size="sm" disabled={salvar.isPending || atual === (cfg.data?.origem_base ?? '')} onClick={() => salvar.mutate({ origem_base: atual.trim().replace(/\/+$/, '') })}>Salvar</Button>
      <label className="ml-auto flex items-center gap-2"><input type="checkbox" checked={!!cfg.data?.aquecer_ligado} onChange={(e) => salvar.mutate({ aquecer_ligado: e.target.checked })} />Aquecer o cache de madrugada (30 grupos mais pedidos)</label>
    </div>
  )
}

/** Cobertura de imagens por grupo (SKUs do catálogo com imagem na origem) e varredura completa do menu da origem. */
function CoberturaPainel() {
  const toast = useToast()
  const qc = useQueryClient()
  const [progresso, setProgresso] = useState<string | null>(null)
  const cob = useQuery({
    queryKey: ['fotos-cobertura'],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('fotos_cobertura')
      if (error) throw error
      return data as Cobertura[]
    },
  })
  const varrer = useMutation({
    mutationFn: async () => {
      const { topos } = await invokeFunction<{ topos: string[] }>('produto-fotos', { acao: 'topos' })
      for (let i = 0; i < topos.length; i++) {
        let pagina: number | null = 0
        while (pagina !== null) {
          setProgresso(`Mapeando ${i + 1} de ${topos.length}: ${topos[i]}`)
          const r: { proxima: number | null } = await invokeFunction('produto-fotos', { acao: 'varrer', topo: topos[i], pagina })
          pagina = r.proxima
        }
      }
    },
    onSuccess: () => { setProgresso(null); toast('ok', 'Mapa de imagens atualizado.'); qc.invalidateQueries({ queryKey: ['fotos-cobertura'] }) },
    onError: (e: Error) => { setProgresso(null); toast('error', e.message) },
  })
  const dados = cob.data ?? []
  const skus = dados.reduce((a, g) => a + g.skus, 0)
  const com = dados.reduce((a, g) => a + g.skus_com_imagem, 0)
  const faltando = dados.filter((g) => g.skus_com_imagem < g.skus)
  return (
    <div className="space-y-2 rounded-lg border bg-card p-3 text-sm">
      <div className="flex flex-wrap items-center gap-3">
        <span className="font-medium">Cobertura de imagens</span>
        <span>{skus ? `${formatNumber(com)} de ${formatNumber(skus)} SKUs com imagem (${((100 * com) / skus).toFixed(1)}%)` : 'Rode o mapeamento para medir.'}</span>
        <Button size="sm" variant="outline" className="ml-auto" disabled={varrer.isPending} onClick={() => varrer.mutate()}><RefreshCw className="mr-1 h-4 w-4" />Mapear origem (varredura completa)</Button>
      </div>
      {progresso && <div className="text-muted-foreground">{progresso} (mantenha esta aba aberta; pode levar vários minutos)</div>}
      {faltando.length > 0 && (
        <details>
          <summary className="cursor-pointer">{faltando.length} grupo(s) com SKUs sem imagem</summary>
          <ul className="mt-1 space-y-0.5">
            {faltando.map((g) => <li key={g.grupo_produto}>{g.grupo_produto}: {g.skus_com_imagem}/{g.skus} ({g.pct_com_imagem}%)</li>)}
          </ul>
        </details>
      )}
    </div>
  )
}
