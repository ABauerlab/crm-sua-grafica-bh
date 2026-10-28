-- Pedido manual: o dono pode lançar item que não está no catálogo (sem SKU). O item é marcado como fora_catalogo e não trava Produção.
-- Aditiva e idempotente. O agente continua sem poder vender fora do catálogo (orcamento_itens segue exigindo SKU).
alter table public.order_items add column if not exists fora_catalogo boolean not null default false;

create or replace function private.order_items_validar() returns trigger
language plpgsql set search_path = ''
as $$
declare
  pr public.parametros_comerciais%rowtype;
  v_pct numeric;
begin
  select * into pr from public.parametros_comerciais where id = 1;
  if pr.exigir_sku_pedidos and not new.fora_catalogo and tg_op = 'INSERT' and (new.code is null or btrim(new.code) = '') then
    raise exception 'Item sem SKU não pode entrar no pedido. Marque "item fora do catálogo" se for um item manual.' using errcode = 'P0001';
  end if;
  if tg_op = 'INSERT' or new.unit_price is distinct from old.unit_price or new.unit_cost is distinct from old.unit_cost or new.qty is distinct from old.qty then
    v_pct := (private.taxa_pagamento(null) ->> 'pct')::numeric;
    if new.unit_cost > 0 and new.unit_price * (1 - pr.imposto_pct / 100 - v_pct / 100) < new.unit_cost then
      raise exception 'Preço abaixo do piso duro (%): o item daria prejuízo.', private.brl(round(new.unit_cost / (1 - pr.imposto_pct / 100 - v_pct / 100), 2))
        using errcode = 'P0001';
    end if;
  end if;
  return new;
end;
$$;

create or replace function private.orders_before_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sem_sku integer;
begin
  new.updated_at := now();
  if new.payment_status = 'aprovado' and old.payment_status is distinct from 'aprovado' then
    new.paid_at := coalesce(new.paid_at, now());
    new.payment_confirmed_at := coalesce(new.payment_confirmed_at, now());
  end if;
  if new.art_status = 'aprovada' and old.art_status is distinct from 'aprovada' then
    new.art_approved_at := coalesce(new.art_approved_at, now());
  end if;
  if new.stage is distinct from old.stage then
    if new.stage = 'pago' and new.payment_status <> 'aprovado' and not new.payment_manual then
      raise exception 'Só é possível mover para Pago com o pagamento confirmado. Confirme o pagamento manualmente se já recebeu.' using errcode = 'P0001';
    end if;
    if new.stage in ('pago', 'producao') then
      select count(*) into v_sem_sku from public.order_items i where i.order_id = new.id and not i.fora_catalogo and (i.code is null or btrim(i.code) = '');
    end if;
    if new.stage = 'producao' and v_sem_sku > 0 then
      raise exception 'Há % item(ns) sem SKU. Informe o SKU do fornecedor antes de mandar para Produção.', v_sem_sku using errcode = 'P0001';
    end if;
    if new.stage = 'pago' and v_sem_sku > 0 then
      perform private.alerta_item_sem_sku(new.conversation_id, new.contact_id, new.id, 'Pedido pago com item sem SKU: informe o código para poder produzir.');
    end if;
    if new.stage = 'producao' and new.art_status <> 'aprovada' then
      raise exception 'Só é possível mover para Produção com a arte aprovada pelo cliente.' using errcode = 'P0001';
    end if;
    new.stage_entered_at := now();
    if new.stage = 'entregue' and new.delivered_at is null then
      new.delivered_at := now();
    end if;
  end if;
  return new;
end;
$$;
