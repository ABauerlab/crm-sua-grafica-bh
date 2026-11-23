-- Relatório diário do CAPI: taxa de compra por origem (semana e 30 dias) e tempo mediano até o pagamento.
-- Aditiva e idempotente. Só leitura. Origem do contato: anúncio (tem referral), origem declarada (etapa 4), pedido manual
-- (sem nenhuma mensagem do cliente) ou sem origem informada. Contatos e pedidos de teste ficam de fora.
--  * taxa = contatos criados na janela que já pagaram, sobre os contatos criados na janela;
--  * tempo = do primeiro contato ao primeiro pagamento, dos clientes que pagaram na janela.

create or replace function private.meta_origem_janela(p_ini timestamptz, p_fim timestamptz)
returns jsonb language sql stable security definer set search_path = '' as $$
  with base as (
    select c.id, c.created_at,
           case when c.first_referral is not null then 'anuncio'
                when c.origem_declarada is not null then c.origem_declarada
                when not exists (select 1 from public.messages m join public.conversations v on v.id = m.conversation_id where v.contact_id = c.id and m.direction = 'in') then 'manual'
                else 'sem_origem' end as origem
      from public.contacts c where not coalesce(c.is_teste, false) and not private.meta_eh_teste(c.id)),
  pag as (
    select o.contact_id, min(coalesce(o.payment_confirmed_at, o.paid_at)) as pago_em
      from public.orders o where o.payment_status = 'aprovado' and not coalesce(o.teste, false) and o.excluido_em is null group by 1),
  coorte as (
    select b.origem, count(*) as contatos, count(p.pago_em) filter (where p.pago_em < p_fim) as compraram
      from base b left join pag p on p.contact_id = b.id where b.created_at >= p_ini and b.created_at < p_fim group by 1),
  tempo as (
    select b.origem, extract(epoch from (p.pago_em - b.created_at)) / 3600.0 as h
      from base b join pag p on p.contact_id = b.id where p.pago_em >= p_ini and p.pago_em < p_fim)
  select jsonb_build_object(
    'por_origem', coalesce((select jsonb_object_agg(origem, jsonb_build_object('contatos', contatos, 'compraram', compraram,
                    'taxa_pct', round(100.0 * compraram / nullif(contatos, 0), 1))) from coorte), '{}'::jsonb),
    'mediana_horas_total', (select round((percentile_cont(0.5) within group (order by h))::numeric, 1) from tempo),
    'mediana_horas_por_origem', coalesce((select jsonb_object_agg(origem, m) from (
        select origem, round((percentile_cont(0.5) within group (order by h))::numeric, 1) as m from tempo group by 1) z), '{}'::jsonb),
    'pagos_na_janela', (select count(*) from tempo));
$$;
revoke all on function private.meta_origem_janela(timestamptz, timestamptz) from public, anon, authenticated;

create or replace function public.meta_relatorio_origem(p_dia date default ((now() at time zone 'America/Sao_Paulo')::date - 1))
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_fim timestamptz := ((p_dia + 1)::timestamp at time zone 'America/Sao_Paulo');
begin
  if coalesce(auth.role(), '') <> 'service_role' and not private.is_staff() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  return jsonb_build_object('semana', private.meta_origem_janela(v_fim - interval '7 days', v_fim),
                            'mes', private.meta_origem_janela(v_fim - interval '30 days', v_fim));
end $$;
revoke all on function public.meta_relatorio_origem(date) from public, anon;
grant execute on function public.meta_relatorio_origem(date) to authenticated, service_role;

create or replace function private.meta_origem_texto(o jsonb)
returns text language sql immutable set search_path = '' as $$
  select coalesce((select string_agg(
           (case k when 'anuncio' then 'anúncio' when 'sem_origem' then 'sem origem informada' when 'manual' then 'pedido manual'
                   when 'ja_era_cliente' then 'já era cliente' when 'indicacao' then 'indicação' when 'balcao' then 'balcão' else k end)
           || ' ' || (v ->> 'compraram') || '/' || (v ->> 'contatos') || coalesce(' (' || (v ->> 'taxa_pct') || '%)', ''), ', ' order by k)
         from jsonb_each(o -> 'por_origem') e(k, v)), 'sem contatos novos');
$$;

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
            then 'Pagos que NÃO chegaram na Meta (7 dias): ' || (select string_agg('#' || (x ->> 'pedido') || ' (' || (x ->> 'situacao') || ')', ', ') from jsonb_array_elements(r -> 'pagos_7d_sem_envio') x) || E'.'
            else 'Todos os pagos dos últimos 7 dias chegaram na Meta.' end
    || case when r ? 'origem' then
         E'\nCompra por origem na semana (pagaram/contatos): ' || private.meta_origem_texto(r #> '{origem,semana}') || E'.'
         || E'\nTempo mediano até pagar na semana: '
         || coalesce((r #>> '{origem,semana,mediana_horas_total}') || ' h' ||
              coalesce(' (anúncio ' || (r #>> '{origem,semana,mediana_horas_por_origem,anuncio}') || ' h)', ''), 'sem pagamentos na semana') || E'.'
         || E'\nEm 30 dias: ' || private.meta_origem_texto(r #> '{origem,mes}')
         || coalesce('; mediana ' || (r #>> '{origem,mes,mediana_horas_total}') || ' h', '') || E'.'
       else '' end;
$$;

create or replace function private.meta_relatorio_enviar()
returns void language plpgsql security definer set search_path = '' as $$
declare v_dia date := (now() at time zone 'America/Sao_Paulo')::date - 1; r jsonb; v_problema boolean;
begin
  perform private.meta_reprocessar();
  r := public.meta_relatorio(v_dia) || jsonb_build_object('origem', public.meta_relatorio_origem(v_dia));
  insert into public.meta_relatorios (dia, dados) values (v_dia, r) on conflict (dia) do update set dados = excluded.dados, criado_em = now();
  v_problema := jsonb_array_length(r -> 'pagos_7d_sem_envio') > 0 or (r ->> 'com_erro_agora')::int > 0;
  perform public.alerta_criar('meta_capi_relatorio', case when v_problema then 'alta' else 'baixa' end, null, null, null,
    private.meta_relatorio_texto(r), r, 'meta_capi_relatorio:' || v_dia::text, array['whatsapp']);
exception when others then
  raise warning 'meta_relatorio_enviar: %', sqlerrm;
end $$;
revoke all on function private.meta_relatorio_enviar() from public, anon, authenticated;
