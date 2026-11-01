import { Input } from '@/components/ui/input'
import { Select } from '@/components/ui/select'
import { METODOS_PAGAMENTO } from '@/lib/orders'

export interface MetodoEscolhido {
  metodo: string
  parcelas: number
}

/** Escolha explícita do método de pagamento. Nunca presume crédito: sem escolha, não segue. */
export function MetodoPagamentoField({ value, onChange, label = 'Método de pagamento' }: { value: MetodoEscolhido; onChange: (v: MetodoEscolhido) => void; label?: string }) {
  return (
    <div className="space-y-2">
      <label className="text-sm font-bold" htmlFor="metodo-pagamento">{label} <span className="text-brand-red">*</span></label>
      <Select id="metodo-pagamento" required value={value.metodo} onChange={(e) => onChange({ metodo: e.target.value, parcelas: 1 })}>
        <option value="">Escolha o método</option>
        {METODOS_PAGAMENTO.map((m) => <option key={m.value} value={m.value}>{m.label}</option>)}
      </Select>
      {value.metodo === 'cartao_credito' && (
        <div className="flex items-center gap-2">
          <label className="text-sm" htmlFor="parcelas">Parcelas</label>
          <Input id="parcelas" type="number" min={1} max={12} className="w-20" value={value.parcelas} onChange={(e) => onChange({ ...value, parcelas: Math.min(12, Math.max(1, Math.floor(Number(e.target.value) || 1))) })} />
        </div>
      )}
      <p className="text-xs text-muted-foreground">Dinheiro e transferência não têm taxa. A taxa de cada método é aplicada só ao método escolhido.</p>
    </div>
  )
}
