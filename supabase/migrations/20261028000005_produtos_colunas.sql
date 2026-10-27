-- Produtos com as mesmas colunas da planilha do fornecedor (para a equipe e para o agente de IA lerem sem interpretar texto).
alter table public.products add column if not exists colors text;
alter table public.products add column if not exists weight numeric(12, 3);
alter table public.products add column if not exists qty integer;
alter table public.products add column if not exists size text;
alter table public.products add column if not exists lead_days integer;

create index if not exists products_qty_idx on public.products (qty);

-- A view precisa ser recriada para incluir as colunas novas (preços continuam calculados no banco)
drop view if exists public.products_priced;
create view public.products_priced with (security_invoker = true) as
select
  p.*,
  round(p.cost * coalesce((select (value ->> 'floor_multiplier')::numeric from public.app_settings where key = 'pricing'), 1.5), 2) as floor_price,
  round(p.suggested_price * (1 - coalesce((select (value ->> 'max_discount_pct')::numeric from public.app_settings where key = 'pricing'), 10) / 100), 2) as max_discount_price,
  round(
    p.suggested_price * (1 - (
      coalesce((select (value ->> 'tax_pct')::numeric from public.app_settings where key = 'pricing'), 6)
      + coalesce((select (value ->> 'payment_fee_pct')::numeric from public.app_settings where key = 'pricing'), 1.5)
    ) / 100) - p.cost,
    2
  ) as est_net_profit
from public.products p;
