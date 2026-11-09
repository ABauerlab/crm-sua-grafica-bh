import { useQueryClient } from '@tanstack/react-query'
import { FileSpreadsheet } from 'lucide-react'
import { useRef, useState } from 'react'
import { Button } from '@/components/ui/button'
import { Modal } from '@/components/ui/sheet'
import { useToast } from '@/components/ui/toast'
import { conferirLinhas, linhasDaPlanilha, type LinhaPlanilha } from '@/lib/planilha-precos'
import { formatNumber } from '@/lib/money'
import { supabase } from '@/lib/supabase'

type Previa = { arquivo: string; linhas: LinhaPlanilha[]; resumo: ReturnType<typeof conferirLinhas>['resumo']; problemas: string[] }
type Relatorio = Record<string, number | string | null>

const LOTE = 2000

/** Importa a planilha oficial de preços de venda: confere no navegador, envia em lotes e aplica em lotes (cada chamada fica abaixo de 8 s). */
export function PlanilhaPrecosImport() {
  const file = useRef<HTMLInputElement>(null)
  const toast = useToast()
  const qc = useQueryClient()
  const [previa, setPrevia] = useState<Previa | null>(null)
  const [progresso, setProgresso] = useState<string | null>(null)
  const [relatorio, setRelatorio] = useState<Relatorio | null>(null)

  async function ler(f: File) {
    try {
      const XLSX = await import('xlsx')
      const wb = XLSX.read(await f.arrayBuffer(), { type: 'array' })
      const aba = wb.SheetNames.find((n) => /pre[cç]os de venda/i.test(n)) ?? wb.SheetNames[0]
      const tabela = XLSX.utils.sheet_to_json<unknown[]>(wb.Sheets[aba], { header: 1, raw: true, defval: '' })
      const linhas = linhasDaPlanilha(tabela)
      const r = conferirLinhas(linhas)
      setRelatorio(null)
      setPrevia({ arquivo: f.name, linhas, resumo: r.resumo, problemas: r.problemas })
    } catch (e) {
      toast('error', (e as Error).message)
    }
  }

  async function aplicar() {
    if (!previa) return
    try {
      for (let i = 0; i < previa.linhas.length; i += LOTE) {
        setProgresso(`Enviando ${formatNumber(Math.min(i + LOTE, previa.linhas.length))} de ${formatNumber(previa.linhas.length)}…`)
        const { error } = await supabase.rpc('importar_precos_planilha', { p_linhas: previa.linhas.slice(i, i + LOTE) })
        if (error) throw error
      }
      let depois: string | null = null
      let feitos = 0
      for (;;) {
        setProgresso(`Aplicando no catálogo e na vitrine… ${formatNumber(feitos)}`)
        const { data, error } = await supabase.rpc('aplicar_planilha_precos_lote', { p_depois: depois, p_limite: LOTE })
        if (error) throw error
        const r = data as { processados: number; ultimo: string | null; fim: boolean }
        feitos += r.processados
        if (r.fim) break
        depois = r.ultimo
      }
      const { data: rel, error: e2 } = await supabase.rpc('planilha_precos_relatorio')
      if (e2) throw e2
      setRelatorio(rel as Relatorio)
      toast('ok', 'Preços da planilha aplicados.')
      qc.invalidateQueries({ queryKey: ['products'] })
      qc.invalidateQueries({ queryKey: ['catalogo-precos'] })
    } catch (e) {
      toast('error', (e as Error).message)
    } finally {
      setProgresso(null)
    }
  }

  const bloqueia = !!previa && (previa.resumo.duplicados > 0 || previa.resumo.linhas === 0)

  return (
    <>
      <input ref={file} type="file" accept=".xlsx,.xls" className="sr-only" aria-label="Planilha de preços de venda (Excel)" onChange={(e) => { const f = e.target.files?.[0]; if (f) void ler(f); e.target.value = '' }} />
      <Button variant="outline" size="sm" onClick={() => file.current?.click()} title="Planilha oficial com o preço de venda de cada SKU">
        <FileSpreadsheet className="h-4 w-4" /> Importar planilha de preços
      </Button>
      <Modal open={!!previa} onOpenChange={(o) => { if (!o && !progresso) setPrevia(null) }} title="Planilha de preços de venda"
        description="O preço de venda de cada SKU passa a ser o da planilha. Linhas abaixo de custo x 1,5 ou com lucro bruto menor que o mínimo não entram.">
        {previa && (
          <div className="space-y-3 text-sm">
            <p className="text-muted-foreground">{previa.arquivo}</p>
            <dl className="grid grid-cols-2 gap-2">
              <dt>Linhas</dt><dd className="text-right font-bold tabular">{formatNumber(previa.resumo.linhas)}</dd>
              <dt>Categorias</dt><dd className="text-right tabular">{formatNumber(previa.resumo.categorias)}</dd>
              <dt>SKUs repetidos</dt><dd className="text-right tabular">{previa.resumo.duplicados}</dd>
              <dt>Sem final ,90</dt><dd className="text-right tabular">{previa.resumo.sem_terminacao_90}</dd>
              <dt>Abaixo de custo x 1,5</dt><dd className="text-right tabular">{previa.resumo.abaixo_do_piso}</dd>
              <dt>Lucro bruto abaixo do mínimo</dt><dd className="text-right tabular">{previa.resumo.lucro_bruto_abaixo_do_minimo}</dd>
            </dl>
            {previa.problemas.length > 0 && (
              <ul className="max-h-28 overflow-auto rounded border bg-secondary/40 p-2 text-xs">{previa.problemas.slice(0, 20).map((p) => <li key={p}>{p}</li>)}</ul>
            )}
            {relatorio && (
              <div className="rounded border bg-secondary/40 p-2 text-xs">
                <p className="font-bold">Resultado</p>
                <p>Na vitrine do site: {formatNumber(Number(relatorio.na_vitrine))}</p>
                <p>Planilha sem item no catálogo: {formatNumber(Number(relatorio.planilha_sem_catalogo))}</p>
                <p>Catálogo sem preço de planilha (segue a fórmula antiga): {formatNumber(Number(relatorio.catalogo_sem_preco_de_planilha))}</p>
                <p>Barrados pela trava: {formatNumber(Number(relatorio.barrados_pela_trava))}</p>
              </div>
            )}
            <div className="flex justify-end gap-2">
              <Button variant="outline" onClick={() => setPrevia(null)} disabled={!!progresso}>{relatorio ? 'Fechar' : 'Cancelar'}</Button>
              {!relatorio && <Button onClick={() => void aplicar()} disabled={bloqueia || !!progresso}>{progresso ?? 'Aplicar preços'}</Button>}
            </div>
          </div>
        )}
      </Modal>
    </>
  )
}
