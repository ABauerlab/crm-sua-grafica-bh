-- Financeiro organizado (17/11/2026). Regras do dono:
--  * Todo pedido pago entra sozinho no saldo pelo valor BRUTO; a taxa do Mercado Pago sai sozinha (o Mercado Pago deposita o líquido).
--  * O custo do pedido só movimenta o saldo quando o dono marca "paguei" (ou "já estava pago", sem movimentar).
--  * O imposto só conta para pedidos com NOTA EMITIDA (nf_emitida). Pedido sem nota fica fora e a tela mostra quanto é.
--    O dono registra os pagamentos de imposto e eles abatem o "imposto a pagar".
--  * Abertura: saldo do Mercado Pago em 17/11/2026 = R$ 1.516,13. Pedidos pagos antes disso já estão nesse saldo (não entram de novo).
-- Aditiva e idempotente.
alter table public.financeiro_lancamentos add column if not exists origem text not null default 'manual';
alter table public.financeiro_lancamentos add column if not exists order_id uuid;
create unique index if not exists financeiro_lancamentos_pedido_origem_uq on public.financeiro_lancamentos (order_id, origem);
alter table public.orders add column if not exists nf_motivo text;

create table if not exists public.financeiro_custos (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique,
  valor numeric(12, 2) not null check (valor > 0),
  status text not null default 'pendente' check (status in ('pendente', 'pago', 'ja_pago')),
  pago_em timestamptz,
  lancamento_id uuid,
  criado_em timestamptz not null default now()
);
create table if not exists public.financeiro_impostos_pagos (
  id uuid primary key default gen_random_uuid(),
  valor numeric(12, 2) not null check (valor > 0),
  data date not null default current_date,
  observacao text,
  movimentou boolean not null default true,
  lancamento_id uuid,
  criado_em timestamptz not null default now()
);
alter table public.financeiro_custos enable row level security;
alter table public.financeiro_impostos_pagos enable row level security;
do $p$ begin
  if not exists (select 1 from pg_policies where tablename = 'financeiro_custos' and policyname = 'financeiro_custos_admin') then
    create policy financeiro_custos_admin on public.financeiro_custos for all to authenticated using (private.is_admin()) with check (private.is_admin());
  end if;
  if not exists (select 1 from pg_policies where tablename = 'financeiro_impostos_pagos' and policyname = 'financeiro_impostos_admin') then
    create policy financeiro_impostos_admin on public.financeiro_impostos_pagos for all to authenticated using (private.is_admin()) with check (private.is_admin());
  end if;
end $p$;

-- Lançamentos automáticos de um pedido (venda bruta, taxa, estorno) e custo a pagar. Nunca bloqueia o pagamento.
create or replace function private.financeiro_sync_pedido(p_order uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare o public.orders%rowtype; f record; v_ini timestamptz; v_quando timestamptz; v_dia date;
begin
  select * into o from public.orders where id = p_order;
  if not found or coalesce(o.teste, false) or o.excluido_em is not null then return; end if;
  select total, cost, fee into f from public.order_financials where order_id = p_order;
  select (value ->> 'inicio_automatico')::timestamptz into v_ini from public.app_settings where key = 'financeiro';
  v_quando := coalesce(o.paid_at, o.created_at);
  v_dia := (v_quando at time zone 'America/Sao_Paulo')::date;
  if o.payment_status = 'aprovado' or o.payment_manual then
    if coalesce(f.cost, 0) > 0 then
      insert into public.financeiro_custos (order_id, valor) values (p_order, f.cost)
      on conflict (order_id) do update set valor = excluded.valor where public.financeiro_custos.status = 'pendente';
    end if;
    if v_ini is not null and v_quando >= v_ini and coalesce(f.total, 0) > 0 then
      insert into public.financeiro_lancamentos (tipo, categoria, descricao, valor, data, origem, order_id)
      values ('receita', 'Venda', 'Pedido SG-' || o.number, f.total, v_dia, 'pedido', p_order)
      on conflict (order_id, origem) do update set valor = excluded.valor, data = excluded.data;
      if coalesce(f.fee, 0) > 0 then
        insert into public.financeiro_lancamentos (tipo, categoria, descricao, valor, data, origem, order_id)
        values ('despesa', 'Taxa do Mercado Pago', 'Pedido SG-' || o.number, f.fee, v_dia, 'taxa', p_order)
        on conflict (order_id, origem) do update set valor = excluded.valor, data = excluded.data;
      end if;
    end if;
  elsif o.payment_status = 'estornado' and exists (select 1 from public.financeiro_lancamentos where order_id = p_order and origem = 'pedido') then
    insert into public.financeiro_lancamentos (tipo, categoria, descricao, valor, data, origem, order_id)
    values ('despesa', 'Estorno de venda', 'Pedido SG-' || o.number, f.total, (now() at time zone 'America/Sao_Paulo')::date, 'estorno', p_order)
    on conflict (order_id, origem) do nothing;
  end if;
end $$;

create or replace function private.financeiro_trigger_pedido() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  begin perform private.financeiro_sync_pedido(new.id); exception when others then null; end;
  return new;
end $$;
drop trigger if exists orders_financeiro_sync on public.orders;
create trigger orders_financeiro_sync after update of payment_status, payment_manual, paid_at, payment_fee_pct, discount_pct, tax_pct on public.orders
  for each row execute function private.financeiro_trigger_pedido();

create or replace function private.financeiro_sincronizar_tudo() returns integer
language plpgsql security definer set search_path = '' as $$
declare r record; n integer := 0;
begin
  for r in select id from public.orders where (payment_status in ('aprovado', 'estornado') or payment_manual) and coalesce(teste, false) = false and excluido_em is null loop
    perform private.financeiro_sync_pedido(r.id); n := n + 1;
  end loop;
  return n;
end $$;
create or replace function public.financeiro_sincronizar() returns integer
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'sem_permissao'; end if;
  return private.financeiro_sincronizar_tudo();
end $$;

-- Abertura: saldo do Mercado Pago em 17/11/2026 e início dos lançamentos automáticos
insert into public.app_settings (key, value)
values ('financeiro', jsonb_build_object('saldo_mp', 1516.13, 'saldo_mp_em', now(), 'inicio_automatico', now()))
on conflict (key) do update set value = public.app_settings.value || case when public.app_settings.value ? 'inicio_automatico' then '{}'::jsonb else jsonb_build_object('saldo_mp', 1516.13, 'saldo_mp_em', now(), 'inicio_automatico', now()) end;

insert into public.financeiro_lancamentos (tipo, categoria, descricao, valor, data, origem)
select case when 1516.13 - s >= 0 then 'receita' else 'despesa' end, 'Saldo de abertura',
       'Ajuste para bater com o saldo do Mercado Pago em 17/11/2026 (R$ 1.516,13)', abs(1516.13 - s), (now() at time zone 'America/Sao_Paulo')::date, 'abertura'
  from (select coalesce(sum(case when tipo = 'receita' then valor else -valor end), 0) s from public.financeiro_lancamentos) q
 where not exists (select 1 from public.financeiro_lancamentos where origem = 'abertura') and abs(1516.13 - s) > 0;

select private.financeiro_sincronizar_tudo();

do $$ begin
  if exists (select 1 from cron.job where jobname = 'financeiro-sincronizar') then perform cron.unschedule('financeiro-sincronizar'); end if;
  perform cron.schedule('financeiro-sincronizar', '*/10 * * * *', 'select private.financeiro_sincronizar_tudo();');
end $$;

-- Painel: saldo, custos a pagar e imposto (só de notas emitidas)
create or replace function public.financeiro_painel() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_rec numeric; v_desp numeric; v_cfg jsonb; v_custos jsonb; v_imp jsonb; v_pend numeric; v_pend_qtd int;
        v_dev numeric; v_devq int; v_pago numeric; v_sn_q int; v_sn_b numeric; v_sn_i numeric; v_mes jsonb; v_pgs jsonb;
begin
  if not private.is_admin() then raise exception 'sem_permissao'; end if;
  select coalesce(sum(valor) filter (where tipo = 'receita'), 0), coalesce(sum(valor) filter (where tipo = 'despesa'), 0) into v_rec, v_desp from public.financeiro_lancamentos;
  select value into v_cfg from public.app_settings where key = 'financeiro';
  select coalesce(sum(valor), 0), count(*) into v_pend, v_pend_qtd from public.financeiro_custos where status = 'pendente';
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'numero', o.number, 'cliente', coalesce(nullif(btrim(ct.name), ''), ct.wa_id), 'valor', c.valor, 'status', c.status, 'pago_em', c.pago_em, 'paid_at', o.paid_at)
         order by (c.status = 'pendente') desc, o.number desc), '[]'::jsonb)
    into v_custos from (select * from public.financeiro_custos order by criado_em desc limit 300) c
    join public.orders o on o.id = c.order_id left join public.contacts ct on ct.id = o.contact_id;
  select coalesce(sum(f.tax), 0), count(*) into v_dev, v_devq
    from public.orders o join public.order_financials f on f.order_id = o.id
   where (o.payment_status = 'aprovado' or o.payment_manual) and coalesce(o.teste, false) = false and o.excluido_em is null and o.nf_emitida;
  select coalesce(sum(valor), 0) into v_pago from public.financeiro_impostos_pagos;
  select count(*), coalesce(sum(f.total), 0), coalesce(sum(f.tax), 0) into v_sn_q, v_sn_b, v_sn_i
    from public.orders o join public.order_financials f on f.order_id = o.id
   where (o.payment_status = 'aprovado' or o.payment_manual) and coalesce(o.teste, false) = false and o.excluido_em is null and not o.nf_emitida;
  select coalesce(jsonb_agg(jsonb_build_object('mes', m, 'notas', n, 'imposto', t) order by m desc), '[]'::jsonb) into v_mes
    from (select to_char(o.nf_emitida_em at time zone 'America/Sao_Paulo', 'YYYY-MM') m, count(*) n, sum(f.tax) t
            from public.orders o join public.order_financials f on f.order_id = o.id
           where (o.payment_status = 'aprovado' or o.payment_manual) and coalesce(o.teste, false) = false and o.excluido_em is null and o.nf_emitida
           group by 1) q;
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'valor', valor, 'data', data, 'observacao', observacao, 'movimentou', movimentou) order by data desc, criado_em desc), '[]'::jsonb) into v_pgs from public.financeiro_impostos_pagos;
  return jsonb_build_object(
    'saldo', v_rec - v_desp, 'receitas', v_rec, 'despesas', v_desp,
    'saldo_mp', v_cfg -> 'saldo_mp', 'saldo_mp_em', v_cfg -> 'saldo_mp_em', 'inicio_automatico', v_cfg -> 'inicio_automatico',
    'custos', jsonb_build_object('pendente', v_pend, 'qtd_pendente', v_pend_qtd, 'itens', v_custos),
    'imposto', jsonb_build_object('devido', v_dev, 'notas', v_devq, 'pago', v_pago, 'a_pagar', v_dev - v_pago,
       'sem_nota_qtd', v_sn_q, 'sem_nota_bruto', v_sn_b, 'sem_nota_imposto', v_sn_i, 'por_mes', v_mes, 'pagamentos', v_pgs));
end $$;

create or replace function public.financeiro_custo_baixar(p_id uuid, p_movimentar boolean default true) returns void
language plpgsql security definer set search_path = '' as $$
declare c public.financeiro_custos%rowtype; v_num integer; v_l uuid;
begin
  if not private.is_admin() then raise exception 'sem_permissao'; end if;
  select * into c from public.financeiro_custos where id = p_id and status = 'pendente';
  if not found then raise exception 'Custo não encontrado ou já baixado.'; end if;
  if p_movimentar then
    select number into v_num from public.orders where id = c.order_id;
    insert into public.financeiro_lancamentos (tipo, categoria, descricao, valor, data, origem, order_id)
    values ('despesa', 'Custo do pedido', 'Pedido SG-' || v_num, c.valor, (now() at time zone 'America/Sao_Paulo')::date, 'custo', c.order_id) returning id into v_l;
  end if;
  update public.financeiro_custos set status = case when p_movimentar then 'pago' else 'ja_pago' end, pago_em = now(), lancamento_id = v_l where id = p_id;
end $$;

create or replace function public.financeiro_custo_reabrir(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare c public.financeiro_custos%rowtype;
begin
  if not private.is_admin() then raise exception 'sem_permissao'; end if;
  select * into c from public.financeiro_custos where id = p_id and status <> 'pendente';
  if not found then return; end if;
  if c.lancamento_id is not null then delete from public.financeiro_lancamentos where id = c.lancamento_id; end if;
  update public.financeiro_custos set status = 'pendente', pago_em = null, lancamento_id = null where id = p_id;
end $$;

create or replace function public.financeiro_imposto_pagar(p_valor numeric, p_data date default current_date, p_movimentar boolean default true, p_obs text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare v_id uuid := gen_random_uuid(); v_l uuid;
begin
  if not private.is_admin() then raise exception 'sem_permissao'; end if;
  if coalesce(p_valor, 0) <= 0 then raise exception 'Informe um valor maior que zero.'; end if;
  if p_movimentar then
    insert into public.financeiro_lancamentos (tipo, categoria, descricao, valor, data, origem)
    values ('despesa', 'Impostos', coalesce(nullif(btrim(p_obs), ''), 'Pagamento de imposto'), p_valor, coalesce(p_data, current_date), 'imposto') returning id into v_l;
  end if;
  insert into public.financeiro_impostos_pagos (id, valor, data, observacao, movimentou, lancamento_id) values (v_id, p_valor, coalesce(p_data, current_date), nullif(btrim(p_obs), ''), p_movimentar, v_l);
end $$;

create or replace function public.financeiro_imposto_excluir(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_l uuid;
begin
  if not private.is_admin() then raise exception 'sem_permissao'; end if;
  select lancamento_id into v_l from public.financeiro_impostos_pagos where id = p_id;
  delete from public.financeiro_impostos_pagos where id = p_id;
  if v_l is not null then delete from public.financeiro_lancamentos where id = v_l; end if;
end $$;

-- Resumo do período: imposto só de pedidos com nota emitida; lançamentos "manuais" separados dos automáticos
create or replace function public.financeiro_resumo(p_de date, p_ate date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_ped jsonb; v_cat jsonb; v_mes jsonb; v_lucro numeric; v_rec numeric; v_desp numeric;
begin
  if not private.is_admin() then raise exception 'sem_permissao'; end if;
  select jsonb_build_object('pedidos', count(*), 'faturamento', coalesce(sum(f.total), 0), 'custo', coalesce(sum(f.cost), 0),
         'impostos', coalesce(sum(case when o.nf_emitida then f.tax else 0 end), 0), 'taxas', coalesce(sum(f.fee), 0),
         'lucro', coalesce(sum(f.net_profit + case when o.nf_emitida then 0 else f.tax end), 0),
         'sem_nota', count(*) filter (where not o.nf_emitida))
    into v_ped
    from public.orders o join public.order_financials f on f.order_id = o.id
   where o.payment_status = 'aprovado' and coalesce(o.teste, false) = false
     and (coalesce(o.paid_at, o.created_at) at time zone 'America/Sao_Paulo')::date between p_de and p_ate;
  select coalesce(sum(valor) filter (where tipo = 'receita'), 0), coalesce(sum(valor) filter (where tipo = 'despesa'), 0)
    into v_rec, v_desp from public.financeiro_lancamentos where origem = 'manual' and data between p_de and p_ate;
  v_lucro := (v_ped ->> 'lucro')::numeric;
  select coalesce(jsonb_agg(jsonb_build_object('categoria', categoria, 'tipo', tipo, 'total', t) order by t desc), '[]'::jsonb)
    into v_cat from (select categoria, tipo, sum(valor) t from public.financeiro_lancamentos where origem = 'manual' and data between p_de and p_ate group by categoria, tipo) q;
  select coalesce(jsonb_agg(jsonb_build_object('mes', m, 'lucro_pedidos', lp, 'receitas', r, 'despesas', d) order by m), '[]'::jsonb)
    into v_mes from (
      select to_char(x.mes, 'YYYY-MM') m,
             coalesce((select sum(f.net_profit + case when o.nf_emitida then 0 else f.tax end) from public.orders o join public.order_financials f on f.order_id = o.id
                        where o.payment_status = 'aprovado' and coalesce(o.teste, false) = false
                          and date_trunc('month', (coalesce(o.paid_at, o.created_at) at time zone 'America/Sao_Paulo')) = x.mes), 0) lp,
             coalesce((select sum(valor) from public.financeiro_lancamentos l where l.origem = 'manual' and l.tipo = 'receita' and date_trunc('month', l.data) = x.mes), 0) r,
             coalesce((select sum(valor) from public.financeiro_lancamentos l where l.origem = 'manual' and l.tipo = 'despesa' and date_trunc('month', l.data) = x.mes), 0) d
        from generate_series(date_trunc('month', p_ate::timestamp) - interval '5 months', date_trunc('month', p_ate::timestamp), interval '1 month') x(mes)) z;
  return jsonb_build_object('pedidos', v_ped, 'manual', jsonb_build_object('receitas', v_rec, 'despesas', v_desp), 'categorias', v_cat, 'meses', v_mes,
                            'resultado', v_lucro + v_rec - v_desp);
end $$;

-- Motivo de a nota não ter sido emitida (anotação do dono)
create or replace function public.nf_motivo_salvar(p_order uuid, p_motivo text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_staff() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  update public.orders set nf_motivo = nullif(btrim(coalesce(p_motivo, '')), '') where id = p_order;
end $$;

revoke all on function public.financeiro_sincronizar(), public.financeiro_painel(), public.financeiro_custo_baixar(uuid, boolean), public.financeiro_custo_reabrir(uuid),
  public.financeiro_imposto_pagar(numeric, date, boolean, text), public.financeiro_imposto_excluir(uuid), public.nf_motivo_salvar(uuid, text) from public, anon;
grant execute on function public.financeiro_sincronizar(), public.financeiro_painel(), public.financeiro_custo_baixar(uuid, boolean), public.financeiro_custo_reabrir(uuid),
  public.financeiro_imposto_pagar(numeric, date, boolean, text), public.financeiro_imposto_excluir(uuid), public.nf_motivo_salvar(uuid, text) to authenticated;
revoke all on function private.financeiro_sync_pedido(uuid), private.financeiro_sincronizar_tudo(), private.financeiro_trigger_pedido() from public, anon, authenticated;
