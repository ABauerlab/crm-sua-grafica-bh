-- Agente de IA, Etapa 1 (4/4): travas de lucro no banco, prazo com corte das 12h e sincronia do prazo de logística.
-- Nenhum caminho (agente, automação, CRM, importação) grava preço com lucro líquido negativo.
-- Pagamento confirmado NUNCA é bloqueado por estas travas: elas olham só preço e desconto, não o status do pagamento.

-- Item de orçamento: SKU existente e preço acima do piso_duro do item (custo + imposto + taxa do método do piso)
create or replace function private.orcamento_itens_validar() returns trigger
language plpgsql set search_path = ''
as $$
declare
  pr public.parametros_comerciais%rowtype;
  v_cost numeric;
  v_pct numeric;
begin
  if new.sku is null or btrim(new.sku) = '' then
    raise exception 'Item sem SKU não pode entrar no orçamento.' using errcode = 'P0001';
  end if;
  select p.cost into v_cost from public.products p where p.code = new.sku;
  if not found then
    raise exception 'SKU % não existe no catálogo.', new.sku using errcode = 'P0001';
  end if;
  select * into pr from public.parametros_comerciais where id = 1;
  v_pct := (private.taxa_pagamento(null) ->> 'pct')::numeric;
  if new.preco_unitario * new.quantidade * (1 - pr.imposto_pct / 100 - v_pct / 100) < v_cost * new.quantidade then
    raise exception 'Preço abaixo do piso duro: o item daria prejuízo. Ajuste o preço.' using errcode = 'P0001';
  end if;
  return new;
end;
$$;
revoke execute on function private.orcamento_itens_validar() from public, anon, authenticated;
drop trigger if exists orcamento_itens_validar on public.orcamento_itens;
create trigger orcamento_itens_validar before insert or update on public.orcamento_itens
  for each row execute function private.orcamento_itens_validar();

-- Subtotal do orçamento acompanha os itens
create or replace function private.orcamento_itens_recalcular() returns trigger
language plpgsql set search_path = ''
as $$
declare
  v_id uuid := coalesce(new.orcamento_id, old.orcamento_id);
begin
  update public.orcamentos o
     set subtotal = coalesce((select sum(i.quantidade * i.preco_unitario) from public.orcamento_itens i where i.orcamento_id = v_id), 0)
   where o.id = v_id;
  return null;
end;
$$;
revoke execute on function private.orcamento_itens_recalcular() from public, anon, authenticated;
drop trigger if exists orcamento_itens_recalcular on public.orcamento_itens;
create trigger orcamento_itens_recalcular after insert or update or delete on public.orcamento_itens
  for each row execute function private.orcamento_itens_recalcular();

-- Orçamento: total consistente, validade padrão e recusa de prejuízo ao sair do rascunho ou quando o total muda
create or replace function private.orcamentos_validar() returns trigger
language plpgsql set search_path = ''
as $$
declare
  pr public.parametros_comerciais%rowtype;
  f jsonb;
begin
  new.total := new.subtotal + new.arte_valor + new.frete_valor - new.desconto_valor;
  new.atualizado_em := now();
  select * into pr from public.parametros_comerciais where id = 1;
  if new.status = 'enviado' and new.validade_ate is null then
    new.validade_ate := now() + make_interval(days => pr.validade_orcamento_dias);
  end if;
  if tg_op = 'UPDATE' and new.status in ('enviado', 'aceito', 'pago')
     and (old.status = 'rascunho' or new.subtotal is distinct from old.subtotal or new.total is distinct from old.total
          or new.desconto_valor is distinct from old.desconto_valor or new.frete_valor is distinct from old.frete_valor) then
    -- o cálculo usa os itens gravados; subtotal e desconto novos entram pela própria linha
    f := private.orcamento_financeiro(new.id);
    if (f ->> 'itens')::integer = 0 and old.status = 'rascunho' then
      raise exception 'Orçamento sem itens não pode ser enviado.' using errcode = 'P0001';
    end if;
    if (f ->> 'itens')::integer > 0
       and private.lucro(new.subtotal - new.desconto_valor + new.arte_valor + new.frete_valor, (f ->> 'custo')::numeric, (f ->> 'extra')::numeric, new.metodo_previsto) < 0 then
      raise exception 'Orçamento recusado: o preço total daria prejuízo (abaixo do piso duro).' using errcode = 'P0001';
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function private.orcamentos_validar() from public, anon, authenticated;
drop trigger if exists orcamentos_validar on public.orcamentos;
create trigger orcamentos_validar before insert or update on public.orcamentos
  for each row execute function private.orcamentos_validar();

-- Item de pedido: preço abaixo do piso duro é recusado; SKU obrigatório quando exigir_sku_pedidos estiver ligado (Etapa 2)
create or replace function private.order_items_validar() returns trigger
language plpgsql set search_path = ''
as $$
declare
  pr public.parametros_comerciais%rowtype;
  v_pct numeric;
begin
  select * into pr from public.parametros_comerciais where id = 1;
  if pr.exigir_sku_pedidos and tg_op = 'INSERT' and (new.code is null or btrim(new.code) = '') then
    raise exception 'Item sem SKU não pode entrar no pedido.' using errcode = 'P0001';
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
revoke execute on function private.order_items_validar() from public, anon, authenticated;
drop trigger if exists order_items_validar on public.order_items;
create trigger order_items_validar before insert or update on public.order_items
  for each row execute function private.order_items_validar();

-- Pedido: desconto ou taxas editados à mão não podem levar o total para prejuízo (só quando esses campos mudam; pagamento não passa por aqui)
create or replace function private.orders_validar_desconto() returns trigger
language plpgsql set search_path = ''
as $$
declare
  v_gross numeric; v_cost numeric;
begin
  select coalesce(sum(qty * unit_price), 0), coalesce(sum(qty * unit_cost), 0) into v_gross, v_cost from public.order_items where order_id = new.id;
  if v_gross > 0 and v_cost > 0
     and round(v_gross * (1 - new.discount_pct / 100) * (1 - (new.tax_pct + new.payment_fee_pct) / 100), 2) < v_cost then
    raise exception 'Desconto recusado: o pedido daria prejuízo (abaixo do piso duro).' using errcode = 'P0001';
  end if;
  return new;
end;
$$;
revoke execute on function private.orders_validar_desconto() from public, anon, authenticated;
drop trigger if exists orders_validar_desconto on public.orders;
create trigger orders_validar_desconto before update of discount_pct, tax_pct, payment_fee_pct on public.orders
  for each row when (new.discount_pct is distinct from old.discount_pct or new.tax_pct is distinct from old.tax_pct or new.payment_fee_pct is distinct from old.payment_fee_pct)
  execute function private.orders_validar_desconto();

-- Prazo do pedido: marco inicial = pagamento confirmado E arte aprovada, com corte das 12h e dia de logística (calcular_prazo)
-- Antes da arte aprovada vale a estimativa pelo momento do pagamento; ao aprovar a arte a data é recalculada.
create or replace function private.orders_set_due_date() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_paid timestamptz := coalesce(new.payment_confirmed_at, case when new.payment_status = 'aprovado' then now() end);
begin
  if v_paid is not null and new.lead_days is not null and not new.due_date_manual then
    new.due_date := private.prazo_data(new.lead_days, greatest(v_paid, coalesce(new.art_approved_at, v_paid)));
  end if;
  return new;
end;
$$;

-- A tela Configurações > Prazos grava app_settings.deadline.extra_days; o valor segue para os parâmetros comerciais
create or replace function private.sync_prazo_logistica() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.key = 'deadline' and (new.value ->> 'extra_days') ~ '^[0-9]+$' then
    update public.parametros_comerciais set dias_logistica = (new.value ->> 'extra_days')::smallint where id = 1;
  end if;
  return new;
end;
$$;
revoke execute on function private.sync_prazo_logistica() from public, anon, authenticated;
drop trigger if exists app_settings_sync_prazo on public.app_settings;
create trigger app_settings_sync_prazo after insert or update on public.app_settings
  for each row execute function private.sync_prazo_logistica();
update public.parametros_comerciais set dias_logistica = coalesce((select (value ->> 'extra_days')::smallint from public.app_settings where key = 'deadline'), 1) where id = 1;
