-- Etapa 7B, Bloco A: proteger a operação. Aditiva e idempotente.
-- Taxas por método e parcelas, taxa real do Mercado Pago, método obrigatório no pedido manual,
-- exclusão com auditoria, atraso só em produção e selo de urgência.

-- ---------------------------------------------------------------- 1. taxas por método e parcelamento
alter table public.parametros_comerciais add column if not exists parcelas_sem_juros_max smallint not null default 2 check (parcelas_sem_juros_max between 1 and 12);
alter table public.parametros_comerciais add column if not exists parcela_adicional_pct numeric(5, 2) not null default 2.00 check (parcela_adicional_pct >= 0);

-- 2x sem juros: o vendedor absorve a taxa de parcelamento. O valor abaixo é uma ESTIMATIVA CONSERVADORA até o dono
-- confirmar em Mercado Pago > Seu negócio > Custos; depois do primeiro pagamento em 2x a taxa real aparece no pedido.
update public.parametros_comerciais set taxas_pagamento = taxas_pagamento
  || case when taxas_pagamento ? 'cartao_credito_2x' then '{}'::jsonb else jsonb_build_object('cartao_credito_2x', jsonb_build_object('pct', 10.50, 'fixo', 0, 'estimativa', true)) end
  || case when taxas_pagamento ? 'cartao_debito' then '{}'::jsonb else jsonb_build_object('cartao_debito', jsonb_build_object('pct', 4.98, 'fixo', 0, 'estimativa', true)) end
  || case when taxas_pagamento ? 'dinheiro' then '{}'::jsonb else jsonb_build_object('dinheiro', jsonb_build_object('pct', 0, 'fixo', 0)) end
  || case when taxas_pagamento ? 'transferencia' then '{}'::jsonb else jsonb_build_object('transferencia', jsonb_build_object('pct', 0, 'fixo', 0)) end
 where id = 1;
-- o piso passa a usar a pior taxa que o link permite (cartão em 2x sem juros)
update public.parametros_comerciais set metodo_piso = 'cartao_credito_2x' where id = 1 and metodo_piso = 'cartao_credito';
update public.parametros_comerciais set campos_revisar = array_append(campos_revisar, 'taxas_pagamento.cartao_credito_2x')
 where id = 1 and not ('taxas_pagamento.cartao_credito_2x' = any(campos_revisar));

drop function if exists private.taxa_pagamento(text);
create or replace function private.taxa_pagamento(p_metodo text, p_parcelas integer default 1) returns jsonb
language plpgsql stable set search_path = ''
as $$
declare
  pr public.parametros_comerciais%rowtype;
  m text := lower(coalesce(p_metodo, ''));
  n integer := greatest(coalesce(p_parcelas, 1), 1);
  v_chave text;
  v_conhecido boolean := true;
  v_pct numeric;
begin
  select * into pr from public.parametros_comerciais where id = 1;
  v_chave := case
    when m in ('cartao_credito', 'cartao', 'credit_card', 'credito', 'visa', 'master', 'mastercard', 'elo', 'amex', 'hipercard', 'diners', 'cabal', 'cartao_credito_2x') then
      case when n >= 2 or m = 'cartao_credito_2x' then 'cartao_credito_2x' else 'cartao_credito' end
    when m in ('debit_card', 'cartao_debito', 'debito') then 'cartao_debito'
    when m in ('saldo_mercado_pago', 'account_money') then 'saldo_mercado_pago'
    when m in ('linha_credito', 'consumer_credits') then 'linha_credito'
    when m in ('cartao_prepago', 'prepaid_card') then 'cartao_prepago'
    when m = 'pix' then 'pix'
    when m = 'open_finance' then 'open_finance'
    when m in ('boleto', 'ticket', 'bolbradesco', 'pec') then 'boleto'
    when m = 'dinheiro' then 'dinheiro'
    when m = 'transferencia' then 'transferencia'
    else null end;
  if v_chave is null or not (pr.taxas_pagamento ? v_chave) then
    v_chave := pr.metodo_piso;
    v_conhecido := false;
  end if;
  v_pct := (pr.taxas_pagamento -> v_chave ->> 'pct')::numeric;
  -- acima de 2x (só se o dono decidir oferecer): soma o adicional por parcela
  if v_chave = 'cartao_credito_2x' and n > 2 then v_pct := v_pct + (n - 2) * pr.parcela_adicional_pct; end if;
  return jsonb_build_object('chave', v_chave, 'pct', v_pct, 'fixo', (pr.taxas_pagamento -> v_chave ->> 'fixo')::numeric,
                            'conhecido', v_conhecido, 'parcelas', n);
end;
$$;
revoke execute on function private.taxa_pagamento(text, integer) from public, anon, authenticated;

-- ---------------------------------------------------------------- 2. orçamento: trava sempre na pior taxa; taxa por método só para o dono
-- O link aceita Pix e cartão em até 2x, então o "método previsto" nunca baixa a trava.
create or replace function private.orcamentos_metodo_pior_caso() returns trigger
language plpgsql set search_path = ''
as $$
begin
  new.metodo_previsto := null;
  return new;
end;
$$;
revoke execute on function private.orcamentos_metodo_pior_caso() from public, anon, authenticated;
drop trigger if exists orcamentos_metodo_pior_caso on public.orcamentos;
create trigger orcamentos_metodo_pior_caso before insert or update of metodo_previsto on public.orcamentos
  for each row when (new.metodo_previsto is not null) execute function private.orcamentos_metodo_pior_caso();
update public.orcamentos set metodo_previsto = null where metodo_previsto is not null and status in ('rascunho', 'enviado');

-- Tabela interna: lucro do orçamento em cada método (o cliente nunca vê taxa como linha separada)
create or replace function public.orcamento_lucro_por_metodo(p_orcamento uuid) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  f jsonb; pr public.parametros_comerciais%rowtype; r jsonb := '[]'::jsonb; k text; t jsonb; n integer;
begin
  if not private.is_staff() and coalesce(auth.role(), '') <> 'service_role' then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  f := private.orcamento_financeiro(p_orcamento);
  if f is null then return null; end if;
  select * into pr from public.parametros_comerciais where id = 1;
  for k in select jsonb_object_keys(pr.taxas_pagamento) order by 1 loop
    if k = 'boleto' then continue; end if;
    t := private.taxa_pagamento(k, case when k = 'cartao_credito_2x' then 2 else 1 end);
    r := r || jsonb_build_array(jsonb_build_object('metodo', k, 'taxa_pct', t -> 'pct',
      'taxa_valor', round((f ->> 'receita')::numeric * (t ->> 'pct')::numeric / 100, 2),
      'lucro_liquido', private.lucro((f ->> 'receita')::numeric, (f ->> 'custo')::numeric, (f ->> 'extra')::numeric, k)));
  end loop;
  return jsonb_build_object('receita', f -> 'receita', 'pior_caso', pr.metodo_piso, 'metodos', r);
end;
$$;
revoke execute on function public.orcamento_lucro_por_metodo(uuid) from public, anon;
grant execute on function public.orcamento_lucro_por_metodo(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------- 3. pedido: parcelas, taxa real, urgência, exclusão
alter table public.orders add column if not exists parcelas smallint check (parcelas between 1 and 12);
alter table public.orders add column if not exists taxa_fonte text not null default 'estimada' check (taxa_fonte in ('estimada', 'metodo', 'mercado_pago'));
alter table public.orders add column if not exists taxa_pagamento_real_valor numeric(12, 2);
alter table public.orders add column if not exists liquido_recebido numeric(12, 2);
alter table public.orders add column if not exists urgente boolean not null default false;
alter table public.orders add column if not exists urgente_motivo text;
alter table public.orders add column if not exists urgente_em timestamptz;
alter table public.orders add column if not exists excluido_em timestamptz;
alter table public.orders add column if not exists excluido_por uuid;
alter table public.orders add column if not exists excluido_motivo text;
alter table public.orders add column if not exists arquivado_em timestamptz;
alter table public.orders add column if not exists cancelado_em timestamptz;
alter table public.orders add column if not exists cancelado_motivo text;
alter table public.orders add column if not exists reembolso_pendente boolean not null default false;
create index if not exists orders_excluido_idx on public.orders (excluido_em) where excluido_em is not null;
create index if not exists orders_urgente_idx on public.orders (urgente) where urgente;

alter table public.contacts add column if not exists urgente boolean not null default false;
alter table public.contacts add column if not exists urgente_motivo text;
alter table public.contacts add column if not exists urgente_em timestamptz;

-- Auditoria de exclusões, cancelamentos e arquivamentos
create table if not exists public.pedidos_auditoria (
  id uuid primary key default gen_random_uuid(),
  order_id uuid,
  numero integer,
  acao text not null check (acao in ('excluido', 'excluido_teste', 'arquivado', 'cancelado', 'restaurado')),
  motivo text not null,
  por uuid,
  quando timestamptz not null default now(),
  pago boolean not null default false,
  resumo jsonb not null default '{}'::jsonb
);
alter table public.pedidos_auditoria enable row level security;
drop policy if exists pedidos_auditoria_dono on public.pedidos_auditoria;
create policy pedidos_auditoria_dono on public.pedidos_auditoria for select to authenticated using (private.is_staff());
revoke all on public.pedidos_auditoria from anon;

-- A taxa do pedido acompanha o método escolhido (pedido manual ou confirmado). A taxa real do Mercado Pago nunca é sobrescrita.
create or replace function private.orders_taxa_do_metodo() returns trigger
language plpgsql set search_path = ''
as $$
declare t jsonb;
begin
  if new.payment_method is null or new.taxa_fonte = 'mercado_pago' then return new; end if;
  t := private.taxa_pagamento(new.payment_method, new.parcelas);
  if (t ->> 'conhecido')::boolean then
    new.payment_fee_pct := round((t ->> 'pct')::numeric, 2);
    new.taxa_fonte := 'metodo';
  end if;
  return new;
end;
$$;
revoke execute on function private.orders_taxa_do_metodo() from public, anon, authenticated;
drop trigger if exists orders_taxa_do_metodo on public.orders;
create trigger orders_taxa_do_metodo before insert or update of payment_method, parcelas on public.orders
  for each row execute function private.orders_taxa_do_metodo();

-- Pagamento confirmado em pedido excluído: o dinheiro entrou, então o pedido volta a aparecer e o dono é avisado
create or replace function private.orders_pago_apos_exclusao() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.payment_status = 'aprovado' and old.payment_status is distinct from 'aprovado' and old.excluido_em is not null then
    new.excluido_em := null;
    insert into public.pedidos_auditoria (order_id, numero, acao, motivo, pago, resumo)
    values (new.id, new.number, 'restaurado', 'pagamento confirmado depois da exclusão', true, jsonb_build_object('motivo_exclusao', old.excluido_motivo));
    perform public.alerta_criar('divergencia_pagamento', 'alta', new.contact_id, new.conversation_id, new.id,
      'Pagamento confirmado em pedido que estava excluído. O pedido voltou para o kanban.', '{}'::jsonb, 'pago_apos_exclusao:' || new.id::text);
  end if;
  return new;
end;
$$;
revoke execute on function private.orders_pago_apos_exclusao() from public, anon, authenticated;
drop trigger if exists orders_pago_apos_exclusao on public.orders;
create trigger orders_pago_apos_exclusao before update of payment_status on public.orders
  for each row execute function private.orders_pago_apos_exclusao();

-- ---------------------------------------------------------------- 4. taxa REAL do Mercado Pago (fee_details e valor líquido)
create or replace function public.pagamento_taxa_real(p_mp_payment_id text, p_taxa numeric, p_liquido numeric, p_parcelas integer default null) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_pg record; v_pct numeric; v_lucro numeric; v_taxa numeric;
begin
  if coalesce(auth.role(), '') <> 'service_role' then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select pg.order_id, pg.valor into v_pg from public.pagamentos pg where pg.mp_payment_id = p_mp_payment_id and pg.status = 'aprovado' order by pg.criado_em desc limit 1;
  if not found or v_pg.order_id is null then return jsonb_build_object('ok', false, 'motivo', 'pagamento_nao_aprovado'); end if;
  if p_taxa is null or p_taxa < 0 or coalesce(v_pg.valor, 0) <= 0 then return jsonb_build_object('ok', false, 'motivo', 'taxa_invalida'); end if;
  v_taxa := round(p_taxa, 2);
  v_pct := round(v_taxa / v_pg.valor * 100, 2);
  update public.orders set parcelas = coalesce(p_parcelas, parcelas), taxa_fonte = 'mercado_pago', payment_fee_pct = v_pct,
         taxa_pagamento_real_pct = v_pct, taxa_pagamento_real_valor = v_taxa, liquido_recebido = p_liquido
   where id = v_pg.order_id and payment_status = 'aprovado';
  select net_profit into v_lucro from public.order_financials where order_id = v_pg.order_id;
  update public.orders set lucro_liquido_real = v_lucro where id = v_pg.order_id;
  return jsonb_build_object('ok', true, 'order_id', v_pg.order_id, 'taxa_pct', v_pct, 'taxa_valor', v_taxa, 'lucro_liquido_real', v_lucro);
end;
$$;
revoke execute on function public.pagamento_taxa_real(text, numeric, numeric, integer) from public, anon, authenticated;
grant execute on function public.pagamento_taxa_real(text, numeric, numeric, integer) to service_role;

-- ---------------------------------------------------------------- 5. pagamento manual: o dono escolhe o método
drop function if exists public.confirmar_pagamento_manual(uuid);
create or replace function public.confirmar_pagamento_manual(p_order uuid, p_metodo text default null, p_parcelas integer default null) returns boolean
language plpgsql security definer set search_path = ''
as $$
declare
  v_ok boolean; v_total numeric; v_id uuid; v_metodo text; v_parc integer;
begin
  if not private.is_staff() then raise exception 'Não autorizado.' using errcode = '42501'; end if;
  select total into v_total from public.order_financials where order_id = p_order;
  if v_total is null then raise exception 'Pedido não encontrado.' using errcode = 'P0001'; end if;
  v_metodo := lower(coalesce(nullif(trim(p_metodo), ''), (select payment_method from public.orders where id = p_order)));
  if v_metodo is null or v_metodo not in ('pix', 'cartao_credito', 'cartao_debito', 'dinheiro', 'transferencia', 'outro') then
    raise exception 'Escolha o método de pagamento (Pix, crédito, débito, dinheiro, transferência ou outro).' using errcode = 'P0001';
  end if;
  v_parc := case when v_metodo = 'cartao_credito' then greatest(coalesce(p_parcelas, (select parcelas from public.orders where id = p_order), 1), 1) else null end;
  update public.orders set payment_method = v_metodo, parcelas = v_parc where id = p_order and payment_status <> 'aprovado';
  insert into public.pagamentos (order_id, valor, status, modo, metodo, aprovado_em)
  select p_order, greatest(v_total, 0.01), 'aprovado', 'manual', v_metodo, now()
  where not exists (select 1 from public.orders where id = p_order and payment_status = 'aprovado')
  returning id into v_id;
  v_ok := private.confirmar_pagamento(p_order, 'manual', v_metodo, null, now(), v_id);
  return v_ok;
end;
$$;
revoke execute on function public.confirmar_pagamento_manual(uuid, text, integer) from public, anon;
grant execute on function public.confirmar_pagamento_manual(uuid, text, integer) to authenticated;

-- ---------------------------------------------------------------- 6. excluir, arquivar e cancelar pedido
create or replace function public.pedido_excluir(p_order uuid, p_motivo text) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  o public.orders%rowtype; v_motivo text := nullif(trim(coalesce(p_motivo, '')), ''); v_pago boolean;
begin
  if not private.is_staff() then raise exception 'Não autorizado.' using errcode = '42501'; end if;
  if v_motivo is null or length(v_motivo) < 5 then raise exception 'Informe o motivo da exclusão (mínimo de 5 letras).' using errcode = 'P0001'; end if;
  select * into o from public.orders where id = p_order for update;
  if not found then raise exception 'Pedido não encontrado.' using errcode = 'P0001'; end if;
  v_pago := o.payment_status = 'aprovado' or o.payment_manual or o.paid_at is not null;
  if o.excluido_em is not null then return jsonb_build_object('ok', true, 'ja_excluido', true); end if;
  if v_pago then
    -- pedido pago nunca é apagado: o registro financeiro e a conversa ficam
    return jsonb_build_object('ok', false, 'motivo', 'pedido_pago', 'orientacao', 'Pedido com pagamento aprovado não pode ser excluído. Use Cancelar ou Arquivar.');
  end if;
  if o.teste then
    insert into public.pedidos_auditoria (order_id, numero, acao, motivo, por, pago, resumo)
    values (o.id, o.number, 'excluido_teste', v_motivo, auth.uid(), false, jsonb_build_object('titulo', o.title));
    update public.orcamentos set order_id = null where order_id = o.id;
    update public.alertas set order_id = null where order_id = o.id;
    update public.pagamentos_alertas set order_id = null where order_id = o.id;
    delete from public.orders where id = o.id;
    return jsonb_build_object('ok', true, 'removido_por_completo', true);
  end if;
  insert into public.pedidos_auditoria (order_id, numero, acao, motivo, por, pago, resumo)
  values (o.id, o.number, 'excluido', v_motivo, auth.uid(), false, jsonb_build_object('titulo', o.title, 'etapa', o.stage));
  update public.orders set excluido_em = now(), excluido_por = auth.uid(), excluido_motivo = v_motivo where id = o.id;
  -- itens dependentes ficam consistentes
  update public.orcamentos set status = 'cancelado' where order_id = o.id and status in ('rascunho', 'enviado', 'aceito');
  update public.pagamentos set link_ativo = false where order_id = o.id and status <> 'aprovado';
  update public.pedido_avisos set status = 'pulado' where order_id = o.id and status in ('pendente', 'reservado');
  update public.followup_fila set status = 'cancelado' where order_id = o.id and status in ('pendente', 'reservado');
  update public.tasks set done_at = now() where order_id = o.id and done_at is null;
  return jsonb_build_object('ok', true, 'logico', true);
end;
$$;
revoke execute on function public.pedido_excluir(uuid, text) from public, anon;
grant execute on function public.pedido_excluir(uuid, text) to authenticated;

-- Pedido pago: cancelar (com reembolso pendente, quem decide é o dono) ou arquivar
create or replace function public.pedido_cancelar_ou_arquivar(p_order uuid, p_acao text, p_motivo text) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  o public.orders%rowtype; v_motivo text := nullif(trim(coalesce(p_motivo, '')), '');
begin
  if not private.is_staff() then raise exception 'Não autorizado.' using errcode = '42501'; end if;
  if p_acao not in ('cancelar', 'arquivar') then raise exception 'Ação inválida.' using errcode = 'P0001'; end if;
  if v_motivo is null or length(v_motivo) < 5 then raise exception 'Informe o motivo (mínimo de 5 letras).' using errcode = 'P0001'; end if;
  select * into o from public.orders where id = p_order for update;
  if not found then raise exception 'Pedido não encontrado.' using errcode = 'P0001'; end if;
  if p_acao = 'arquivar' then
    update public.orders set arquivado_em = now() where id = o.id;
    insert into public.pedidos_auditoria (order_id, numero, acao, motivo, por, pago, resumo)
    values (o.id, o.number, 'arquivado', v_motivo, auth.uid(), o.payment_status = 'aprovado', jsonb_build_object('titulo', o.title));
    return jsonb_build_object('ok', true);
  end if;
  update public.orders set cancelado_em = now(), cancelado_motivo = v_motivo, arquivado_em = now(),
         reembolso_pendente = (payment_status = 'aprovado') where id = o.id;
  update public.orcamentos set status = 'cancelado' where order_id = o.id and status in ('rascunho', 'enviado', 'aceito');
  update public.pedido_avisos set status = 'pulado' where order_id = o.id and status in ('pendente', 'reservado');
  insert into public.pedidos_auditoria (order_id, numero, acao, motivo, por, pago, resumo)
  values (o.id, o.number, 'cancelado', v_motivo, auth.uid(), o.payment_status = 'aprovado', jsonb_build_object('titulo', o.title));
  if o.payment_status = 'aprovado' then
    perform public.alerta_criar('reembolso_pendente', 'alta', o.contact_id, o.conversation_id, o.id,
      'Pedido pago cancelado. O reembolso é decisão do dono e deve ser feito no Mercado Pago.', '{}'::jsonb, 'reembolso_pendente:' || o.id::text);
  end if;
  return jsonb_build_object('ok', true, 'reembolso_pendente', o.payment_status = 'aprovado');
end;
$$;
revoke execute on function public.pedido_cancelar_ou_arquivar(uuid, text, text) from public, anon;
grant execute on function public.pedido_cancelar_ou_arquivar(uuid, text, text) to authenticated;

-- ---------------------------------------------------------------- 7. atraso (só em produção) e urgência
-- Fonte única da regra: atrasado = já em produção, não entregue e com o prazo útil vencido (data de calendário de São Paulo).
create or replace function public.pedido_esta_atrasado(p_stage text, p_due date, p_delivered timestamptz, p_hoje date default null) returns boolean
language sql stable set search_path = ''
as $$
  select p_stage = 'producao' and p_delivered is null and p_due is not null
         and p_due < coalesce(p_hoje, (now() at time zone 'America/Sao_Paulo')::date);
$$;
revoke execute on function public.pedido_esta_atrasado(text, date, timestamptz, date) from public, anon;
grant execute on function public.pedido_esta_atrasado(text, date, timestamptz, date) to authenticated, service_role;

create or replace function public.pedidos_atrasados() returns table (order_id uuid, numero integer, contact_id uuid, due_date date, dias_atraso integer, urgente boolean)
language sql stable security definer set search_path = ''
as $$
  select o.id, o.number, o.contact_id, o.due_date, ((now() at time zone 'America/Sao_Paulo')::date - o.due_date)::integer, o.urgente
    from public.orders o
   where private.dono_ou_servidor() and o.excluido_em is null and o.cancelado_em is null
     and public.pedido_esta_atrasado(o.stage::text, o.due_date, o.delivered_at)
   order by o.urgente desc, o.due_date;
$$;
revoke execute on function public.pedidos_atrasados() from public, anon;
grant execute on function public.pedidos_atrasados() to authenticated, service_role;

-- Urgência só ordena a fila. Nunca altera prazo, preço ou promessa.
create or replace function public.registrar_urgencia(p_contact uuid, p_motivo text default null, p_ligar boolean default true) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_motivo text := left(nullif(trim(coalesce(p_motivo, '')), ''), 200);
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  update public.contacts set urgente = p_ligar, urgente_motivo = case when p_ligar then v_motivo else null end,
         urgente_em = case when p_ligar then now() else null end where id = p_contact;
  update public.orders set urgente = p_ligar, urgente_motivo = case when p_ligar then v_motivo else null end,
         urgente_em = case when p_ligar then now() else null end
   where contact_id = p_contact and excluido_em is null and cancelado_em is null and stage <> 'entregue' and stage <> 'recompra';
  return jsonb_build_object('ok', true, 'urgente', p_ligar);
end;
$$;
revoke execute on function public.registrar_urgencia(uuid, text, boolean) from public, anon;
grant execute on function public.registrar_urgencia(uuid, text, boolean) to authenticated, service_role;

-- ---------------------------------------------------------------- 8. calcular_preco: o piso usa sempre a pior taxa
create or replace function public.calcular_preco(p_sku text, p_quantidade integer default 1, p_contexto jsonb default '{}'::jsonb)
returns jsonb
language plpgsql stable set search_path = ''
as $$
declare
  pr public.parametros_comerciais%rowtype;
  prod record;
  v_qtd integer := greatest(coalesce(p_quantidade, 1), 1);
  -- o método de pagamento só é conhecido depois do pagamento: o preço sempre usa a pior taxa (simular_metodo é só para análise interna)
  v_metodo text := case when p_contexto ->> 'simular_metodo' = 'true' then p_contexto ->> 'metodo' end;
  v_outros_receita numeric := coalesce((p_contexto ->> 'receita_outros')::numeric, 0);
  v_outros_custo numeric := coalesce((p_contexto ->> 'custo_outros')::numeric, 0);
  v_custo_item numeric; v_custo_total numeric; v_extra numeric;
  v_base numeric; v_piso numeric; v_piso_duro numeric;
  v_mediana numeric; v_n integer; v_fator numeric; v_alvo numeric; v_preco numeric;
  v_ancora numeric; v_n_vendas integer; v_consulta uuid;
  v_regra text; v_conf text; v_nao_comp boolean := false; v_receita numeric; v_lucro numeric;
  v_avisos text[] := '{}';
begin
  select * into pr from public.parametros_comerciais where id = 1;
  select c.custo, c.active, c.vendavel, c.grupo_produto, c.especificacao_normalizada into prod from public.catalogo c where c.sku = p_sku;
  if not found or not prod.active then return jsonb_build_object('ok', false, 'erro', 'sku_nao_encontrado'); end if;
  if not prod.vendavel then return jsonb_build_object('ok', false, 'erro', 'item_nao_vendavel'); end if;

  v_custo_item := prod.custo * v_qtd;
  v_custo_total := v_custo_item + v_outros_custo;
  v_extra := private.custos_operacionais(p_contexto ->> 'entrega');
  v_piso := ceil(greatest(v_custo_item * pr.multiplicador_piso,
                          private.receita_para_lucro(v_custo_total, v_extra, pr.lucro_liquido_minimo, v_metodo) - v_outros_receita) * 100) / 100;
  v_piso_duro := ceil((private.receita_para_lucro(v_custo_total, v_extra, 0, v_metodo) - v_outros_receita) * 100) / 100;
  v_base := private.arredonda_90(v_custo_item * private.multiplicador_faixa(v_custo_item));

  -- mercado válido: mesma especificação, normalizado, sem outlier, dentro da idade máxima
  select percentile_cont(0.5) within group (order by m.preco), count(distinct m.fonte) into v_mediana, v_n
    from public.precos_mercado m
   where (m.chave_especificacao = coalesce(nullif(prod.especificacao_normalizada, ''), p_sku) or m.sku = p_sku)
     and m.normalizado and not m.outlier and m.invalidado_em is null
     and m.coletado_em >= now() - make_interval(days => pr.idade_max_pesquisa_dias);
  if v_n > 0 then
    select m.consulta_id into v_consulta from public.precos_mercado m
     where (m.chave_especificacao = coalesce(nullif(prod.especificacao_normalizada, ''), p_sku) or m.sku = p_sku)
       and m.normalizado and not m.outlier and m.invalidado_em is null and m.consulta_id is not null
     order by m.coletado_em desc limit 1;
  end if;

  select coalesce(f.fator, pr.fator_competitivo) into v_fator from (select 1) x left join public.fatores_competitivos f on f.grupo_produto = prod.grupo_produto;
  v_fator := least(greatest(coalesce(v_fator, pr.fator_competitivo), pr.fator_competitivo_min), pr.fator_competitivo_max);

  -- âncora: 3 ou mais vendas do mesmo SKU nos últimos 90 dias; média ponderada pela recência (preço por unidade do SKU)
  select count(*), sum((p.preco_total / p.quantidade) * w) / nullif(sum(w), 0) into v_n_vendas, v_ancora
    from (select pp.preco_total, pp.quantidade, 1.0 / (1 + extract(epoch from (now() - pp.criado_em)) / 86400 / 30) as w
            from public.precos_praticados pp
           where pp.sku = p_sku and pp.resultado = 'ganho' and pp.criado_em >= now() - interval '90 days' and pp.preco_total > 0) p;
  if coalesce(v_n_vendas, 0) < 3 then v_ancora := null; end if;

  if v_n > 0 then
    v_alvo := v_mediana * v_qtd * v_fator;
    v_regra := 'mercado';
    if v_ancora is not null then
      v_alvo := (v_alvo + least(v_ancora, v_mediana) * v_qtd) / 2;     -- a âncora nunca passa do mercado
      v_regra := 'mercado_com_ancora_vendas';
    end if;
    v_alvo := private.arredonda_90(v_alvo);
    v_conf := case when v_n >= 3 then 'alta' when v_n = 2 then 'media' else 'baixa' end;
    if v_n = 1 then v_avisos := array_append(v_avisos, 'mercado_com_uma_fonte'); end if;
  elsif v_ancora is not null then
    v_alvo := private.arredonda_90(v_ancora * v_qtd);
    v_regra := 'historico_vendas'; v_conf := 'media';
  else
    v_alvo := v_base; v_regra := 'custo_x_multiplicador'; v_conf := 'baixa';
    v_avisos := array_append(v_avisos, 'sem_dado_de_mercado');
  end if;

  if v_alvo >= v_piso then
    v_preco := v_alvo;
  else
    v_preco := private.teto_90(v_piso);
    v_regra := 'piso';
    v_nao_comp := v_n > 0;
    if v_nao_comp then v_avisos := array_append(v_avisos, 'mercado_abaixo_do_piso'); end if;
  end if;
  -- trava final: jamais abaixo do piso duro, mesmo que alguém altere a fórmula acima
  if v_preco < v_piso_duro then v_preco := private.teto_90(v_piso_duro); end if;

  v_receita := v_preco + v_outros_receita;
  v_lucro := private.lucro(v_receita, v_custo_total, v_extra, v_metodo);
  return jsonb_build_object(
    'ok', true, 'sku', p_sku, 'quantidade', v_qtd,
    'preco_unitario', round(v_preco / v_qtd, 2), 'preco_total', v_preco,
    'regra', v_regra, 'confianca', v_conf,
    'margem_liquida_pct', round(v_lucro / nullif(v_receita, 0) * 100, 1), 'lucro_liquido', v_lucro,
    'piso', round(v_piso, 2), 'piso_duro', round(v_piso_duro, 2),
    'nao_competitivo', v_nao_comp, 'fontes_mercado', v_n, 'mercado_mediana', round(v_mediana * v_qtd, 2),
    'consulta_mercado_id', v_consulta, 'fator_competitivo', v_fator, 'ancora_vendas', round(v_ancora * v_qtd, 2),
    'avisos', to_jsonb(v_avisos));
end;
$$;
