-- CAPI Etapa 3: relatório diário, conferência de pagos x Meta, retentativa automática e número do dono como teste.
-- Aditiva e idempotente. Nada aqui altera pedido, valor ou dado do CRM; só lê e grava em meta_eventos / meta_relatorios.

-- O número do dono (agente_config.whatsapp_dono) nunca gera evento: o pedido 417 (checkout de teste de R$ 1,00) foi à Meta como venda real.
create or replace function private.meta_eh_teste(p_contact uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(c.is_teste, false)
      or exists (select 1 from public.numeros_teste n
                  where length(regexp_replace(n.telefone, '\D', '', 'g')) >= 8
                    and right(private.meta_fone(c.wa_id), 10) = right(regexp_replace(n.telefone, '\D', '', 'g'), 10))
      or exists (select 1 from public.agente_config a
                  where length(regexp_replace(coalesce(a.whatsapp_dono, ''), '\D', '', 'g')) >= 8
                    and right(private.meta_fone(c.wa_id), 10) = right(regexp_replace(a.whatsapp_dono, '\D', '', 'g'), 10))
  from public.contacts c where c.id = p_contact;
$$;
revoke all on function private.meta_eh_teste(uuid) from public, anon, authenticated;

-- O gatilho de Purchase passa a respeitar o mesmo critério de teste (antes só olhava orders.teste)
create or replace function private.meta_purchase_do_pedido()
returns trigger language plpgsql security definer set search_path = '' as $$
declare c public.contacts%rowtype; v_total numeric; v_valor numeric; v_refs jsonb; v_itens integer;
        v_ctwa text; v_motivo text; v_fone text; v_ev text; v_src text;
begin
  if new.payment_status is distinct from 'aprovado' or old.payment_status is not distinct from 'aprovado' or coalesce(new.teste, false) then return new; end if;
  begin
    if private.meta_eh_teste(new.contact_id) then return new; end if;
    select * into c from public.contacts where id = new.contact_id;
    select total into v_total from public.order_financials where order_id = new.id;
    select p.valor into v_valor from public.pagamentos p
     where p.order_id = new.id and p.status = 'aprovado' and p.mp_payment_id is not distinct from new.payment_external_id
     order by p.aprovado_em desc nulls last limit 1;
    select coalesce(jsonb_agg(e.ref) filter (where e.ref is not null), '[]'::jsonb), coalesce(sum(i.qty), 0)
      into v_refs, v_itens
      from public.order_items i left join public.ecommerce_products e on e.sku = i.code where i.order_id = new.id;
    v_fone := private.meta_fone(c.wa_id);
    if new.canal = 'site' then
      v_src := 'website';
    else
      select t.ctwa, t.motivo into v_ctwa, v_motivo from private.meta_ctwa(new.contact_id) t;
      v_src := case when v_ctwa is not null then 'business_messaging' else 'system_generated' end;
    end if;
    v_ev := 'purchase-' || coalesce(nullif(new.payment_external_id, ''), new.id::text);
    insert into public.meta_eventos (event_id, event_name, action_source, messaging_channel, ctwa_clid, motivo_sem_ctwa, event_time, user_data, custom_data, pedido_id)
    values (v_ev, 'Purchase', v_src, case when v_src = 'business_messaging' then 'whatsapp' end, v_ctwa,
            case when new.canal <> 'site' and v_ctwa is null then v_motivo end,
            coalesce(new.payment_confirmed_at, new.paid_at, now()),
            private.meta_user_data(c.id, v_ctwa),
            jsonb_build_object('currency', 'BRL', 'value', coalesce(v_valor, v_total, 0), 'content_ids', v_refs, 'content_type', 'product',
                               'num_items', v_itens, 'order_id', 'SG-' || new.number, 'canal', new.canal),
            new.id)
    on conflict (event_id) do nothing;
  exception when others then
    raise warning 'meta_purchase_do_pedido: %', sqlerrm;
  end;
  return new;
end $$;

alter table public.meta_eventos add column if not exists reprocessos integer not null default 0;

-- Retentativa automática: evento que esgotou as tentativas volta para a fila até 3 vezes enquanto ainda vale (6 dias).
-- O event_id é único e a Meta deduplica, então reenviar nunca duplica a venda.
create or replace function private.meta_reprocessar()
returns integer language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  update public.meta_eventos set status = 'pendente', tentativas = 0, reprocessos = reprocessos + 1
   where status = 'erro' and reprocessos < 3 and event_time > now() - interval '6 days';
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function private.meta_reprocessar() from public, anon, authenticated;

create table if not exists public.meta_relatorios (
  dia date primary key,
  dados jsonb not null,
  criado_em timestamptz not null default now()
);
alter table public.meta_relatorios enable row level security;
revoke all on public.meta_relatorios from anon, authenticated;
grant select on public.meta_relatorios to authenticated;
drop policy if exists meta_relatorios_staff on public.meta_relatorios;
create policy meta_relatorios_staff on public.meta_relatorios for select to authenticated using (private.is_staff());

-- Relatório de um dia (fuso de Belo Horizonte). Só leitura.
create or replace function public.meta_relatorio(p_dia date default ((now() at time zone 'America/Sao_Paulo')::date - 1))
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_ini timestamptz := (p_dia::timestamp at time zone 'America/Sao_Paulo'); v_fim timestamptz := ((p_dia + 1)::timestamp at time zone 'America/Sao_Paulo');
        r jsonb;
begin
  if coalesce(auth.role(), '') <> 'service_role' and not private.is_staff() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  with ev as (select * from public.meta_eventos where criado_em >= v_ini and criado_em < v_fim),
  pagos as (
    select o.id, o.number, o.paid_at from public.orders o
     where o.payment_status = 'aprovado' and not coalesce(o.teste, false) and not private.meta_eh_teste(o.contact_id)
       and coalesce(o.payment_confirmed_at, o.paid_at) >= v_ini and coalesce(o.payment_confirmed_at, o.paid_at) < v_fim),
  pur as (select p.*, (select m.status from public.meta_eventos m where m.pedido_id = p.id and m.event_name = 'Purchase' order by (m.status = 'enviado') desc, m.id desc limit 1) st,
                     exists (select 1 from public.meta_eventos m where m.pedido_id = p.id and m.event_name = 'Purchase' and m.ctwa_clid is not null and m.status = 'enviado') com_ctwa from pagos p)
  select jsonb_build_object(
    'dia', p_dia,
    'eventos', coalesce((select jsonb_object_agg(k, v) from (select event_name || '|' || status k, count(*) v from ev group by 1) x), '{}'::jsonb),
    'pendentes_agora', (select count(*) from public.meta_eventos where status = 'pendente'),
    'com_erro_agora', (select count(*) from public.meta_eventos where status = 'erro'),
    'purchases_pagos', (select count(*) from pur),
    'purchases_enviados', (select count(*) from pur where st = 'enviado'),
    'purchases_com_ctwa', (select count(*) from pur where com_ctwa),
    'pct_purchases_com_ctwa', (select case when count(*) = 0 then null else round(100.0 * count(*) filter (where com_ctwa) / count(*), 1) end from pur),
    'pagos_do_dia_sem_envio', coalesce((select jsonb_agg(jsonb_build_object('pedido', number, 'situacao', coalesce(st, 'sem_evento'))) from pur where st is distinct from 'enviado'), '[]'::jsonb),
    -- conferência dos últimos 7 dias (ainda dá tempo de corrigir): pagos aprovados sem Purchase enviado
    'pagos_7d_sem_envio', coalesce((
      select jsonb_agg(jsonb_build_object('pedido', o.number, 'pago_em', coalesce(o.payment_confirmed_at, o.paid_at),
             'situacao', coalesce((select m.status from public.meta_eventos m where m.pedido_id = o.id and m.event_name = 'Purchase' order by m.id desc limit 1), 'sem_evento')) order by o.number)
        from public.orders o
       where o.payment_status = 'aprovado' and not coalesce(o.teste, false) and not private.meta_eh_teste(o.contact_id)
         and coalesce(o.payment_confirmed_at, o.paid_at) > now() - interval '7 days'
         and not exists (select 1 from public.meta_eventos m where m.pedido_id = o.id and m.event_name = 'Purchase' and m.status = 'enviado')), '[]'::jsonb),
    'erros', coalesce((select jsonb_agg(jsonb_build_object('motivo', e, 'qtd', q)) from (
        select left(erro, 120) e, count(*) q from public.meta_eventos where status in ('erro', 'pendente') and erro is not null group by 1 order by 2 desc limit 5) z), '[]'::jsonb)
  ) into r;
  return r;
end $$;
revoke all on function public.meta_relatorio(date) from public, anon;
grant execute on function public.meta_relatorio(date) to authenticated, service_role;

create or replace function private.meta_relatorio_texto(r jsonb)
returns text language sql immutable set search_path = '' as $$
  select 'CAPI Meta de ' || to_char((r ->> 'dia')::date, 'DD/MM') || E':\n'
    || 'Compras pagas: ' || (r ->> 'purchases_pagos') || ', enviadas à Meta: ' || (r ->> 'purchases_enviados')
    || ', com ctwa_clid: ' || (r ->> 'purchases_com_ctwa')
    || coalesce(' (' || (r ->> 'pct_purchases_com_ctwa') || '%)', '') || E'.\n'
    || 'Leads enviados: ' || coalesce(((r -> 'eventos') ->> 'LeadSubmitted|enviado'), '0')
    || ', checkouts enviados: ' || coalesce(((r -> 'eventos') ->> 'InitiateCheckout|enviado'), '0') || E'.\n'
    || 'Na fila: ' || (r ->> 'pendentes_agora') || ', com erro: ' || (r ->> 'com_erro_agora') || E'.\n'
    || case when jsonb_array_length(r -> 'pagos_7d_sem_envio') > 0
            then 'Pagos que NÃO chegaram na Meta (7 dias): ' || (select string_agg('#' || (x ->> 'pedido') || ' (' || (x ->> 'situacao') || ')', ', ') from jsonb_array_elements(r -> 'pagos_7d_sem_envio') x) || '.'
            else 'Todos os pagos dos últimos 7 dias chegaram na Meta.' end;
$$;

-- Rotina diária: reprocessa o que falhou, grava o relatório de ontem e avisa o dono (alta se houver problema)
create or replace function private.meta_relatorio_enviar()
returns void language plpgsql security definer set search_path = '' as $$
declare v_dia date := (now() at time zone 'America/Sao_Paulo')::date - 1; r jsonb; v_problema boolean;
begin
  perform private.meta_reprocessar();
  r := public.meta_relatorio(v_dia);
  insert into public.meta_relatorios (dia, dados) values (v_dia, r) on conflict (dia) do update set dados = excluded.dados, criado_em = now();
  v_problema := jsonb_array_length(r -> 'pagos_7d_sem_envio') > 0 or (r ->> 'com_erro_agora')::int > 0;
  perform public.alerta_criar('meta_capi_relatorio', case when v_problema then 'alta' else 'baixa' end, null, null, null,
    private.meta_relatorio_texto(r), r, 'meta_capi_relatorio:' || v_dia::text, array['whatsapp']);
exception when others then
  raise warning 'meta_relatorio_enviar: %', sqlerrm;
end $$;
revoke all on function private.meta_relatorio_enviar() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'meta-reprocessar') then perform cron.unschedule('meta-reprocessar'); end if;
  perform cron.schedule('meta-reprocessar', '17 * * * *', $job$ select private.meta_reprocessar(); $job$);
  if exists (select 1 from cron.job where jobname = 'meta-relatorio-diario') then perform cron.unschedule('meta-relatorio-diario'); end if;
  -- 11:00 UTC = 08:00 em Belo Horizonte
  perform cron.schedule('meta-relatorio-diario', '0 11 * * *', $job$ select private.meta_relatorio_enviar(); $job$);
end $$;
