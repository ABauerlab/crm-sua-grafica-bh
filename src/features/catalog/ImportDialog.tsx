import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { AlertTriangle, CheckCircle2, Download } from 'lucide-react'
import { useMemo, useState } from 'react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { Sheet } from '@/components/ui/sheet'
import { useToast } from '@/components/ui/toast'
import { downloadCsv } from '@/lib/csv'
import { formatNumber } from '@/lib/money'
import { buildProducts, guessHeaderRow, guessMapping, type Field, type ImportItem } from '@/lib/spreadsheet'
import { supabase } from '@/lib/supabase'

const LABELS: Record<Field, string> = {
  code: 'Código (SKU)',
  category: 'Categoria',
  description: 'Descrição do serviço',
  colors: 'Cores',
  weight: 'Peso (g)',
  qty: 'Quantidade (Qtde)',
  size: 'Tamanho em mm (Tam)',
  lead: 'Prazo em dias úteis',
  cost: 'Custo (Preço do fornecedor)',
}
const REQUIRED: Field[] = ['description', 'cost']
const CHUNK = 1000

export interface Previa {
  lidas: number
  linhas_candidatas_arquivo: number | null
  confere: boolean
  novas: number
  alteradas: number
  iguais: number
  sem_sku: number
  sem_sku_novas: number
  duplicadas_iguais: number
  conflitos: number
  rejeitadas: number
  removidos: number
  acima_do_limite: number
  limite_pct: number
  pisos_que_mudam: number
  cfv02_custo: number | null
  cfv02_esperado: number
  razao_mediana_custo: number | null
  itens_comparados: number
  alertas: string[]
  desativados?: number
  nao_competitivos_agora?: number
  inseridas?: number
  atualizadas?: number
}

/** Alertas que exigem confirmação do dono antes de aplicar. */
const GRAVES = ['cfv02_diverge', 'cfv02_ausente', 'valores_parecem_inflados_80pct', 'valores_parecem_reduzidos', 'muitos_itens_removidos', 'total_nao_confere_com_o_arquivo', 'linhas_sem_destino']

export const ALERTA_TEXTO: Record<string, string> = {
  cfv02_diverge: 'O custo do CFV02 não é R$ 75,99 (o valor da tabela atual). Pode ser outra tabela.',
  cfv02_ausente: 'O CFV02 não está no arquivo. Confirme se é a tabela completa.',
  valores_parecem_inflados_80pct: 'Os valores parecem cerca de 80% acima dos atuais (como a tabela antiga com custo x1,8). Não aplique sem conferir.',
  valores_parecem_reduzidos: 'Os valores parecem muito abaixo dos atuais. Confira se é a tabela certa.',
  muitos_itens_removidos: 'Mais de 25% do catálogo atual não aparece neste arquivo. Pode ser uma tabela parcial.',
  total_nao_confere_com_o_arquivo: 'O total de linhas lidas não bate com o total de linhas com preço no arquivo.',
  sku_repetido_com_dados_diferentes: 'Há código repetido com dados diferentes. Essas linhas NÃO serão aplicadas até você decidir.',
  linhas_sem_destino: 'Alguma linha ficou sem destino. Não aplique e avise o suporte.',
}

type Step = 'mapear' | 'enviando' | 'previa' | 'aplicando' | 'pronto'

const Card = ({ label, value, tone }: { label: string; value: number | string; tone?: 'warn' | 'bad' }) => (
  <div className={`rounded-md border p-2.5 ${tone === 'bad' ? 'border-brand-red/50 bg-brand-red/5' : tone === 'warn' ? 'border-brand-yellow bg-brand-yellow/10' : ''}`}>
    <dt className="text-[11px] uppercase text-muted-foreground">{label}</dt>
    <dd className="text-lg font-black tabular">{typeof value === 'number' ? formatNumber(value) : value}</dd>
  </div>
)

/** Importa o catálogo do fornecedor (PDF, Excel ou CSV) em duas fases: pré-visualização das diferenças e, só depois da confirmação do dono, aplicação. */
export function ImportDialog({
  rows, fileName, file, candidatas, emitidoEm, avisos, onClose,
}: { rows: string[][]; fileName: string; file: File; candidatas: number | null; emitidoEm: string | null; avisos: string[]; onClose: () => void }) {
  const qc = useQueryClient()
  const toast = useToast()
  const [headerRow, setHeaderRow] = useState(() => guessHeaderRow(rows))
  const header = rows[headerRow] ?? []
  const [map, setMap] = useState<Record<Field, number>>(() => guessMapping(rows[guessHeaderRow(rows)] ?? []))
  const [step, setStep] = useState<Step>('mapear')
  const [limite, setLimite] = useState('20')
  const [importacao, setImportacao] = useState<string | null>(null)
  const [previa, setPrevia] = useState<Previa | null>(null)
  const [ciente, setCiente] = useState(false)
  const [desativar, setDesativar] = useState(true)
  const [progress, setProgress] = useState('')
  const [aba, setAba] = useState<'alteradas' | 'sem_sku' | 'conflito' | 'rejeitada'>('alteradas')

  const { items, skipped, ignoradas } = useMemo(() => buildProducts(rows, headerRow, map), [rows, headerRow, map])
  const ready = map.description >= 0 && map.cost >= 0 && items.length > 0
  const semCodigo = items.filter((i) => !i.sku).length
  const graves = (previa?.alertas ?? []).filter((a) => GRAVES.includes(a))

  const preparar = useMutation({
    mutationFn: async () => {
      setStep('enviando')
      // 1. o arquivo original fica guardado no bucket privado (nunca no repositório)
      setProgress('Guardando o arquivo original em local privado…')
      const bytes = await file.arrayBuffer()
      const sha = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))).map((b) => b.toString(16).padStart(2, '0')).join('')
      const seguro = fileName.replace(/[^A-Za-z0-9._-]+/g, '_')
      const path = `${new Date().toISOString().slice(0, 10)}/${crypto.randomUUID()}-${seguro}`
      const up = await supabase.storage.from('catalogo-fornecedor').upload(path, file, { contentType: file.type || undefined })
      if (up.error) throw new Error(`Não foi possível guardar o arquivo original: ${up.error.message}`)
      // 2. linhas em lotes
      const ini = await supabase.rpc('catalogo_importacao_iniciar', { p_nome: fileName, p_path: path, p_sha256: sha, p_emitido: emitidoEm, p_candidatas: candidatas ?? items.length })
      if (ini.error) throw new Error(ini.error.message)
      const id = ini.data as string
      for (let i = 0; i < items.length; i += CHUNK) {
        setProgress(`Enviando linhas ${formatNumber(Math.min(items.length, i + CHUNK))} de ${formatNumber(items.length)}…`)
        const lote = items.slice(i, i + CHUNK).map((x: ImportItem) => ({ ...x }))
        const { error } = await supabase.rpc('catalogo_importacao_lote', { p_id: id, p_linhas: lote })
        if (error) throw new Error(error.message)
      }
      setProgress('Comparando com o catálogo atual…')
      const pv = await supabase.rpc('catalogo_importacao_previa', { p_id: id, p_limite_pct: Number(limite.replace(',', '.')) || 20 })
      if (pv.error) throw new Error(pv.error.message)
      return { id, previa: pv.data as Previa }
    },
    onSuccess: (r) => {
      setImportacao(r.id)
      setPrevia(r.previa)
      setStep('previa')
    },
    onError: (e: Error) => {
      setStep('mapear')
      toast('error', e.message)
    },
  })

  const recalcular = useMutation({
    mutationFn: async () => {
      const pv = await supabase.rpc('catalogo_importacao_previa', { p_id: importacao!, p_limite_pct: Number(limite.replace(',', '.')) || 20 })
      if (pv.error) throw new Error(pv.error.message)
      return pv.data as Previa
    },
    onSuccess: (p) => setPrevia(p),
    onError: (e: Error) => toast('error', e.message),
  })

  const aplicar = useMutation({
    mutationFn: async () => {
      setStep('aplicando')
      let restantes = 1
      let feitas = 0
      while (restantes > 0) {
        const { data, error } = await supabase.rpc('catalogo_importacao_aplicar', { p_id: importacao!, p_limite: 1000, p_aceitar_alertas: ciente, p_desativar_removidos: desativar })
        if (error) throw new Error(error.message)
        const r = data as { aplicadas: number; restantes: number }
        restantes = r.restantes
        feitas += r.aplicadas
        setProgress(`Aplicadas ${formatNumber(feitas)} linhas${restantes ? `, faltam ${formatNumber(restantes)}` : ''}…`)
      }
      const { data } = await supabase.from('catalogo_importacoes').select('relatorio').eq('id', importacao!).single()
      return data!.relatorio as Previa
    },
    onSuccess: (rel) => {
      setPrevia(rel)
      setStep('pronto')
      for (const k of ['products', 'product-categories', 'catalogo-sem-sku', 'catalogo-precos']) qc.invalidateQueries({ queryKey: [k] })
      toast('ok', 'Catálogo atualizado.')
    },
    onError: (e: Error) => {
      setStep('previa')
      toast('error', e.message)
    },
  })

  const lista = useQuery({
    queryKey: ['catalogo-import-linhas', importacao, aba, previa?.limite_pct],
    enabled: !!importacao && (step === 'previa' || step === 'pronto'),
    queryFn: async () => {
      let q = supabase.from('catalogo_import_linhas').select('n,sku,categoria,descricao,quantidade,tamanho_mm,prazo_dias_uteis,custo,custo_anterior,prazo_anterior,variacao_pct,acima_limite,motivo,resultado').eq('importacao_id', importacao!).order('n').limit(60)
      if (aba === 'alteradas') q = q.in('resultado', ['alterada', 'aplicada']).not('custo_anterior', 'is', null).order('acima_limite', { ascending: false })
      else if (aba === 'sem_sku') q = q.is('sku', null).neq('resultado', 'duplicada_igual')
      else q = q.eq('resultado', aba)
      const { data, error } = await q
      if (error) throw error
      return data as Record<string, string | number | boolean | null>[]
    },
  })

  async function baixar(resultado: 'sem_sku' | 'conflito' | 'rejeitada', nome: string) {
    let q = supabase.from('catalogo_import_linhas').select('n,sku,categoria,descricao,cores,quantidade,tamanho_mm,prazo_dias_uteis,motivo').eq('importacao_id', importacao!).order('n').limit(5000)
    q = resultado === 'sem_sku' ? q.is('sku', null) : q.eq('resultado', resultado)
    const { data, error } = await q
    if (error) return toast('error', error.message)
    downloadCsv(nome, ['Linha', 'Código', 'Categoria', 'Descrição', 'Cores', 'Qtde', 'Tam', 'Prazo', 'Motivo'],
      (data ?? []).map((r) => [r.n, r.sku, r.categoria, r.descricao, r.cores, r.quantidade, r.tamanho_mm, r.prazo_dias_uteis, r.motivo]))
  }

  return (
    <Sheet open onOpenChange={(o) => !o && step !== 'enviando' && step !== 'aplicando' && onClose()} title="Importar catálogo do fornecedor" description={`${fileName} · ${formatNumber(rows.length)} linhas lidas${emitidoEm ? ` · emitido em ${emitidoEm.split('-').reverse().join('/')}` : ''}`} className="sm:max-w-4xl">
      <div className="min-h-0 flex-1 space-y-4 overflow-y-auto p-4">
        {(avisos.length > 0 || (candidatas !== null && candidatas !== rows.length - 1)) && step === 'mapear' && (
          <div role="alert" className="rounded-md border border-brand-yellow bg-brand-yellow/10 p-3 text-sm">
            <p className="font-bold">Atenção na leitura do PDF</p>
            {candidatas !== null && candidatas !== rows.length - 1 && <p>O PDF tem {formatNumber(candidatas)} linhas com preço e eu li {formatNumber(rows.length - 1)}.</p>}
            <ul className="list-disc pl-5">{avisos.slice(0, 8).map((a) => <li key={a}>{a}</li>)}</ul>
          </div>
        )}

        {step === 'mapear' && (
          <>
            <div className="space-y-1.5">
              <Label htmlFor="imp-head">Em qual linha está o cabeçalho (nomes das colunas)?</Label>
              <Select id="imp-head" value={headerRow} onChange={(e) => { const n = Number(e.target.value); setHeaderRow(n); setMap(guessMapping(rows[n] ?? [])) }}>
                {rows.slice(0, 15).map((r, i) => <option key={i} value={i}>Linha {i + 1}: {r.filter(Boolean).slice(0, 4).join(' | ') || '(vazia)'}</option>)}
              </Select>
            </div>
            <div className="grid gap-3 sm:grid-cols-2">
              {(Object.keys(LABELS) as Field[]).map((f) => (
                <div key={f} className="space-y-1.5">
                  <Label htmlFor={`imp-${f}`}>{LABELS[f]}{REQUIRED.includes(f) ? ' *' : ''}</Label>
                  <Select id={`imp-${f}`} value={map[f]} onChange={(e) => setMap({ ...map, [f]: Number(e.target.value) })}>
                    <option value={-1}>{REQUIRED.includes(f) ? 'Escolha a coluna' : 'Não tem'}</option>
                    {header.map((h, i) => <option key={i} value={i}>{h || `Coluna ${i + 1}`}</option>)}
                  </Select>
                </div>
              ))}
            </div>
            <p className="rounded-md border bg-secondary/40 p-3 text-xs text-muted-foreground">
              Cada linha é uma opção fechada de quantidade e o código identifica o item exato (CFV02 = 1.000 cartões, CFV02D = 2.000). O prazo é guardado BRUTO, em dias úteis; o dia extra de logística só entra no cálculo da data. O preço de venda não vem desta tabela: ele é calculado pelo sistema (pesquisa de mercado e trava de lucro). Linhas sem código entram como "sem código" e não são vendáveis.
            </p>
            <div>
              <h3 className="mb-1 text-xs font-bold uppercase tracking-wide">Prévia (primeiras 5 linhas)</h3>
              {items.length === 0 ? (
                <p className="rounded-md border border-dashed p-3 text-sm text-muted-foreground">Escolha as colunas de descrição e custo para ver a prévia.</p>
              ) : (
                <div className="overflow-x-auto rounded-md border">
                  <table className="w-full min-w-[820px] text-sm">
                    <thead><tr className="border-b text-left text-[11px] uppercase text-muted-foreground"><th className="px-3 py-1.5">Linha</th><th>Código</th><th>Categoria</th><th>Descrição</th><th>Cores</th><th className="text-right">Peso</th><th className="text-right">Qtde</th><th className="pl-3">Tam</th><th className="text-right">Prazo</th><th className="px-3 text-right">Custo</th></tr></thead>
                    <tbody>
                      {items.slice(0, 5).map((i) => (
                        <tr key={i.n} className="border-b last:border-0">
                          <td className="px-3 py-1.5 tabular">{i.n}</td><td className="font-mono text-xs">{i.sku ?? '—'}</td><td>{i.categoria ?? '—'}</td><td className="max-w-[220px] truncate">{i.descricao}</td><td>{i.cores ?? '—'}</td><td className="text-right tabular">{i.peso_g ?? '—'}</td><td className="text-right tabular">{i.quantidade ?? '—'}</td><td className="pl-3">{i.tamanho_mm ?? '—'}</td><td className="text-right tabular">{i.prazo ?? '—'}</td><td className="px-3 text-right tabular">{i.custo ?? '—'}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
              <p className="mt-2 text-xs text-muted-foreground">{formatNumber(skipped)} linha(s) ignoradas (títulos de seção e cabeçalhos repetidos){semCodigo > 0 ? ` · ${formatNumber(semCodigo)} sem código` : ''}.</p>
              {ignoradas.length > 0 && (
                <details className="mt-1 text-xs text-muted-foreground"><summary className="cursor-pointer">Ver as linhas ignoradas</summary><ul className="mt-1 list-disc pl-5">{ignoradas.map((l) => <li key={l}>{l}</li>)}</ul></details>
              )}
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="imp-lim">Destacar alterações de preço ou prazo acima de (%)</Label>
              <Input id="imp-lim" inputMode="decimal" className="w-28" value={limite} onChange={(e) => setLimite(e.target.value)} />
            </div>
          </>
        )}

        {(step === 'enviando' || step === 'aplicando') && (
          <div className="rounded-md border p-6 text-center" role="status" aria-live="polite">
            <p className="font-bold">{step === 'enviando' ? 'Preparando a pré-visualização…' : 'Aplicando no catálogo…'}</p>
            <p className="mt-1 text-sm text-muted-foreground">{progress}</p>
            <p className="mt-3 text-xs text-muted-foreground">Não feche esta janela.</p>
          </div>
        )}

        {(step === 'previa' || step === 'pronto') && previa && (
          <>
            <div className={`flex items-start gap-2 rounded-md border p-3 text-sm ${step === 'pronto' ? 'border-brand-green/40 bg-brand-green/5' : ''}`}>
              {step === 'pronto' ? <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0 text-brand-green" aria-hidden /> : <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden />}
              <p>
                {step === 'pronto' ? 'Importação concluída. ' : 'Nada foi gravado ainda no catálogo. '}
                Lidas <b>{formatNumber(previa.lidas)}</b>
                {previa.linhas_candidatas_arquivo !== null && <> de <b>{formatNumber(previa.linhas_candidatas_arquivo)}</b> no arquivo{previa.confere && previa.lidas === previa.linhas_candidatas_arquivo ? ' (confere)' : ''}</>}.
                {previa.cfv02_custo !== null && <> CFV02 custa <b>{previa.cfv02_custo.toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' })}</b>{previa.cfv02_custo === previa.cfv02_esperado ? ' (confere com a tabela atual)' : ` (a tabela atual é ${previa.cfv02_esperado.toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' })})`}.</>}
              </p>
            </div>

            {previa.alertas.length > 0 && (
              <ul className="space-y-1.5" role="alert">
                {previa.alertas.map((a) => (
                  <li key={a} className="flex gap-2 rounded-md border border-brand-red/40 bg-brand-red/5 p-2.5 text-sm"><AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-brand-red" aria-hidden /> {ALERTA_TEXTO[a] ?? a}</li>
                ))}
              </ul>
            )}

            <dl className="grid grid-cols-2 gap-2 sm:grid-cols-4">
              <Card label="Novas" value={step === 'pronto' ? previa.inseridas ?? previa.novas : previa.novas} />
              <Card label="Alteradas" value={step === 'pronto' ? previa.atualizadas ?? previa.alteradas : previa.alteradas} tone={previa.acima_do_limite > 0 ? 'warn' : undefined} />
              <Card label="Iguais" value={previa.iguais} />
              <Card label="Sem código" value={previa.sem_sku} tone={previa.sem_sku > 0 ? 'warn' : undefined} />
              <Card label="Duplicadas (iguais)" value={previa.duplicadas_iguais} />
              <Card label="Conflitos" value={previa.conflitos} tone={previa.conflitos > 0 ? 'bad' : undefined} />
              <Card label="Rejeitadas" value={previa.rejeitadas} tone={previa.rejeitadas > 0 ? 'bad' : undefined} />
              <Card label="Saíram da tabela" value={previa.removidos} tone={previa.removidos > 0 ? 'warn' : undefined} />
              <Card label={`Acima de ${previa.limite_pct}%`} value={previa.acima_do_limite} tone={previa.acima_do_limite > 0 ? 'warn' : undefined} />
              <Card label="Pisos que mudam" value={previa.pisos_que_mudam} />
              {step === 'pronto' && <Card label="Não competitivos agora" value={previa.nao_competitivos_agora ?? 0} />}
              {step === 'pronto' && <Card label="Desativados" value={previa.desativados ?? 0} />}
            </dl>

            <div>
              <div className="mb-2 flex flex-wrap gap-1" role="tablist" aria-label="Detalhe da importação">
                {([['alteradas', 'Preço ou prazo alterados'], ['sem_sku', 'Sem código'], ['conflito', 'Conflitos'], ['rejeitada', 'Rejeitadas']] as const).map(([k, l]) => (
                  <button key={k} role="tab" aria-selected={aba === k} onClick={() => setAba(k)} className={`rounded-md border px-2.5 py-1 text-xs font-semibold ${aba === k ? 'bg-ink text-white' : 'hover:bg-secondary'}`}>{l}</button>
                ))}
              </div>
              <div className="overflow-x-auto rounded-md border">
                <table className="w-full min-w-[760px] text-sm">
                  <thead><tr className="border-b text-left text-[11px] uppercase text-muted-foreground"><th className="px-3 py-1.5">Linha</th><th>Código</th><th>Categoria</th><th>Descrição</th><th className="text-right">Qtde</th><th>Tam</th><th className="text-right">Prazo</th>{aba === 'alteradas' ? <><th className="text-right">Custo antes</th><th className="text-right">Custo novo</th><th className="px-3 text-right">Variação</th></> : <th>Motivo</th>}</tr></thead>
                  <tbody>
                    {(lista.data ?? []).map((r) => (
                      <tr key={String(r.n)} className={`border-b last:border-0 ${r.acima_limite ? 'bg-brand-yellow/10' : ''}`}>
                        <td className="px-3 py-1.5 tabular">{r.n}</td><td className="font-mono text-xs">{r.sku ?? '—'}</td><td className="text-xs">{r.categoria ?? '—'}</td><td className="max-w-[240px] truncate">{r.descricao}</td><td className="text-right tabular">{r.quantidade ?? '—'}</td><td>{r.tamanho_mm ?? '—'}</td>
                        <td className="text-right tabular">{r.prazo_anterior !== null && r.prazo_anterior !== r.prazo_dias_uteis && aba === 'alteradas' ? `${r.prazo_anterior} → ${r.prazo_dias_uteis}` : r.prazo_dias_uteis ?? '—'}</td>
                        {aba === 'alteradas' ? <><td className="text-right tabular">{r.custo_anterior ?? '—'}</td><td className="text-right tabular">{r.custo}</td><td className="px-3 text-right tabular">{r.variacao_pct === null ? '—' : `${r.variacao_pct}%`}</td></> : <td className="text-xs">{r.motivo ?? '—'}</td>}
                      </tr>
                    ))}
                    {lista.data?.length === 0 && <tr><td colSpan={10} className="px-3 py-4 text-center text-muted-foreground">Nenhuma linha nesta lista.</td></tr>}
                  </tbody>
                </table>
              </div>
              <div className="mt-2 flex flex-wrap gap-2">
                <Button size="sm" variant="outline" onClick={() => baixar('sem_sku', 'linhas-sem-codigo.csv')}><Download className="h-4 w-4" /> Linhas sem código (CSV)</Button>
                <Button size="sm" variant="outline" onClick={() => baixar('conflito', 'conflitos.csv')}><Download className="h-4 w-4" /> Conflitos (CSV)</Button>
                <Button size="sm" variant="outline" onClick={() => baixar('rejeitada', 'rejeitadas.csv')}><Download className="h-4 w-4" /> Rejeitadas (CSV)</Button>
              </div>
            </div>

            {step === 'previa' && (
              <div className="space-y-3 rounded-md border p-3">
                <div className="flex flex-wrap items-end gap-2">
                  <div className="space-y-1.5"><Label htmlFor="imp-lim2">Destacar acima de (%)</Label><Input id="imp-lim2" className="w-24" inputMode="decimal" value={limite} onChange={(e) => setLimite(e.target.value)} /></div>
                  <Button size="sm" variant="outline" onClick={() => recalcular.mutate()} disabled={recalcular.isPending}>Recalcular destaque</Button>
                </div>
                <label className="flex items-start gap-2 text-sm"><input type="checkbox" className="mt-1" checked={desativar} onChange={(e) => setDesativar(e.target.checked)} /> Desativar os {formatNumber(previa.removidos)} item(ns) que saíram da tabela (não apaga: pedidos antigos continuam apontando para eles).</label>
                {graves.length > 0 && <label className="flex items-start gap-2 text-sm font-semibold"><input type="checkbox" className="mt-1" checked={ciente} onChange={(e) => setCiente(e.target.checked)} /> Li os alertas acima e quero aplicar mesmo assim.</label>}
              </div>
            )}
          </>
        )}
      </div>

      <footer className="flex items-center justify-between gap-2 border-t p-3">
        <span className="text-sm text-muted-foreground tabular">
          {step === 'mapear' && `${formatNumber(items.length)} linha(s) de dados lidas`}
          {step === 'previa' && 'Confira antes de aplicar'}
          {step === 'pronto' && 'Pronto'}
        </span>
        <span className="flex gap-2">
          {step === 'pronto' ? (
            <Button onClick={onClose}>Fechar</Button>
          ) : (
            <>
              <Button variant="outline" onClick={onClose} disabled={step === 'enviando' || step === 'aplicando'}>Cancelar</Button>
              {step === 'mapear' && <Button disabled={!ready || preparar.isPending} onClick={() => preparar.mutate()}>Pré-visualizar diferenças</Button>}
              {step === 'previa' && <Button disabled={aplicar.isPending || (graves.length > 0 && !ciente)} onClick={() => aplicar.mutate()}>Confirmar e aplicar</Button>}
            </>
          )}
        </span>
      </footer>
    </Sheet>
  )
}
