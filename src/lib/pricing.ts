// Regras de proteção de preço. O preço vem do banco/digitado pelo dono; aqui só se COMPARA com os limites configurados.

export interface PricingRules {
  floor_multiplier: number
  max_discount_pct: number
  min_net_profit: number
  tax_pct: number
  payment_fee_pct: number
}

export const DEFAULT_PRICING: PricingRules = {
  floor_multiplier: 1.5,
  max_discount_pct: 10,
  min_net_profit: 60,
  tax_pct: 6,
  payment_fee_pct: 1.5,
}

export interface PriceAlert {
  code: 'below_floor' | 'discount_too_high' | 'profit_too_low'
  message: string
}

/** Piso unitário: custo x multiplicador. */
export const unitFloor = (unitCost: number, rules: PricingRules) => Math.round(unitCost * rules.floor_multiplier * 100) / 100

export function priceAlerts(
  input: { items: { description: string; unit_cost: number; unit_price: number }[]; discountPct: number; netProfit: number },
  rules: PricingRules,
  fmt: (v: number) => string,
): PriceAlert[] {
  const alerts: PriceAlert[] = []
  for (const it of input.items) {
    if (it.unit_cost > 0 && it.unit_price < unitFloor(it.unit_cost, rules)) {
      alerts.push({
        code: 'below_floor',
        message: `"${it.description || 'Item'}" está abaixo do piso (${fmt(unitFloor(it.unit_cost, rules))} por unidade, custo x ${rules.floor_multiplier}).`,
      })
    }
  }
  if (input.discountPct > rules.max_discount_pct) {
    alerts.push({
      code: 'discount_too_high',
      message: `Desconto de ${input.discountPct}% acima do máximo sem consulta (${rules.max_discount_pct}%).`,
    })
  }
  if (input.items.length > 0 && input.netProfit < rules.min_net_profit) {
    alerts.push({
      code: 'profit_too_low',
      message: `Lucro líquido de ${fmt(input.netProfit)} abaixo do mínimo por pedido (${fmt(rules.min_net_profit)}).`,
    })
  }
  return alerts
}

/** Prévia só para decidir se mostra alerta antes de salvar. Os valores exibidos vêm da view order_financials do banco. */
export function previewNetProfit(
  items: { qty: number; unit_cost: number; unit_price: number }[],
  discountPct: number,
  taxPct: number,
  feePct: number,
): number {
  const gross = items.reduce((n, i) => n + i.qty * i.unit_price, 0)
  const cost = items.reduce((n, i) => n + i.qty * i.unit_cost, 0)
  const total = gross * (1 - discountPct / 100)
  return Math.round((total * (1 - (taxPct + feePct) / 100) - cost) * 100) / 100
}
