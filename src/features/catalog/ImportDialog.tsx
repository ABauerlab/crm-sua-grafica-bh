import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useMemo, useState } from 'react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { Sheet } from '@/components/ui/sheet'
import { useToast } from '@/components/ui/toast'
import { formatBRL, formatNumber, parseMoney } from '@/lib/money'
import { buildProducts, guessExtras, guessHeaderRow, guessMapping, type Field } from '@/lib/spreadsheet'
import { supabase } from '@/lib/supabase'

const LABELS: Record<Field, string> = {
  code: 'Código',
  description: 'Descrição',
  category: 'Categoria (opcional)',
  cost: 'Custo',
  price: 'Preço de venda (opcional)',
}

/** Importa o catálogo do fornecedor de qualquer planilha: o dono confere quais colunas são o quê antes de gravar. */
export function ImportDialog({ rows, fileName, onClose }: { rows: string[][]; fileName: string; onClose: () => void }) {
  const qc = useQueryClient()
  const toast = useToast()
  const [headerRow, setHeaderRow] = useState(() => guessHeaderRow(rows))
  const header = rows[headerRow] ?? []
  const [map, setMap] = useState<Record<Field, number>>(() => guessMapping(rows[guessHeaderRow(rows)] ?? []))
  const [markup, setMarkup] = useState(() => {
    try {
      return localStorage.getItem('sgbh.import.markup') ?? ''
    } catch {
      return ''
    }
  })

  const [extras, setExtras] = useState<number[]>(() => {
    const h = rows[guessHeaderRow(rows)] ?? []
    return guessExtras(h, guessMapping(h))
  })
  const [progress, setProgress] = useState(0)

  const { items, skipped } = useMemo(() => buildProducts(rows, headerRow, map, extras, parseMoney(markup)), [rows, headerRow, map, extras, markup])

  const ready = map.code >= 0 && map.description >= 0 && map.cost >= 0 && items.length > 0
  const dup = items.length - new Set(items.map((i) => i.code)).size

  const run = useMutation({
    mutationFn: async () => {
      // Código repetido na mesma planilha: vale a última linha
      const unique = [...new Map(items.map((i) => [i.code, i])).values()]
      try {
        if (markup.trim()) localStorage.setItem('sgbh.import.markup', markup.trim())
      } catch {
        /* sem armazenamento */
      }
      setProgress(0)
      for (let i = 0; i < unique.length; i += 500) {
        const { error } = await supabase.from('products').upsert(unique.slice(i, i + 500), { onConflict: 'code' })
        if (error) throw new Error(error.message)
        setProgress(Math.min(unique.length, i + 500))
      }
      return unique.length
    },
    onSuccess: (n) => {
      toast('ok', `${formatNumber(n)} produto(s) importado(s).`)
      qc.invalidateQueries({ queryKey: ['products'] })
      qc.invalidateQueries({ queryKey: ['product-categories'] })
      onClose()
    },
    onError: (e: Error) => toast('error', e.message),
  })

  return (
    <Sheet open onOpenChange={(o) => !o && onClose()} title="Importar catálogo" description={`${fileName} · ${formatNumber(rows.length)} linhas`}>
      <div className="min-h-0 flex-1 space-y-4 overflow-y-auto p-4">
        <div className="space-y-1.5">
          <Label htmlFor="imp-head">Em qual linha está o cabeçalho (nomes das colunas)?</Label>
          <Select
            id="imp-head"
            value={headerRow}
            onChange={(e) => {
              const n = Number(e.target.value)
              setHeaderRow(n)
              const m = guessMapping(rows[n] ?? [])
              setMap(m)
              setExtras(guessExtras(rows[n] ?? [], m))
            }}
          >
            {rows.slice(0, 15).map((r, i) => (
              <option key={i} value={i}>
                Linha {i + 1}: {r.filter(Boolean).slice(0, 4).join(' | ') || '(vazia)'}
              </option>
            ))}
          </Select>
        </div>

        <div className="grid gap-3 sm:grid-cols-2">
          {(Object.keys(LABELS) as Field[]).map((f) => (
            <div key={f} className="space-y-1.5">
              <Label htmlFor={`imp-${f}`}>{LABELS[f]}</Label>
              <Select id={`imp-${f}`} value={map[f]} onChange={(e) => setMap({ ...map, [f]: Number(e.target.value) })}>
                <option value={-1}>{f === 'category' || f === 'price' ? 'Não tem' : 'Escolha a coluna'}</option>
                {header.map((h, i) => (
                  <option key={i} value={i}>
                    {h || `Coluna ${i + 1}`}
                  </option>
                ))}
              </Select>
            </div>
          ))}
        </div>

        <fieldset className="space-y-1.5">
          <legend className="text-sm font-medium">Colunas que entram no nome do produto</legend>
          <p className="text-xs text-muted-foreground">Na tabela do fornecedor o mesmo serviço aparece várias vezes (cores, quantidade, tamanho). Marque o que diferencia cada item.</p>
          <div className="flex flex-wrap gap-2">
            {header.map((h, i) =>
              Object.values(map).includes(i) ? null : (
                <label key={i} className="flex min-h-11 cursor-pointer items-center gap-1.5 rounded-sm border px-2.5 text-sm md:min-h-9">
                  <input type="checkbox" className="h-4 w-4 accent-[var(--brand-blue)]" checked={extras.includes(i)} onChange={(e) => setExtras(e.target.checked ? [...extras, i].sort((a, b) => a - b) : extras.filter((x) => x !== i))} />
                  {h || `Coluna ${i + 1}`}
                </label>
              ),
            )}
          </div>
        </fieldset>

        {map.price < 0 && (
          <div className="space-y-1.5">
            <Label htmlFor="imp-markup">O preço da planilha é o seu custo. Preço de venda sugerido = custo x</Label>
            <Input id="imp-markup" inputMode="decimal" className="w-32" placeholder="ex.: 2,5" value={markup} onChange={(e) => setMarkup(e.target.value)} />
            <p className="text-xs text-muted-foreground">Deixe em branco para importar com preço zero e definir depois. O preço fica gravado no banco e dali em diante o sistema só lê.</p>
          </div>
        )}

        <div>
          <h3 className="mb-1 text-xs font-bold uppercase tracking-wide">Prévia (primeiros 5)</h3>
          {items.length === 0 ? (
            <p className="rounded-md border border-dashed p-3 text-sm text-muted-foreground">Escolha as colunas de código, descrição e custo para ver a prévia.</p>
          ) : (
            <div className="overflow-x-auto rounded-md border">
              <table className="w-full min-w-[480px] text-sm">
                <thead><tr className="border-b text-left text-[11px] uppercase text-muted-foreground"><th className="px-3 py-1.5 font-medium">Código</th><th className="font-medium">Descrição</th><th className="text-right font-medium">Custo</th><th className="px-3 text-right font-medium">Preço</th></tr></thead>
                <tbody>
                  {items.slice(0, 5).map((i) => (
                    <tr key={i.code} className="border-b last:border-0"><td className="px-3 py-1.5 font-mono text-xs">{i.code}</td><td>{i.description}</td><td className="text-right tabular">{formatBRL(i.cost)}</td><td className="px-3 text-right tabular">{formatBRL(i.suggested_price)}</td></tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
          {skipped > 0 && <p className="mt-2 text-xs text-muted-foreground">{formatNumber(skipped)} linha(s) ignoradas (títulos, categorias e cabeçalhos repetidos).</p>}
          {dup > 0 && <p className="mt-2 text-xs text-brand-red">{dup} código(s) repetido(s) na planilha: vale a última linha de cada um.</p>}
        </div>
      </div>
      <footer className="flex items-center justify-between gap-2 border-t p-3">
        <span className="text-sm text-muted-foreground tabular">{formatNumber(items.length)} produto(s) prontos</span>
        <span className="flex gap-2">
          <Button variant="outline" onClick={onClose}>Cancelar</Button>
          <Button disabled={!ready || run.isPending} onClick={() => run.mutate()}>{run.isPending ? `Importando ${formatNumber(progress)} de ${formatNumber(items.length)}…` : 'Importar'}</Button>
        </span>
      </footer>
    </Sheet>
  )
}
