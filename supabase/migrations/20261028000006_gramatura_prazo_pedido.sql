-- Gramatura separada no produto e prazo do fornecedor levado para o pedido.

-- Gramatura em gramas (ex.: "10g", "300 g", "150g/m²" na descrição). A reimportação da planilha passa a preencher direto.
alter table public.products add column if not exists grammage integer;

update public.products
set grammage = (substring(description from '(?i)(\d{1,4})\s*(?:g/m|gr?\M|gramas)'))::integer
where grammage is null
  and description ~* '\d{1,4}\s*(?:g/m|gr?\M|gramas)';

-- Prazo em dias de cada item (copiado do catálogo) e o prazo do pedido (o maior entre os itens).
alter table public.order_items add column if not exists lead_days integer check (lead_days is null or lead_days >= 0);
alter table public.orders add column if not exists lead_days integer check (lead_days is null or lead_days >= 0);

create or replace function public.sync_order_lead_days() returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_order uuid := coalesce(new.order_id, old.order_id);
begin
  update public.orders
  set lead_days = (select max(lead_days) from public.order_items where order_id = v_order)
  where id = v_order;
  return null;
end;
$$;

drop trigger if exists order_items_sync_lead_days on public.order_items;
create trigger order_items_sync_lead_days
  after insert or update of lead_days or delete on public.order_items
  for each row execute function public.sync_order_lead_days();

revoke execute on function public.sync_order_lead_days() from public, anon, authenticated;

-- A view precisa ser recriada para incluir a coluna nova (preços continuam calculados no banco)
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
