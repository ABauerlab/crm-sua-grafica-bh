import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { AlertTriangle, CheckCircle2, RefreshCw, Search } from 'lucide-react'
import { useState } from 'react'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { Sheet } from '@/components/ui/sheet'
import { Skeleton } from '@/components/ui/skeleton'
import { Switch } from '@/components/ui/switch'
import { Textarea } from '@/components/ui/textarea'
import { useToast } from '@/components/ui/toast'
import { invokeFunction } from '@/lib/api'
import { KNOWLEDGE_LIMITS, trechoPalavras, trechoProblemas } from '@/lib/knowledge'
import { supabase } from '@/lib/supabase'
import { cn } from '@/lib/utils'

interface Row {
  id: string
  slug: string | null
  titulo: string
  categoria: string | null
  quando_usar: string | null
  resposta_pronta: string | null
  fatos: string | null
  proximo_passo: string | null
  tags: string[]
  revisar: boolean
  ativo: boolean
  embedding_em: string | null
  atualizado_em: string
  usos: number
  ultimo_uso_em: string | null
  substituido_por: string | null
}
interface Sugestao { id: string; slug_novo: string; slugs_atuais: string[]; payload: Record<string, unknown>; motivo: string | null; criado_em: string }
interface Lacuna { id: string; pergunta: string; ocorrencias: number; status: 'aberta' | 'resolvida' | 'ignorada'; ultima_em: string }

const COLS = 'id,slug,titulo,categoria,quando_usar,resposta_pronta,fatos,proximo_passo,tags,revisar,ativo,embedding_em,atualizado_em,usos,ultimo_uso_em,substituido_por'

function useTrechos() {
  return useQuery({
    queryKey: ['conhecimento'],
    queryFn: async () => {
      const { data, error } = await supabase.from('conhecimento').select(COLS).order('categoria').order('titulo').limit(500)
      if (error) throw error
      return data as Row[]
    },
  })
}

function Contador({ n, max, label }: { n: number; max: number; label: string }) {
  return <span className={cn('text-xs tabular', n > max ? 'font-bold text-brand-red' : 'text-muted-foreground')}>{label}: {n}/{max} palavras</span>
}

function Editor({ row, onClose, novo }: { row: Row; onClose: () => void; novo?: boolean }) {
  const qc = useQueryClient()
  const toast = useToast()
  const [v, setV] = useState({ ...row, tagsTexto: row.tags.join(', ') })
  const t = { ...v, tags: v.tagsTexto.split(',').map((x) => x.trim()).filter(Boolean) }
  const n = trechoPalavras(t)
  const problemas = trechoProblemas(t)
  const preview = useQuery({
    queryKey: ['conhecimento-preview', v.resposta_pronta],
    enabled: !!v.resposta_pronta?.includes('{{'),
    queryFn: async () => (await supabase.rpc('conhecimento_resolver', { p_texto: v.resposta_pronta })).data as string,
  })

  const salvar = useMutation({
    mutationFn: async (revisado: boolean) => {
      const patch = {
        titulo: t.titulo.trim(), categoria: t.categoria?.trim() || null, quando_usar: t.quando_usar?.trim() || null, resposta_pronta: t.resposta_pronta?.trim() || null,
        fatos: t.fatos?.trim() || null, proximo_passo: t.proximo_passo?.trim() || null, tags: t.tags, ativo: v.ativo, revisar: !revisado,
      }
      const { error } = novo ? await supabase.from('conhecimento').insert(patch) : await supabase.from('conhecimento').update(patch).eq('id', row.id)
      if (error) throw new Error(error.message)
      // refaz o vetor logo (a reindexação automática também cobre, a cada 5 minutos)
      void invokeFunction('conhecimento', { acao: 'indexar' }).catch(() => undefined)
    },
    onSuccess: () => {
      toast('ok', 'Trecho salvo.')
      qc.invalidateQueries({ queryKey: ['conhecimento'] })
      onClose()
    },
    onError: (e: Error) => toast('error', e.message),
  })

  const F = (k: 'titulo' | 'categoria' | 'quando_usar' | 'resposta_pronta' | 'fatos' | 'proximo_passo', label: string, rows = 2) => (
    <div className="space-y-1.5">
      <Label htmlFor={`k-${k}`}>{label}</Label>
      {rows === 1 ? <Input id={`k-${k}`} value={v[k] ?? ''} onChange={(e) => setV({ ...v, [k]: e.target.value })} /> : <Textarea id={`k-${k}`} rows={rows} value={v[k] ?? ''} onChange={(e) => setV({ ...v, [k]: e.target.value })} />}
    </div>
  )

  return (
    <Sheet open onOpenChange={(o) => !o && onClose()} title={novo ? 'Novo trecho' : v.titulo} description="Trecho curto, no tom do atendente. Sem preço de produto, custo, prazo de item nem nome do fornecedor.">
      <div className="min-h-0 flex-1 space-y-3 overflow-y-auto p-4">
        {F('titulo', 'Título', 1)}
        {F('categoria', 'Categoria', 1)}
        {F('quando_usar', 'Quando usar (uma frase)')}
        {F('resposta_pronta', 'Resposta pronta (até 40 palavras, no tom do atendente)', 3)}
        <div className="flex flex-wrap justify-between gap-2"><Contador n={n.resposta} max={KNOWLEDGE_LIMITS.resposta} label="Resposta" />{preview.data && <span className="text-xs text-muted-foreground">Fica assim: “{preview.data}”</span>}</div>
        {F('fatos', 'Fatos (até 80 palavras; use [CONFIRMAR] quando precisar validar)', 3)}
        <div className="flex flex-wrap justify-between gap-2"><Contador n={n.fatos} max={KNOWLEDGE_LIMITS.fatos} label="Fatos" /><Contador n={n.total} max={KNOWLEDGE_LIMITS.total} label="Trecho todo" /></div>
        {F('proximo_passo', 'Próximo passo', 1)}
        <div className="space-y-1.5">
          <Label htmlFor="k-tags">Frases que o cliente usa (separe por vírgula)</Label>
          <Textarea id="k-tags" rows={3} value={v.tagsTexto} onChange={(e) => setV({ ...v, tagsTexto: e.target.value })} />
          <p className="text-xs text-muted-foreground">Ajudam a achar o trecho quando o cliente escreve diferente. Variáveis aceitas: {'{{arte_basica}} {{arte_frete}} {{pedido_minimo}} {{validade}} {{horario}} {{persona_vendas}} {{persona_pos_pagamento}} {{cupom_percentual}} {{cupom_teto}} {{cupom_validade_dias}} {{troca_prazo}}'}.</p>
        </div>
        <label className="flex items-center gap-2 text-sm"><Switch checked={v.ativo} onCheckedChange={(c) => setV({ ...v, ativo: c })} /> Trecho ativo</label>
        {problemas.length > 0 && (
          <ul role="alert" className="space-y-1 rounded-md border border-brand-red/40 bg-brand-red/5 p-3 text-sm">
            {problemas.map((p) => <li key={p} className="flex gap-2"><AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-brand-red" aria-hidden /> {p}</li>)}
          </ul>
        )}
        {v.fatos?.includes('[CONFIRMAR]') && <p className="rounded-md border border-brand-yellow bg-brand-yellow/10 p-2.5 text-sm">Este trecho tem [CONFIRMAR]. Valide a informação, apague a marca e só então marque como revisado.</p>}
      </div>
      <footer className="flex flex-wrap justify-end gap-2 border-t p-3">
        <Button variant="outline" onClick={onClose}>Cancelar</Button>
        <Button variant="outline" disabled={!t.titulo.trim() || salvar.isPending} onClick={() => salvar.mutate(false)}>Salvar e manter em revisão</Button>
        <Button disabled={!t.titulo.trim() || salvar.isPending || problemas.length > 0 || !!v.fatos?.includes('[CONFIRMAR]')} onClick={() => salvar.mutate(true)}><CheckCircle2 className="h-4 w-4" /> Salvar e marcar revisado</Button>
      </footer>
    </Sheet>
  )
}

function Lacunas({ onCriar }: { onCriar: (trechoId: string) => void }) {
  const qc = useQueryClient()
  const toast = useToast()
  const { data, isLoading } = useQuery({
    queryKey: ['conhecimento-lacunas'],
    queryFn: async () => {
      const { data, error } = await supabase.from('conhecimento_lacunas').select('id,pergunta,ocorrencias,status,ultima_em').order('status').order('ocorrencias', { ascending: false }).limit(200)
      if (error) throw error
      return data as Lacuna[]
    },
  })
  const marcar = useMutation({
    mutationFn: async ({ id, status }: { id: string; status: Lacuna['status'] }) => {
      const { error } = await supabase.from('conhecimento_lacunas').update({ status }).eq('id', id)
      if (error) throw new Error(error.message)
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['conhecimento-lacunas'] }),
    onError: (e: Error) => toast('error', e.message),
  })
  const criar = useMutation({
    mutationFn: async (l: Lacuna) => {
      const { data, error } = await supabase.rpc('conhecimento_criar_de_lacuna', { p_lacuna: l.id })
      if (error) throw new Error(error.message)
      return (data as { trecho_id: string }).trecho_id
    },
    onSuccess: (id) => { qc.invalidateQueries({ queryKey: ['conhecimento'] }); qc.invalidateQueries({ queryKey: ['conhecimento-lacunas'] }); onCriar(id) },
    onError: (e: Error) => toast('error', e.message),
  })
  if (isLoading) return <Skeleton className="h-24 w-full" />
  if (!data?.length) return <p className="rounded-md border border-dashed p-4 text-sm text-muted-foreground">Nenhuma pergunta sem resposta. Quando o agente não achar um trecho, a pergunta aparece aqui para você escrever o trecho que falta.</p>
  return (
    <ul className="divide-y rounded-md border">
      {data.map((l) => (
        <li key={l.id} className="flex flex-wrap items-center justify-between gap-2 px-3 py-2">
          <div className="min-w-0"><p className="truncate text-sm font-semibold">{l.pergunta}</p><p className="text-xs text-muted-foreground tabular">{l.ocorrencias}x · última em {new Date(l.ultima_em).toLocaleDateString('pt-BR')} · {l.status}</p></div>
          {l.status === 'aberta' && <span className="flex flex-wrap gap-1"><Button size="sm" onClick={() => criar.mutate(l)} disabled={criar.isPending}>Criar trecho a partir desta pergunta</Button><Button size="sm" variant="outline" onClick={() => marcar.mutate({ id: l.id, status: 'resolvida' })}>Já escrevi o trecho</Button><Button size="sm" variant="ghost" onClick={() => marcar.mutate({ id: l.id, status: 'ignorada' })}>Ignorar</Button></span>}
        </li>
      ))}
    </ul>
  )
}

function Sugestoes({ trechos }: { trechos: Row[] }) {
  const qc = useQueryClient()
  const toast = useToast()
  const { data, isLoading } = useQuery({
    queryKey: ['conhecimento-sugestoes'],
    queryFn: async () => {
      const { data, error } = await supabase.from('conhecimento_sugestoes').select('id,slug_novo,slugs_atuais,payload,motivo,criado_em').eq('status', 'pendente').order('criado_em')
      if (error) throw error
      return data as Sugestao[]
    },
  })
  const decidir = useMutation({
    mutationFn: async ({ id, aceitar }: { id: string; aceitar: boolean }) => {
      const { data, error } = await supabase.rpc('conhecimento_sugestao_decidir', { p_sugestao: id, p_aceitar: aceitar })
      if (error) throw new Error(error.message)
      return data
    },
    onSuccess: () => { toast('ok', 'Pronto.'); qc.invalidateQueries({ queryKey: ['conhecimento-sugestoes'] }); qc.invalidateQueries({ queryKey: ['conhecimento'] }) },
    onError: (e: Error) => toast('error', e.message),
  })
  if (isLoading) return <Skeleton className="h-24 w-full" />
  if (!data?.length) return <p className="rounded-md border border-dashed p-4 text-sm text-muted-foreground">Nenhuma sugestão pendente. Quando uma importação traz uma versão nova de um trecho que você já editou, ela aparece aqui para você comparar. O seu texto nunca é trocado sem a sua decisão.</p>
  return (
    <ul className="space-y-3">
      {data.map((x) => {
        const atual = trechos.find((t) => x.slugs_atuais.includes(t.slug ?? ''))
        return (
          <li key={x.id} className="space-y-2 rounded-md border p-3">
            <p className="text-sm font-semibold">{String(x.payload.titulo)} <span className="font-normal text-muted-foreground">({x.motivo})</span></p>
            <div className="grid gap-2 text-sm sm:grid-cols-2">
              <div className="rounded-md bg-secondary/50 p-2"><p className="mb-1 text-xs font-semibold text-muted-foreground">Seu texto atual</p>{atual?.resposta_pronta ?? '(trecho não encontrado)'}</div>
              <div className="rounded-md bg-brand-green/10 p-2"><p className="mb-1 text-xs font-semibold text-muted-foreground">Versão nova</p>{String(x.payload.resposta_pronta)}</div>
            </div>
            <div className="flex justify-end gap-2"><Button size="sm" variant="outline" onClick={() => decidir.mutate({ id: x.id, aceitar: false })}>Manter o meu</Button><Button size="sm" onClick={() => decidir.mutate({ id: x.id, aceitar: true })}>Usar a versão nova</Button></div>
          </li>
        )
      })}
    </ul>
  )
}

/** Configurações > Conhecimento: o banco de conhecimento do agente (trechos curtos de vendedor), lacunas e taxa de acerto. */
export default function KnowledgeTab() {
  const qc = useQueryClient()
  const toast = useToast()
  const { data, isLoading } = useTrechos()
  const [busca, setBusca] = useState('')
  const [cat, setCat] = useState('')
  const [soRevisar, setSoRevisar] = useState(false)
  const [edit, setEdit] = useState<{ row: Row; novo?: boolean } | null>(null)
  const [aba, setAba] = useState<'trechos' | 'lacunas' | 'sugestoes'>('trechos')
  const [ordem, setOrdem] = useState<'categoria' | 'usos' | 'recente'>('categoria')
  const [uso, setUso] = useState<'' | 'nunca' | 'usados'>('')
  const taxa = useQuery({
    queryKey: ['conhecimento-taxa'],
    queryFn: async () => (await supabase.rpc('conhecimento_taxa', { p_dias: 30 })).data as { consultas: number; acertos: number; taxa_pct: number | null; via_faq: number },
  })

  const reindexar = useMutation({
    mutationFn: async () => {
      let faltam = 1
      await invokeFunction('conhecimento', { acao: 'reindexar_todos' })
      let voltas = 0
      while (faltam > 0 && voltas++ < 20) {
        const r = await invokeFunction<{ faltam: number; erros: string[] }>('conhecimento', { acao: 'indexar' })
        faltam = r.faltam
        if (r.erros.length) throw new Error(`Falhou em ${r.erros.length} trecho(s). Tente de novo em instantes.`)
      }
    },
    onSuccess: () => { toast('ok', 'Vetores refeitos.'); qc.invalidateQueries({ queryKey: ['conhecimento'] }) },
    onError: (e: Error) => toast('error', e.message),
  })

  const t = busca.trim().toLowerCase()
  const lista = (data ?? []).filter((r) => (!cat || r.categoria === cat) && (!soRevisar || r.revisar) && (uso === '' || (uso === 'nunca' ? r.usos === 0 : r.usos > 0)) && (!t || `${r.titulo} ${r.quando_usar} ${r.resposta_pronta} ${r.tags.join(' ')}`.toLowerCase().includes(t)))
  if (ordem === 'usos') lista.sort((a, b) => b.usos - a.usos)
  if (ordem === 'recente') lista.sort((a, b) => (b.ultimo_uso_em ?? '').localeCompare(a.ultimo_uso_em ?? ''))
  const cats = [...new Set((data ?? []).map((r) => r.categoria).filter(Boolean))] as string[]
  const pendRev = (data ?? []).filter((r) => r.revisar).length
  const semVetor = (data ?? []).filter((r) => r.ativo && !r.embedding_em).length

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-2">
        <Badge className="bg-secondary px-2 py-1 text-xs">{data?.length ?? 0} trechos</Badge>
        <Badge className={cn('px-2 py-1 text-xs', pendRev ? 'bg-brand-yellow/30' : 'bg-brand-green/10 text-brand-green')}>{pendRev} para revisar</Badge>
        <Badge className={cn('px-2 py-1 text-xs', semVetor ? 'bg-brand-yellow/30' : 'bg-secondary')}>{semVetor} aguardando indexação</Badge>
        <Badge className="bg-secondary px-2 py-1 text-xs" title="Perguntas em que o agente achou um trecho, nos últimos 30 dias">Taxa de acerto: {taxa.data?.taxa_pct == null ? 'sem consultas' : `${taxa.data.taxa_pct}% de ${taxa.data.consultas}`}</Badge>
        <span className="ml-auto flex gap-2">
          <Button size="sm" variant="outline" onClick={() => reindexar.mutate()} disabled={reindexar.isPending}><RefreshCw className={cn('h-4 w-4', reindexar.isPending && 'animate-spin')} /> {reindexar.isPending ? 'Reindexando…' : 'Reindexar tudo'}</Button>
          <Button size="sm" onClick={() => setEdit({ novo: true, row: { id: '', slug: null, titulo: '', categoria: null, quando_usar: '', resposta_pronta: '', fatos: '', proximo_passo: '', tags: [], revisar: true, ativo: true, embedding_em: null, atualizado_em: '', usos: 0, ultimo_uso_em: null, substituido_por: null } })}>Novo trecho</Button>
        </span>
      </div>

      <div className="flex gap-1" role="tablist" aria-label="Conhecimento">
        <button role="tab" aria-selected={aba === 'trechos'} onClick={() => setAba('trechos')} className={cn('rounded-md border px-3 py-1 text-sm font-semibold', aba === 'trechos' && 'bg-ink text-white')}>Trechos</button>
        <button role="tab" aria-selected={aba === 'lacunas'} onClick={() => setAba('lacunas')} className={cn('rounded-md border px-3 py-1 text-sm font-semibold', aba === 'lacunas' && 'bg-ink text-white')}>Perguntas sem resposta</button>
        <button role="tab" aria-selected={aba === 'sugestoes'} onClick={() => setAba('sugestoes')} className={cn('rounded-md border px-3 py-1 text-sm font-semibold', aba === 'sugestoes' && 'bg-ink text-white')}>Sugestões da importação</button>
      </div>

      {aba === 'lacunas' ? <Lacunas onCriar={(id) => { const r = (data ?? []).find((x) => x.id === id); if (r) setEdit({ row: r }); else void qc.fetchQuery({ queryKey: ['conhecimento'], staleTime: 0 }).then((rows) => { const n = (rows as Row[] | undefined)?.find((x) => x.id === id); if (n) setEdit({ row: n }) }) }} /> : aba === 'sugestoes' ? <Sugestoes trechos={data ?? []} /> : (
        <>
          <div className="flex flex-wrap items-center gap-2">
            <div className="relative min-w-52 flex-1"><Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" aria-hidden /><Input className="pl-9" aria-label="Buscar trecho" placeholder="Buscar trecho" value={busca} onChange={(e) => setBusca(e.target.value)} /></div>
            <Select aria-label="Categoria" className="w-48" value={cat} onChange={(e) => setCat(e.target.value)}><option value="">Todas as categorias</option>{cats.map((c) => <option key={c} value={c}>{c}</option>)}</Select>
            <Select aria-label="Uso" className="w-40" value={uso} onChange={(e) => setUso(e.target.value as typeof uso)}><option value="">Todos os usos</option><option value="usados">Já usados</option><option value="nunca">Nunca usados</option></Select>
            <Select aria-label="Ordenar" className="w-44" value={ordem} onChange={(e) => setOrdem(e.target.value as typeof ordem)}><option value="categoria">Por categoria</option><option value="usos">Mais usados</option><option value="recente">Usados há pouco</option></Select>
            <label className="flex items-center gap-2 text-sm"><Switch checked={soRevisar} onCheckedChange={setSoRevisar} /> Só para revisar</label>
          </div>
          {isLoading ? <Skeleton className="h-40 w-full" /> : (
            <ul className="divide-y rounded-md border">
              {lista.map((r) => {
                const n = trechoPalavras(r)
                const acima = n.total > KNOWLEDGE_LIMITS.total || n.resposta > KNOWLEDGE_LIMITS.resposta || n.fatos > KNOWLEDGE_LIMITS.fatos
                return (
                  <li key={r.id}>
                    <button className="flex w-full flex-wrap items-center justify-between gap-2 px-3 py-2 text-left hover:bg-secondary/50" onClick={() => setEdit({ row: r })}>
                      <span className="min-w-0"><span className="block truncate text-sm font-semibold">{r.titulo}</span><span className="block truncate text-xs text-muted-foreground">{r.resposta_pronta}</span></span>
                      <span className="flex shrink-0 items-center gap-1">
                        {acima && <Badge className="bg-brand-red/10 text-brand-red" title="Passa do limite de palavras">Acima do limite</Badge>}
                        {r.fatos?.includes('[CONFIRMAR]') && <Badge className="bg-brand-yellow/30">Confirmar</Badge>}
                        {r.revisar && <Badge className="bg-brand-yellow/30">Revisar</Badge>}
                        {!r.ativo && <Badge className="bg-ink/10" title={r.substituido_por ? `Substituído por ${r.substituido_por}` : undefined}>{r.substituido_por ? 'Substituído' : 'Inativo'}</Badge>}
                        {r.ativo && !r.embedding_em && <Badge className="bg-secondary">Sem vetor</Badge>}
                        <Badge className="bg-secondary tabular" title="Quantas vezes o agente recuperou este trecho">{r.usos} usos</Badge>
                        <Badge className="bg-secondary tabular" title="Última vez que o agente usou este trecho">{r.ultimo_uso_em ? `usado em ${new Date(r.ultimo_uso_em).toLocaleDateString('pt-BR')}` : 'nunca usado'}</Badge>
                        <Badge className="bg-secondary tabular">{n.total} pal.</Badge>
                      </span>
                    </button>
                  </li>
                )
              })}
              {lista.length === 0 && <li className="px-3 py-6 text-center text-sm text-muted-foreground">Nenhum trecho encontrado.</li>}
            </ul>
          )}
        </>
      )}
      {edit && <Editor key={edit.row.id || 'novo'} row={edit.row} novo={edit.novo} onClose={() => setEdit(null)} />}
    </div>
  )
}
