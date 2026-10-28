import { Copy } from 'lucide-react'
import { useToast } from '@/components/ui/toast'
import { cn } from '@/lib/utils'

/** SKU do fornecedor em destaque, com botão de copiar. É INTERNO: só aparece nas telas do dono, nunca no PDF nem numa mensagem ao cliente. */
export function SkuBadge({ sku, className }: { sku: string | null | undefined; className?: string }) {
  const toast = useToast()
  if (!sku) {
    return <span className={cn('inline-flex items-center rounded-sm bg-brand-red/10 px-1.5 py-0.5 text-[11px] font-bold text-brand-red', className)}>Sem SKU</span>
  }
  async function copy() {
    try {
      await navigator.clipboard.writeText(sku!)
      toast('ok', `SKU ${sku} copiado.`)
    } catch {
      toast('error', 'Não foi possível copiar. Selecione o código e copie à mão.')
    }
  }
  return (
    <span className={cn('inline-flex items-center overflow-hidden rounded-sm border border-ink/20 bg-secondary font-mono text-xs font-bold', className)}>
      <span className="px-1.5 py-0.5 select-all">{sku}</span>
      <button type="button" onClick={copy} aria-label={`Copiar SKU ${sku}`} className="flex h-full min-h-6 items-center border-l border-ink/20 px-1.5 text-muted-foreground hover:bg-ink/10 hover:text-foreground">
        <Copy className="h-3 w-3" aria-hidden />
      </button>
    </span>
  )
}
